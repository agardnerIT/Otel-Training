# Local CI/CD: Gitea Actions & Packages

_Appendix. Prerequisite: the base environment is up on the
**Gitea** GitOps fallback (`GITOPS_PROVIDER=gitea`), so Argo CD watches the
in-cluster `casino/casino` repo. See [M0 — Environment setup](../setup.md)._

**Goal:** close the full software-delivery loop **inside your cluster** — edit a
casino service, let **Gitea Actions** build the image, push it to **Gitea
Packages** (Gitea's built-in container registry), and watch **Argo CD** redeploy
*your locally-built image*. No `ghcr.io`, no external CI, nothing leaves the
Codespace. Budget 40 minutes.

!!! info "Optional / stretch — the rebuild-from-source loop is the lesson"
    The default environment already runs the casino **from the in-cluster Gitea
    registry**: at bootstrap the baseline images are mirrored `ghcr.io` → Gitea
    (`gitea.local:30001/casino/vegasapp-*`, crane copy — no build) and the seeded
    `k8s/` manifests reference that alias, so there is already **no `ghcr.io` in
    the running manifests** (ISI-7881). What this appendix adds is the
    **rebuild-from-source** loop: change the code, and the cluster's own CI builds
    *your* image, writes the new tag into `k8s/` for you, and Argo CD rolls it —
    replacing the mirrored baseline with your build. Here the local CI/CD loop is
    the **subject you are learning**, not invisible plumbing.

## The loop you are about to close

```mermaid
flowchart LR
  edit["① Edit<br/>casino service source<br/>(opencode in the Gitea repo)"]
  ci["② CI build<br/>Gitea Actions builds +<br/>tags the image with the commit SHA"]
  pkg["③ Package<br/>push to Gitea Packages<br/>gitea.local:30001/casino/…"]
  write["④ Write-back<br/>CI commits the new SHA tag<br/>into k8s/ (skip-ci)"]
  deploy["⑤ Redeploy<br/>Argo CD syncs the git change<br/>new pods roll"]
  edit --> ci --> pkg --> write --> deploy
  deploy -. "verify, then iterate" .-> edit
```

Every hop runs on a workload *inside the kind cluster*: the git host, the CI
runner, the registry, and Argo CD are all pods in your per-attendee cluster. The
only thing **you** add is a code change — steps ② → ⑤ are automated (ISI-7882):
CI builds, tags with the commit SHA, pushes, **and writes that tag into `k8s/`**
so Argo CD redeploys without you hand-editing a manifest.

## 1. Why a fully-local loop

Out of the box the casino already runs **entirely from the in-cluster Gitea
registry**: at bootstrap the baseline `vegasapp-*` images are mirrored
`ghcr.io` → `gitea.local:30001/casino/*` (crane copy — no build), and the seeded
`k8s/` manifests reference that alias (ISI-7881). So the *default* deploy is
already GHCR-free — but those are still images someone else built. Depending on
an external registry to *rebuild* the app drags in a recurring class of pain:
private-package `403`s, rate limits, and "works on the maintainer's account, not
yours."

This loop removes the external dependency from the **build** too — you change
the code and the cluster rebuilds and redeploys it, no `ghcr.io` anywhere:

- **CI** — Gitea Actions builds the casino images *in the cluster* from your
  edit and tags each build with the commit SHA.
- **Packages** — images land in Gitea's built-in container registry, reachable
  by the kind node over a stable local alias.
- **Write-back** — CI commits the new SHA tag into `k8s/` for you, so the
  manifest Argo CD watches points at *your* build (ISI-7882).
- **Deploy** — Argo CD syncs that git change and rolls an image built *right
  here*, with no `ghcr.io` in the path.

## 2. The pieces

| Piece | Where | What it does in the loop |
|---|---|---|
| Gitea repo `casino/casino` | ns `gitea`, UI `http://localhost:30001` | Your editable casino monorepo — `apps/casino/**` source, the `k8s/` manifests Argo syncs, and the CI workflow. |
| Gitea Actions runner | ns `gitea` (`gitea-act-runner`) | Picks up the workflow on push and runs the build (with a Docker-in-Docker build daemon). |
| Gitea Packages (registry) | ns `gitea`, alias `gitea.local:30001` | Gitea's built-in container registry. Push target **and** pull source — the same string on both sides. |
| Argo CD | ns `argocd`, UI `http://localhost:30002` | Watches `k8s/` on the in-cluster repo and keeps the `casino` namespace in sync. `selfHeal` reverts hand-drift. |

!!! note "The `gitea.local:30001` alias — why push and pull match"
    The runner's build daemon pushes to `gitea.local:30001/casino/vegasapp-<svc>`,
    and the kind node's containerd is configured to resolve that **same** name to
    the Gitea NodePort over plain HTTP (an insecure local-registry mirror). So the
    ref the CI *pushes* is byte-identical to the ref a Deployment *pulls* — no
    rewrite, no external DNS. Packages are **public-read**, so pulls need no
    secret; only the CI push authenticates.

Seeding (`gitops/install/seed-gitea.sh`) pushes that whole tree with a
`[skip ci]` marker on the first commit, so bringing the environment up does **not**
kick off seven in-cluster builds. The loop fires only when **you** push a normal
commit.

## 3. ① Problem — a change you want to see deployed from your own build

Pick one service and make a change you can recognise in the running app. The
cleanest demo is the **slots** service (`vegas-slots-service`, Node.js) — the
same money-path service you instrumented in
[M2](../module-2.md). Your goal for this lab is not the
*content* of the change; it is proving the pipeline carries **your** bytes to a
running pod.

Confirm the "before" — what image the slots pods run right now. The slots
Deployment is named **`vegas-casino-slots`** (every casino service follows
`vegas-casino-<svc>`):

```bash
kubectl -n casino get deploy vegas-casino-slots -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# e.g. gitea.local:30001/casino/vegasapp-slots:0.40
#      (default: baseline image mirrored into the in-cluster Gitea registry)
```

That ref already points at your cluster's own registry — but the bytes are the
**mirrored baseline** (built upstream, copied in at bootstrap). By the end of
this page the same command will print
`gitea.local:30001/casino/vegasapp-slots:<commit-sha>` — the same registry, a tag
your **own** build produced.

## 4. ② Opencode — drive the edit

Work against the **in-cluster** Gitea repo (not an external fork). Clone it in
the Codespace with the seeded admin credentials, then drive `opencode` (warmed up
in [M1](../module-1.md)) at the slots service:

```bash
git clone http://attendee:trainingpass123@localhost:30001/casino/casino.git
cd casino

opencode run "In apps/casino/slots, add a distinctive startup log line to the \
service entry point (index.js) — exactly: console.log('BUILD MARKER: local-ci') \
— so I can prove from the pod logs that this exact build is the one running. Do \
not change any request handler or the response shape."
```

A **startup log line** is the most reliable proof here: it is emitted the moment
your image boots, independent of any route, port, or HTTP method, so the verify
in §9 is a single `kubectl logs | grep`. (Any other visible edit works too — a
version string on the frontend, a new log field — as long as you can observe it
from outside the pod once it is deployed.)

## 5. ③ Review — read the diff

In build mode `opencode` writes straight into the working tree. **Read the diff
before you commit** — this is a real pipeline; a bad edit will build and deploy
just as faithfully as a good one.

```bash
git diff
```

## 6. ④ Immutable tags — the commit SHA is your tag

A new build deserves a **new tag**, and in this pipeline you don't pick one by
hand — **CI tags every build with the commit SHA**. That is the deployable ref:
unique per commit, so every push is automatically a fresh, immutable tag.

!!! tip "Why a per-commit SHA tag — and why *not* re-push `:0.40`"
    If CI re-pushed the *same* tag, Argo CD would see **no change** in the
    manifest and never roll the Deployment, and the node would keep serving the
    old layers it already cached (`imagePullPolicy: IfNotPresent`). A fresh tag
    is how a GitOps system *notices* a new build. The commit SHA gives you that
    for free — one commit, one tag, no manual `IMAGE_VERSION` bump needed.
    (`deploy/casino/IMAGE_VERSION` still exists as an optional human-readable
    *release* tag CI also pushes, but the **SHA** is what drives the redeploy.)

So there is nothing to edit in this step — just make your code change and push.

## 7. ⑤ CI — push, and watch Gitea Actions build + write back

Commit the source change and push a **normal** commit (no `[skip ci]`):

```bash
git add apps/casino
git commit -m "slots: prove local build (BUILD MARKER log)"
git push origin main
```

!!! tip "Prefer a PR? Same loop."
    A single-attendee cluster can push straight to `main`, but the PR flow works
    identically: open a PR, merge it, and the merge commit to `main` is what
    triggers CI. `edit → PR → merge → CI builds + SHA-tags → CI writes the tag
    into k8s/ → Argo deploys` is the full loop.

The push matches the workflow's path filter (`apps/casino/**`), so the runner
starts the build. Open the run in the Gitea UI:

> **Gitea → `casino/casino` → Actions tab** (`http://localhost:30001/casino/casino/actions`)

The workflow is `.gitea/workflows/casino-images.yml` — a **7-service matrix**
(`frontend`, `slots`, `blackjack`, `dashboard`, `roulette`, `dice`, `scoring`;
`gateway` is intentionally excluded — nothing deploys it). Each job installs a
docker client, builds from `apps/casino/<svc>/Dockerfile`, and pushes
`gitea.local:30001/casino/vegasapp-<svc>:<commit-sha>` (plus the `:IMAGE_VERSION`
release tag and `:latest`). Single-arch `linux/amd64` only — no buildx/QEMU, to
respect the 8 GB ceiling.

Then a second job, **`write-back k8s tag`**, runs once all 7 builds succeed: it
rewrites the `vegasapp-*` image refs in `k8s/*.yaml` to the new `:<commit-sha>`
and commits that back to `main` with a `[skip ci]` marker (so it never
re-triggers CI — and `k8s/**` is not a trigger path either). **That commit is
what makes Argo CD redeploy** — you never hand-edit a manifest.

!!! note "Screenshot — Gitea Actions run"
    Capture the **Actions** tab showing the `Build casino images (Gitea CI)` run
    green, with the 7 matrix jobs expanded (`frontend … scoring`) **and** the
    `write-back k8s tag` job. This is the "CI ran in my cluster" evidence.

When the run is green, confirm the package landed:

> **Gitea → `casino` org → Packages** (`http://localhost:30001/casino/-/packages`)

You should see `vegasapp-slots` (and its siblings) with your new `:<commit-sha>`
tag.

!!! note "Screenshot — Gitea Packages registry"
    Capture the **Packages** list for the `casino` org showing `vegasapp-slots`
    at your new SHA tag — the image your cluster just built and stored locally.

## 8. ⑥ Redeploy — Argo CD rolls it automatically

There is **no manual manifest edit** here: the `write-back` job already committed
the new `:<commit-sha>` tag into `k8s/` on `main`, which is exactly the git change
Argo CD watches. Argo auto-syncs within its reconcile interval; the **Refresh** →
**Sync** buttons in the Argo UI (`http://localhost:30002`, Application `casino`)
force it instantly. Pull the write-back commit and watch the slots Deployment roll
to your image:

```bash
git pull origin main          # fetch the CI write-back commit
git --no-pager log -1 --oneline  # -> "ci: redeploy casino at <sha> [skip ci]"

kubectl -n casino rollout status deploy/vegas-casino-slots
kubectl -n casino get deploy vegas-casino-slots -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# -> gitea.local:30001/casino/vegasapp-slots:<commit-sha>
```

The running tag has flipped from the mirrored baseline (`:0.40`) to your commit
SHA — observable proof the loop closed on *your* build.

!!! note "Screenshot — Argo CD sync"
    Capture the Argo CD `casino` Application showing **Synced / Healthy** right
    after the roll, with the slots resource updated. Together with the two Gitea
    captures this is the end-to-end "my edit → my image → my cluster" proof.

!!! warning "Do not `kubectl apply` or `kubectl set image` into the casino namespace"
    Argo CD `selfHeal` reverts any hand-drift — the in-cluster Gitea repo is the
    single source of truth. The pipeline changes the image the GitOps way (CI
    writes `k8s/`, Argo syncs); never patch a running Deployment by hand.

## 9. Verify — your bytes are serving traffic

Prove the running pod is *your* build, not the cached one:

```bash
# the startup marker you added in step ② — printed by the freshly-deployed pod
kubectl -n casino logs deploy/vegas-casino-slots | grep "BUILD MARKER"
# -> BUILD MARKER: local-ci
```

You have now run a change through a CI/CD pipeline that lives entirely inside one
throwaway Kubernetes cluster.

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **Push didn't start a run** | Commit touched only `k8s/` (path filter is `apps/casino/**`), or the message carried `[skip ci]`. | Make an `apps/casino/**` edit in a normal commit, or use **Run workflow** (`workflow_dispatch`) in the Actions tab. |
| **Job queued forever** | The `gitea-act-runner` is offline. | `kubectl -n gitea get pods` — the runner pod should be `Running`; check its logs. Registration is best-effort at bring-up, so a re-run of the GitOps install re-registers it. |
| **`docker login` in CI fails with `dial tcp [::1]:30001: connect: connection refused`** | Gitea builds the OCI token realm from `ROOT_URL` (`http://localhost:30001/v2/token`), and inside the runner pod `localhost` is pod-local — nothing listens there on 30001. | The `registry-realm-forwarder` sidecar in the `gitea-act-runner` pod forwards loopback `:30001` to the Gitea NodePort on the node. If the pod predates the sidecar, re-apply `gitops/install/gitea-act-runner.yaml`. |
| **`ImagePullBackOff` on the new SHA tag** | Argo synced the write-back commit before the build job finished pushing the image. | Wait for the whole Actions run (build **and** `write-back k8s tag`) to go green, then **Refresh** in Argo CD — the kubelet retries the pull. |
| **k8s/ tag never changed** | The `write-back k8s tag` job didn't run — a build matrix job failed, so the write-back (which `needs: build`) was skipped. | Open the Actions run; fix the failing service build and push again. The write-back only fires when all 7 builds succeed. |
| **`git pull` reports no new commit** | CI hasn't finished, or your source edit produced an identical image ref so the sed found nothing to rewrite. | Confirm the Actions run is green; the write-back commits only when a `vegasapp-*` tag actually changes. |
| **`x509`/`http: server gave HTTP response to HTTPS client` on pull** | The node isn't treating `gitea.local:30001` as an insecure registry. | This is the kind containerd mirror (`hosts.toml`) from the environment setup — re-run the GitOps bring-up so the alias is wired. |

## Definition of done

- [ ] You edited a casino service in the in-cluster `casino/casino` repo and
      pushed a normal commit (no manual tag bump, no manifest edit).
- [ ] A **Gitea Actions** run built the image inside the cluster and the
      `write-back k8s tag` job committed the new `:<commit-sha>` into `k8s/`
      (green run in the Actions tab).
- [ ] The image appears in **Gitea Packages** for the `casino` org at your new
      SHA tag.
- [ ] **Argo CD** redeployed the slots Deployment from
      `gitea.local:30001/casino/vegasapp-slots:<commit-sha>` — the running tag
      flipped from the mirrored baseline to your build.
- [ ] You proved the running pod is **your** build (the `BUILD MARKER` log line).
- [ ] You can explain why CI tags each build with the commit SHA and why that
      SHA tag — written into `k8s/` — is what makes Argo CD notice a new build.

Back to the [Catalog](catalog.md) · [The environment](../setup.md).
