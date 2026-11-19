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
| `k8s/31-roulette.yaml`    | Roulette game (Python) — http 8082 / gRPC 50052 |
| `k8s/32-dice.yaml`        | Dice game (Go) — http 8083 / gRPC 50053 |
| `k8s/33-blackjack.yaml`   | Blackjack game (Node) — http 8084 / gRPC 50054 |
| `k8s/40-dashboard.yaml`   | Dashboard — http 3001 / gRPC 50055 |
| `k8s/50-frontend.yaml`    | Frontend web UI — http 3000 (trace root) |
| `k8s/60-loadgen-k6.yaml`  | k6 load-gen Job (stock `grafana/k6`) + script ConfigMap |
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
> mounted at `/scripts/casino-load.js`; it logs in players and plays all four
> games through the frontend HTTP API (ISI-7625 D2b). To tune load, edit `VUS` /
> `DURATION` on the Job, or the script in the ConfigMap.

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
