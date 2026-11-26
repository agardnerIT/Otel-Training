# Vegas Casino — training-cluster deployment (ISI-6794)

Canonical Kubernetes manifests for the (upgraded, defect-planted) Vegas Casino
app on the per-attendee OTel-training kind cluster. These are the **single
source of truth** the GitOps path (ISI-6796) consumes — Argo CD syncs
`deploy/casino/k8s` into the `casino` namespace.

```
 frontend ──gRPC──▶ slots / roulette / dice / blackjack ──┐
    │  │                                                    ├─▶ redis
    │  └──HTTP──▶ scoring ──▶ postgresql                    │
    └──gRPC──▶ dashboard ──HTTP──▶ scoring                  ┘
 k6 load-gen ──HTTP──▶ frontend        all services ──OTLP/gRPC──▶
                                       otel-gateway-collector.observability:4317
```

## What's here

| File | Resource(s) |
| ---- | ----------- |
| `k8s/00-config.yaml`      | ServiceAccount `vegas-casino` + shared ConfigMap `vegas-casino-config` |
| `k8s/10-redis.yaml`       | Redis (game state) — Deployment + Service |
| `k8s/11-postgresql.yaml`  | PostgreSQL (scoring store) — Deployment + Service |
| `k8s/20-scoring.yaml`     | Scoring service (Java) — Deployment + Service |
| `k8s/30-slots.yaml`       | Slots game (Node) — http 8081 / gRPC 50051 |
| `k8s/31-roulette.yaml`    | Roulette game (Python) — http 8082 / gRPC 50052 — **dropped by the `lite` profile** |
| `k8s/32-dice.yaml`        | Dice game (Go) — http 8083 / gRPC 50053 — **dropped by the `lite` profile** |
| `k8s/33-blackjack.yaml`   | Blackjack game (Node) — http 8084 / gRPC 50054 |
| `k8s/40-dashboard.yaml`   | Dashboard — http 3001 / gRPC 50055 |
| `k8s/50-frontend.yaml`    | Frontend web UI — http 3000 (trace root) |
| `k8s/60-loadgen-k6.yaml`  | k6 load-gen Deployment (stock `grafana/k6`) + script ConfigMap |
| `verify.sh`               | live-cluster acceptance checks (ISI-6794 AC) |

22 resources total (9 Deployments, 9 Services, 1 Job, 2 ConfigMaps, 1 ServiceAccount).

## Design decisions

- **Plain YAML, not Helm/Kustomize.** The Argo CD Application uses a *directory*
  source (`path: k8s`). Plain manifests are applied verbatim and give attendees
  a file they can read and edit end-to-end — the core "edit a manifest → commit
  → watch Argo CD deploy" lab mechanic. (A `kustomization.yaml` would flip Argo
  into kustomize mode, so there deliberately isn't one.) The manifests were
  rendered from the upstream `helm/vegas-casino` chart with training values
  baked in.
- **No `namespace:` fields.** Argo CD applies everything into its destination
  namespace `casino` (`CreateNamespace=true`). Hardcoding a namespace would
  fight the Application.
- **OTLP export wired to the deployment collector.** Every service exports
  OTLP/gRPC to `otel-gateway-collector.observability.svc.cluster.local:4317`
  (ISI-6792 gateway), insecure in-cluster. That collector enriches with k8s
  metadata and forwards to Dynatrace.
- **OpenFeature/flagd excluded.** The services degrade to default flag values
  when flagd is unreachable (confirmed in `services/common/openfeature.js`), so
  the OpenFeature Operator + flagd sidecars are dropped to keep the per-attendee
  cluster inside its ~8 GB budget. Feature flags are not part of the planted-
  defect observability story.
- **Gateway (API-gateway) service and Gateway API/HTTPRoute excluded.** The
  gateway service is disabled upstream; Gateway API routing would add a
  kgateway CRD dependency the training cluster doesn't install. The frontend is
  reachable in-cluster via its ClusterIP Service (AC satisfied); humans
  port-forward it.
