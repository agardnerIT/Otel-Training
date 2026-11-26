#!/usr/bin/env bash
# mirror-baseline-images.sh — copy the baseline casino images from GHCR into the
# in-cluster Gitea container registry at bootstrap, so a cold-start codespace has
# images to pull when the seeded manifests reference gitea.local:30001 by default
# (ISI-7881 / ISI-7867 gap 2).
#
# WHY this exists:
#   seed-gitea.sh now defaults IMAGE_SOURCE=gitea (ISI-7881 gap 1), so Argo CD
#   syncs casino Deployments that pull gitea.local:30001/casino/vegasapp-*:<tag>.
#   But the seed push carries `[skip ci]`, so Gitea Actions builds NOTHING at
#   bootstrap and the Gitea registry is EMPTY on first boot -> every casino pod
#   would ImagePullBackOff. This step pre-populates those 7 refs by COPYING the
#   already-published upstream GHCR baseline images into Gitea.
#
# MIRROR, do NOT build: `crane copy` pulls each image's manifest + blobs and
# re-pushes them to Gitea — no docker build, no source compile. This is the whole
# point: D1 (ISI-7624) removed the 7 in-cluster `docker build`s from bootstrap
# because they blew the 8 GB codespace budget; this must not reintroduce them.
#
# Addressing (gitops/install/registry-mirror.md, ISI-7638):
#   push (here, from the codespace host):  localhost:<NodePort>/<owner>/vegasapp-*
#   pull (casino Deployments, on the node): gitea.local:30001/<owner>/vegasapp-*
#   Same registry + same repo path; the node containerd hosts.toml mirror
#   (create-cluster.sh) rewrites the alias to http://localhost:30001.
#
# Contract (project precedent): idempotent (crane copy re-push is a no-op when the
# digest already exists) and NON-FATAL + LOUD — a mirror hiccup must never abort
# the GitOps bootstrap (ISI-7555). Exit is always 0; the per-image result and a
# final summary are printed so a failure is obvious. gitops/verify.sh + the
# casino-health gate in bootstrap are the authorities on the true end state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# No-op unless we're on the Gitea image source (the new default). On IMAGE_SOURCE=ghcr
# the manifests pull straight from GHCR, so there is nothing to mirror.
IMAGE_SOURCE="${IMAGE_SOURCE:-gitea}"

# Source (GHCR) coordinates. Baseline owner = upstream (henrikrexed); overridable
# so a fork can mirror its own published images. The path segment is fixed by the
# casino CI layout: ghcr.io/<owner>/otel-training/vegasapp-<svc>.
GHCR_REGISTRY="${GHCR_REGISTRY:-ghcr.io}"
IMAGE_OWNER="${IMAGE_OWNER:-henrikrexed}"
GHCR_PATH="${GHCR_PATH:-otel-training}"

# Destination (Gitea) coordinates — must match render-images.sh's gitea rewrite
# (GITEA_REGISTRY/GITEA_OWNER) so the mirrored refs are exactly what Argo pulls.
GITEA_NODEPORT="${GITEA_NODEPORT:-30001}"
GITEA_REGISTRY="${GITEA_REGISTRY:-gitea.local:${GITEA_NODEPORT}}"
GITEA_OWNER="${GITEA_OWNER:-${CASINO_ORG:-casino}}"
# Push over the host loopback NodePort (same endpoint the alias resolves to); the
# stored repo path (<owner>/vegasapp-*) is identical regardless of the push host.
PUSH_HOST="${PUSH_HOST:-localhost:${GITEA_NODEPORT}}"
GITEA_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"

# Tag: the immutable version both the renderer and CI pin (deploy/casino/IMAGE_VERSION).
VERSION_FILE="$REPO_ROOT/deploy/casino/IMAGE_VERSION"
DEFAULT_TAG="latest"
[[ -r "$VERSION_FILE" ]] && DEFAULT_TAG="$(tr -d '[:space:]' < "$VERSION_FILE")"
IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_TAG}"

CRANE="${CRANE:-crane}"
CASINO_PROFILE="${CASINO_PROFILE:-full}"

# Baseline-tag fallback (ISI-7881 / pairs with ISI-7826 + child 2, gap 3). The
# seeded manifests pin IMAGE_TAG (= deploy/casino/IMAGE_VERSION). If that exact
# tag is NOT yet published on GHCR — e.g. IMAGE_VERSION was bumped to ship a fix
# but the public build has not caught up (5592fdb bumped 0.39->0.40 for the Deal
# fix, ISI-7826, while GHCR still only serves 0.39/latest) — then a strict mirror
# would leave the Gitea registry without the pinned tag and every casino pod would
# ImagePullBackOff on cold-start. To keep the first boot green, fall back to
# copying the newest public baseline (BASELINE_FALLBACK_TAG, default 'latest')
# INTO the pinned Gitea tag, LOUDLY. The authoritative pinned-tag image is then
# produced by the in-cluster CI write-back loop (child 2). Set
# MIRROR_TAG_FALLBACK=false to disable and fail instead when the pinned tag is
# absent on GHCR.
MIRROR_TAG_FALLBACK="${MIRROR_TAG_FALLBACK:-true}"
BASELINE_FALLBACK_TAG="${BASELINE_FALLBACK_TAG:-latest}"

log()  { echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }

# The 7 casino-BUILT services (the ones render-images.sh rewrites to Gitea).
# postgres/redis/curl and grafana/k6 are upstream infra images, pulled straight
# from their public registries in both modes, so they are intentionally NOT
# mirrored here.
SERVICES=(blackjack dashboard dice frontend roulette scoring slots)

# Casino "lite" profile (ISI-7653): only the deployed games get mirrored. Drop
# roulette+dice so a lite bring-up does not waste time/space on images it never
# pulls — mirror exactly the set the seeded (lite-filtered) manifests reference.
if [[ "$CASINO_PROFILE" == "lite" ]]; then
  log "CASINO_PROFILE=lite — mirroring only the lite service set (dropping roulette, dice)"
  _lite=(); for s in "${SERVICES[@]}"; do [[ "$s" == "roulette" || "$s" == "dice" ]] && continue; _lite+=("$s"); done
  SERVICES=("${_lite[@]}")
fi

if [[ "$IMAGE_SOURCE" != "gitea" ]]; then
  log "IMAGE_SOURCE=$IMAGE_SOURCE (not 'gitea') — manifests pull from GHCR directly; nothing to mirror. Skipping."
  exit 0
fi

if ! command -v "$CRANE" >/dev/null 2>&1; then
  warn "crane not found on PATH — CANNOT mirror baseline images GHCR->Gitea."
  warn "Install it (FORCE=1 bash .devcontainer/bootstrap/install-tools.sh) and re-run:"
  warn "  bash $SCRIPT_DIR/mirror-baseline-images.sh"
  warn "Until then, casino pods referencing gitea.local:${GITEA_NODEPORT} will ImagePullBackOff."
  exit 0   # non-fatal: bootstrap continues; this is loud enough to act on
fi

# Wait (best-effort, short) for the Gitea registry /v2/ endpoint on the host
# loopback. Loud on timeout; still attempt the copies (crane will report per-image).
log "waiting for the Gitea registry at http://${PUSH_HOST}/v2/ (up to 60s)"
REG_UP=0
for i in $(seq 1 30); do
  if curl -fsS "http://${PUSH_HOST}/v2/" >/dev/null 2>&1 || curl -fsS -o /dev/null -w '%{http_code}' "http://${PUSH_HOST}/v2/" 2>/dev/null | grep -qE '^(200|401)$'; then
    REG_UP=1; break
  fi
  sleep 2
done
[[ "$REG_UP" -eq 1 ]] || warn "Gitea registry did not answer on ${PUSH_HOST} within 60s — attempting copies anyway (crane will report)."

# Authenticate the push side (Gitea requires auth to push packages). Anonymous
# PULL by the nodes works when the '$GITEA_OWNER' org is public (Gitea default),
# so render-images.sh adds no imagePullSecret (D3). Login is best-effort: a public
# registry push may not need it, so a login failure is only a warning.
if echo "$GITEA_PASS" | "$CRANE" auth login "$PUSH_HOST" -u "$GITEA_USER" --password-stdin --insecure >/dev/null 2>&1; then
  log "crane authenticated to $PUSH_HOST as '$GITEA_USER'"
else
  warn "crane auth login to $PUSH_HOST failed (continuing; push may still work if the registry allows it)"