- **Images:** `ghcr.io/${IMAGE_OWNER}/otel-training/vegasapp-<service>:${IMAGE_TAG}`,
  built and published by CI (`.github/workflows/casino-images.yml`, ISI-7587).
  The `image:` lines carry `${IMAGE_OWNER}`/`${IMAGE_TAG}` **placeholders**; the
  deploy path resolves them with `render-images.sh` (see below) so a fork can
  repoint images at its own GHCR namespace. Baseline defaults:
  `IMAGE_OWNER=henrikrexed`, `IMAGE_TAG=` the immutable version in
  [`IMAGE_VERSION`](IMAGE_VERSION).
- **Image tag = immutable version (ISI-7625 D1).** [`IMAGE_VERSION`](IMAGE_VERSION)
  (currently `0.39`) is the **single source of truth** for the tag. The build
  workflow reads it and publishes every service at that immutable `type=raw`
  tag (alongside `sha-<short>` and, on the default branch, `latest`);
  `render-images.sh` reads the *same* file as its default `IMAGE_TAG`. So the tag
  the manifests pin always exists as a published package — no more pinning a tag
  CI never built. **To cut a new image set:** bump `IMAGE_VERSION` in a PR; the
  merge push republishes all services at the new tag and every deploy pins it.
- **Resource sizing** is tuned for the shared kind node: ~650m CPU / ~1.5 Gi of
  memory *requests* across the whole app, leaving headroom for the collectors
  and operators that share the cluster.

## Profiles — `full` (default) / `lite` (ISI-7653)

`CASINO_PROFILE` selects the casino footprint. **Default is `full`** — the whole
22-resource topology above. `CASINO_PROFILE=lite` shrinks it to the smallest
casino that still tells the full lab story.

| | `full` (default) | `lite` |
| --- | --- | --- |
| Services | slots, roulette, dice, blackjack + scoring/frontend/dashboard/redis/postgres | **roulette + dice removed** — everything else kept |
| k6 loadgen `GAMES` | `slots,roulette,dice,blackjack` | `slots,blackjack` (no traffic to the dropped routes) |
| Dynatrace ActiveGate | deployed (k8s-monitoring) | **optional — skipped** (app OTLP still exports via the OTel collector); `LITE_WITH_ACTIVEGATE=1` keeps it |
| Gitea | used on the `gitops`/`gitea` path | optional — pair with `DEPLOY_MODE=direct` for a Gitea-free `kubectl apply` bring-up |

Why **exactly** roulette + dice: the WS7 footprint audit (ISI-7633) found those
two are the **only** services no lab uniquely depends on. The minimum viable
topology lite preserves is `scoring + slots + blackjack + frontend + redis +
postgres + loadgen + gateway`.

**How it's applied — a seed-time plain-text filter, not a kustomize overlay.**
`deploy/casino/lite-filter.sh` runs on a *throwaway copy* of the rendered
manifests (never the committed source): it deletes `31-roulette.yaml` +
`32-dice.yaml` and rewrites the loadgen `GAMES` value to `slots,blackjack`. Both
deploy paths call it when `CASINO_PROFILE=lite`:

- **GitOps / Gitea** — `gitops/install/seed-gitea.sh` filters the copy it pushes,
  so Argo CD only ever sees the lite set. (The external-GitLab-fork path serves
  whatever is in the attendee's fork; filter there by editing the fork.)
- **Direct** — `deploy-environment.sh` filters the rendered temp dir before
  `kubectl apply`.

A flat directory of plain YAML is kept intact (no `kustomization.yaml`), so the
edit → commit → Argo-sync lab mechanic (ISI-6796) is unchanged.

```bash
# Lite, Gitea-free (smallest footprint):
CASINO_PROFILE=lite DEPLOY_MODE=direct bash .devcontainer/bootstrap/deploy-environment.sh
# Lite via GitOps/Gitea (Argo CD syncs the lite set):
CASINO_PROFILE=lite GITOPS_PROVIDER=gitea bash .devcontainer/bootstrap/deploy-environment.sh
# Preview what lite produces, without deploying:
d=$(mktemp -d); cp deploy/casino/k8s/*.yaml "$d"/; bash deploy/casino/lite-filter.sh "$d"; ls "$d"
```

**Nothing-breaks note:** the k6 load script sets `thresholds: {}` and so never
aborts on a non-2xx — dropping a game is already an *expected* condition, not a
run failure. In `lite` the `GAMES` toggle removes the dropped-route calls
entirely, so the loadgen emits **zero** avoidable errors against the surviving
`slots`/`blackjack`/frontend topology.

## Image owner substitution (ISI-7587 / c3 ISI-7589)

The manifest `image:` lines are templated with `${IMAGE_OWNER}`/`${IMAGE_TAG}`.
They are resolved by **plain-text substitution** (no kustomize, preserving the
ISI-6794 plain-YAML + Argo decision) via `render-images.sh`:

```bash
# Render with the upstream baseline (defaults):
bash deploy/casino/render-images.sh -o /tmp/casino-rendered
# Render pointing at a fork's own build:
IMAGE_OWNER=alice IMAGE_TAG=latest bash deploy/casino/render-images.sh -o /tmp/casino-rendered
```

The seed/deploy path (ISI-7589 c3) derives `IMAGE_OWNER` from the fork's git
origin (same pattern as `PARTICIPANT_ID`, defaulting to the upstream owner) and
renders at seed time before Argo CD syncs. First launch needs **no** pre-build:
the manifests default to the upstream **baseline** public images.

The owner decision lives in `deploy/casino/image-owner.sh` and is deliberately
**baseline-first**:

1. An explicit `IMAGE_OWNER` in the env always wins (no probe).
2. Otherwise the owner is parsed from `git remote get-url origin`. If that is the
   **upstream** repo → baseline, done.
3. For a real **fork**, the resolver runs a one-shot GHCR **preflight** (a
   manifest `HEAD` on `ghcr.io/<fork>/otel-training/vegasapp-frontend:<tag>`). Only
   if the fork build is **proven published** does it adopt `<fork>`; otherwise it
   stays on the upstream baseline and says so. The probe is short-timeout and
   fail-soft — it never hangs or aborts the bring-up, and never points at an image
   that does not exist (which would be `ImagePullBackOff`).

```bash
# What owner will the seed use here?
bash deploy/casino/image-owner.sh owner
# Is a fork build published yet?
bash deploy/casino/image-owner.sh preflight <fork-owner>
```

## Two git loops: edit a manifest vs deploy your own build

The casino lab has **two** push-to-deploy loops. Know which one a change needs:

**Loop 1 — manifest / config → Gitea → Argo CD.** Editing a file under
`k8s/` (a `Deployment`, the `vegas-casino-config` ConfigMap, the loadgen script,
…) changes only Kubernetes YAML. Commit + push to the casino repo in Gitea and
**Argo CD syncs it** — no image rebuild. This is the loop the advanced catalog
"ship via GitOps" steps use for collector/config edits.

**Loop 2 (default) — service code → in-cluster Gitea CI → image → write-back → Argo CD.**
Editing a service's **source** under `apps/casino/<svc>/` needs a **new image**,
so Argo CD cannot pick it up from a manifest change alone. On the default Gitea
GitOps path this is **fully in-cluster and automated** (ISI-7882) — nothing
leaves the Codespace and you never hand-edit a tag:

```text
edit apps/casino/<svc>/…  ->  git push (in-cluster casino/casino repo)
   -> Gitea Actions builds + SHA-tags  gitea.local:30001/casino/vegasapp-<svc>:<sha>
   -> CI commits that :<sha> into k8s/ [skip ci]  ->  Argo CD syncs the new image
```

The CI `write-back k8s tag` job rewrites the `vegasapp-*` refs in `k8s/*.yaml` to
the per-commit `:<sha>` and commits it back, so the manifest Argo watches always
points at the freshly built image. Walk-through:
[Local CI/CD: Gitea Actions & Packages](../../docs-site/advanced/gitea-local-cicd.md).

**Loop 2 (optional variant) — service code → your GHCR fork → `deploy-my-build.sh`.**
A separate exercise that builds on **your own GitHub fork's** Actions and GHCR
namespace instead of the in-cluster registry. Opt in with `IMAGE_SOURCE=ghcr` on
the seed. The flow is:

```text
edit apps/casino/<svc>/…  ->  git push (your fork)  ->  fork Actions build+publish
   ghcr.io/<you>/otel-training/vegasapp-<svc>:<tag>  ->  deploy-my-build.sh  ->  Argo CD syncs
```

### One-time prerequisite — enable fork Actions

A brand-new fork has GitHub Actions **disabled**. Enable them **once** so the
"Build casino images" workflow runs on your pushes:

> Your fork → **Actions** tab → **"I understand my workflows, go ahead and enable them"**.

(You also only ever need the pull secret if your fork packages are **private**;
the upstream baseline packages are public and pull with no token.)

### Deploy my build

After your push, the fork's Actions take **~1–3 min** to build + publish all
`vegasapp-*` images at the pinned tag (`deploy/casino/IMAGE_VERSION`). Then:

```bash
bash deploy/casino/deploy-my-build.sh
```

It derives your owner from the fork origin, **preflights** that your images are
published (if not, it changes nothing and tells you the Actions run hasn't
finished), wires the `ghcr-pull` secret for private fork images, re-seeds Gitea
with `IMAGE_OWNER=<you>`, and nudges Argo CD to sync. Re-running with no new build
is a no-op. On the direct (no-Argo) debug path, run it with `DEPLOY_MODE=direct`.
## Image source — GHCR (default) or the Gitea registry alias (ISI-7640 / WS-C)

The same renderer also switches the **registry** the 7 casino-built `vegasapp-*`
images resolve to, so a fully in-cluster, GHCR-free deploy is one env var away.
It stays plain-text sed — **no kustomize** — so the GHCR default render is
byte-for-byte unchanged (D1) and the Gitea flip is purely additive:

```bash
# Default (D1): GHCR — nothing changes, existing deploys keep pulling from ghcr.io
bash deploy/casino/render-images.sh -o /tmp/casino-rendered

# Flip all 7 services to the in-cluster Gitea container registry alias (ISI-7638):
IMAGE_SOURCE=gitea bash deploy/casino/render-images.sh -o /tmp/casino-rendered
#   -> gitea.local:30001/casino/vegasapp-<svc>:<tag>
```

`IMAGE_SOURCE` flows through the environment, so the same flip works on the
seed/deploy path (`gitops/install/seed-gitea.sh`, `deploy-environment.sh`). The
alias and namespace are overridable via `GITEA_REGISTRY` (default
`gitea.local:30001`, the WS-D contract) and `GITEA_OWNER` (default `casino`, the
`CASINO_ORG` seeded repo owner). Infra images (postgres, redis, curl) and the
upstream `grafana/k6` loadgen are not casino-built and are left on their public
upstreams in **both** modes.

> **Seed/bootstrap default is now `gitea` (ISI-7881 / ISI-7867).** While the
> renderer CLI still defaults to GHCR (so a bare `render-images.sh` is unchanged),
> `gitops/install/seed-gitea.sh` now defaults **`IMAGE_SOURCE=gitea`**, so a fresh
> bring-up seeds `casino/casino` `k8s/*.yaml` with `gitea.local:30001/casino/vegasapp-*`
> refs and Argo CD's source of truth is the in-cluster Gitea registry — no `ghcr.io`
> in the deployed manifests. Set `IMAGE_SOURCE=ghcr` on the seed to opt back into
> the upstream/fork GHCR loop (the fork exercise above). Because the `[skip ci]`
> seed builds nothing, the bootstrap first **mirrors** the baseline images
> GHCR→Gitea with `gitops/install/mirror-baseline-images.sh` (crane copy, no build)
> so the registry is populated on first sync. Node-level pulls of the alias are
> resolved by the containerd mirror wired in `create-cluster.sh` (ISI-7638); see
> `gitops/install/registry-mirror.md`.

**No `imagePullSecret` for Gitea (D3).** Gitea container packages are made
public (anonymous pull), so `gitea.local:30001` refs pull without a secret. The
`ghcr-pull` secret on the `vegas-casino` ServiceAccount is a GHCR credential; it
is simply never matched against `gitea.local` refs, so it is inert in Gitea mode.

## Image pulls — baseline public + fork pull secret

The casino images are built by CI to `ghcr.io/<owner>/otel-training/vegasapp-<svc>`
(ISI-7587). GHCR packages are **private on first publish**, so two things make
the pull work:

- **Baseline (upstream repo) = public.** A one-time GitHub account-owner toggle
  makes each `otel-training/vegasapp-*` package **Public** (the workflow prints
  the exact step in its run summary). After that, anonymous pulls work
  everywhere with no secret distribution, and later pushes stay public. Owner
  action — the fine-grained workshop `GITHUB_PAT` cannot flip visibility and
  there is no REST API for user-namespace container visibility.
- **Fork build = private → pull secret.** An attendee's own build lands in their
  GHCR namespace and may be private. `gitops/install/ensure-casino-pull-secret.sh`
  creates a `ghcr-pull` docker-registry Secret in the `casino` namespace from a
  `read:packages` token (`CASINO_PULL_TOKEN`). The `vegas-casino` ServiceAccount
  already references `ghcr-pull`, so every pod uses it. No token set → no-op,
  assumes public images.

> **k6 loadgen** (`60-loadgen-k6.yaml`) runs the **stock upstream `grafana/k6`**
> image (multi-arch, pinned) — there is no `vegasapp-k6` image to build or pull.
> The load script lives in the `vegas-casino-loadgen-script` ConfigMap and is
> mounted at `/scripts/casino-load.js`; it logs in players and plays the games
> through the frontend HTTP API (ISI-7625 D2b). The `GAMES` env on the Job selects
> which games it drives (default all four; the `lite` profile narrows it to
> `slots,blackjack`). To tune load, edit `VUS` / `DURATION` / `GAMES` on the Job,
> or the script in the ConfigMap.

## Planted defects

The planted defects (`labs/defects.md`) are baked into the **images**, not these
manifests — the manifests deploy the app faithfully so the defects show up
downstream (broken trace propagation, missing logs, etc.). Do not "fix" them
here.

## Deploy

**Via GitOps (the training path):**

```bash
bash gitops/bootstrap/bootstrap-gitops.sh   # seeds deploy/casino/k8s into Gitea, Argo CD syncs it
```

**Directly (debug / without GitOps):**

```bash
kubectl create namespace casino
kubectl -n casino apply -f deploy/casino/k8s
```

Once Argo CD owns the `casino` namespace, do **not** `kubectl apply` by hand —
`selfHeal` reverts drift. Git is authoritative.

## Verify

Offline (anytime):
`kubeconform -strict -ignore-missing-schemas deploy/casino/k8s/*.yaml` — the 22
deployed app resources validate. (`-ignore-missing-schemas` skips the Gateway
API CRs in `70/71/72-*.yaml`, which have no bundled schema and are not part of
the deployed topology — see the gateway exclusion note above.)

Live (on the cluster, after deploy):

```bash
bash deploy/casino/verify.sh
```

It checks every ISI-6794 acceptance criterion — all pods Running, frontend
`/health` reachable in-cluster, telemetry flowing to the gateway collector, and
the load-gen running — and writes a timestamped evidence bundle to
`deploy/casino/evidence/`.