fi

log "mirroring ${#SERVICES[@]} baseline casino image(s) ${GHCR_REGISTRY}/${IMAGE_OWNER}/${GHCR_PATH}/vegasapp-* : ${IMAGE_TAG} -> ${PUSH_HOST}/${GITEA_OWNER}/vegasapp-* (also :latest)"
src_base="${GHCR_REGISTRY}/${IMAGE_OWNER}/${GHCR_PATH}"
copied=0; failed=0; fellback=0
for svc in "${SERVICES[@]}"; do
  src_repo="${src_base}/vegasapp-${svc}"
  dst="${PUSH_HOST}/${GITEA_OWNER}/vegasapp-${svc}:${IMAGE_TAG}"
  dst_latest="${PUSH_HOST}/${GITEA_OWNER}/vegasapp-${svc}:latest"

  # Resolve the source tag: prefer the pinned IMAGE_TAG; fall back to
  # BASELINE_FALLBACK_TAG (loudly) only if the pinned tag is absent on GHCR.
  src_tag="$IMAGE_TAG"
  if ! "$CRANE" manifest "${src_repo}:${IMAGE_TAG}" >/dev/null 2>&1; then
    if [[ "$MIRROR_TAG_FALLBACK" == "true" ]] && "$CRANE" manifest "${src_repo}:${BASELINE_FALLBACK_TAG}" >/dev/null 2>&1; then
      warn "  vegasapp-${svc}: pinned tag '${IMAGE_TAG}' not published on GHCR — mirroring '${BASELINE_FALLBACK_TAG}' content INTO Gitea tag '${IMAGE_TAG}' (cold-start baseline; the real '${IMAGE_TAG}' build comes from in-cluster CI — ISI-7826 / child 2)"
      src_tag="$BASELINE_FALLBACK_TAG"
      fellback=$((fellback + 1))
    else
      warn "  vegasapp-${svc}: neither '${IMAGE_TAG}' nor fallback '${BASELINE_FALLBACK_TAG}' is available on GHCR (${src_repo}) — skipping"
      failed=$((failed + 1))
      continue
    fi
  fi

  src="${src_repo}:${src_tag}"
  log "  vegasapp-${svc}: $src -> $dst"
  if "$CRANE" copy "$src" "$dst" --insecure 2>&1 | sed 's/^/      crane: /'; then
    # Tag :latest too (best-effort) so a `:latest` render also resolves. A second
    # copy from the just-pushed Gitea ref avoids re-pulling GHCR.
    "$CRANE" copy "$dst" "$dst_latest" --insecure >/dev/null 2>&1 \
      || warn "    could not also tag vegasapp-${svc}:latest (continuing)"
    copied=$((copied + 1))
  else
    warn "    FAILED to mirror vegasapp-${svc} (the Gitea registry rejected the push, or ${src} became unavailable)"
    failed=$((failed + 1))
  fi
done

echo ""
log "mirror summary: ${copied}/${#SERVICES[@]} image(s) copied to ${PUSH_HOST}/${GITEA_OWNER}/ (tag ${IMAGE_TAG} + latest); ${fellback} used the '${BASELINE_FALLBACK_TAG}' fallback; ${failed} failed"
if [[ "$fellback" -gt 0 ]]; then
  warn "${fellback} image(s) were mirrored from '${BASELINE_FALLBACK_TAG}' because the pinned tag '${IMAGE_TAG}' is not published on GHCR."
  warn "This keeps cold-start green, but the pinned '${IMAGE_TAG}' content is the newest PUBLIC build, not a build of the '${IMAGE_TAG}' source. The authoritative '${IMAGE_TAG}' image is produced by the in-cluster CI write-back loop (ISI-7826 / child 2)."
fi
if [[ "$failed" -gt 0 ]]; then
  warn "${failed} image(s) did not mirror — casino pods for those services will ImagePullBackOff until fixed."
  warn "Re-run (idempotent): bash $SCRIPT_DIR/mirror-baseline-images.sh"
  warn "Check: are the GHCR baseline images public at tag '${IMAGE_TAG}'? is the Gitea registry up on NodePort ${GITEA_NODEPORT}?"
fi
# Always exit 0 — non-fatal by contract (ISI-7555); the summary above is the signal.
exit 0
