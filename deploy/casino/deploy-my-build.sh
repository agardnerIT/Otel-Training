#!/usr/bin/env bash
# deploy-my-build.sh — the in-lab "deploy MY build" step (ISI-7589 c3).
#
# The casino app launches on the UPSTREAM baseline images (zero pre-build). This
# script is the explicit attendee action that repoints the running casino at the
# images THEIR OWN fork just built, after they:
#
#   1. edit a service under apps/casino/<svc>/,
#   2. commit + push to their fork's main (or a training/** branch),
#   3. let the fork's Actions (.github/workflows/casino-images.yml) build + publish
#      ghcr.io/<me>/otel-training/vegasapp-*:<tag>   (~1-3 min).
#
# Then run this. It:
#   * derives <me> from the fork's git origin,
#   * PREFLIGHTS that the fork images actually exist at the pinned tag — if not,
#     it changes NOTHING and tells you your Actions run hasn't finished yet,
#   * wires the ghcr-pull imagePullSecret (fork packages may be private),
#   * re-points the casino to ghcr.io/<me>/… and redeploys:
#       - GitOps mode (default): re-seeds Gitea with IMAGE_OWNER=<me> and nudges
#         Argo CD to sync — the same edit->commit->sync loop, just for images.
#       - direct mode (DEPLOY_MODE=direct): renders + kubectl applies straight.
#
# Idempotent and safe to re-run. Re-running with no new fork build is a no-op.
#
# Env:
#   IMAGE_OWNER     force a specific owner (default: derived from git origin)
#   IMAGE_TAG       image tag             (default: deploy/casino/IMAGE_VERSION)
#   DEPLOY_MODE     gitops (default) | direct
#   ARGOCD_APP      Argo CD Application name to refresh (default: casino)
#   CASINO_NAMESPACE casino namespace     (default: casino)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
DEPLOY_MODE="${DEPLOY_MODE:-gitops}"
ARGOCD_APP="${ARGOCD_APP:-casino}"
CASINO_NAMESPACE="${CASINO_NAMESPACE:-casino}"

log()  { echo "==> deploy-my-build: $*"; }
warn() { echo "==> deploy-my-build: WARN: $*" >&2; }
die()  { echo "==> deploy-my-build: ERROR: $*" >&2; exit 1; }

# shellcheck source=deploy/casino/image-owner.sh
source "$SCRIPT_DIR/image-owner.sh"

TAG="${IMAGE_TAG:-$(casino_default_tag)}"

# Owner: an explicit IMAGE_OWNER wins; otherwise the fork owner from origin. We do
# NOT use casino_resolve_image_owner here because THIS command is specifically
# "deploy my fork build" — it must target the fork and fail loudly if that build
# is not published, rather than silently settling on baseline.
if [[ -n "${IMAGE_OWNER:-}" ]]; then
  OWNER="$(printf '%s' "$IMAGE_OWNER" | tr '[:upper:]' '[:lower:]')"
  log "using explicit IMAGE_OWNER=$OWNER"
else
  OWNER="$(casino_fork_owner_from_origin "$REPO_ROOT")"
  log "derived owner '$OWNER' from this repo's git origin"
fi

if [[ "$OWNER" == "$CASINO_UPSTREAM_OWNER" ]]; then
  cat >&2 <<EOF

This repo's origin is the UPSTREAM repo ($CASINO_UPSTREAM_OWNER), so there is no
fork build to deploy — the casino is already on the baseline images.

To use "deploy my build": fork the repo on GitHub, launch your codespace from
YOUR fork, edit a service under apps/casino/<svc>/, push to your fork, let the
fork's Actions publish the images, then re-run this script.
EOF
  exit 0
fi

# PREFLIGHT — the gate that keeps a not-yet-built fork on baseline (acceptance).
log "preflighting ghcr.io/$OWNER/$CASINO_IMAGE_REPO/$CASINO_PREFLIGHT_IMAGE:$TAG"
if ! casino_preflight_image "$OWNER" "$TAG"; then
  cat >&2 <<EOF

No published fork image found at:
    ghcr.io/$OWNER/$CASINO_IMAGE_REPO/vegasapp-*:$TAG

Nothing was changed — the casino stays on the upstream baseline images.

Most likely your fork's build is still running (it takes ~1-3 min after a push).
Check it at:  https://github.com/$OWNER/otel-training/actions

One-time prerequisite: a brand-new fork has Actions DISABLED. Enable them once at
    https://github.com/$OWNER/otel-training/actions  ->  "I understand my workflows, go ahead and enable them"
then push again so the "Build casino images" workflow runs.

Re-run this script once the run is green.
EOF
  exit 1
fi
log "fork images present — repointing the casino to ghcr.io/$OWNER/…:$TAG"

# Wire the pull secret (fork packages may be private). No-op when a token is
# absent / the images are public; non-fatal either way.
log "ensuring the ghcr-pull imagePullSecret (for private fork images)"
CASINO_NAMESPACE="$CASINO_NAMESPACE" CASINO_PULL_USER="${CASINO_PULL_USER:-$OWNER}" \
  bash "$REPO_ROOT/gitops/install/ensure-casino-pull-secret.sh" \
  || warn "ensure-casino-pull-secret.sh reported errors (continuing — images may be public)"

case "$DEPLOY_MODE" in
  gitops)
    # Re-seed Gitea with the fork owner — seed-gitea.sh honours an explicit
    # IMAGE_OWNER (override wins in casino_resolve_image_owner), re-renders the
    # manifests at ghcr.io/<me>/… and force-pushes to the casino repo. Argo CD
    # then syncs the new image refs (same edit->commit->sync loop as a manifest
    # change). seed-gitea.sh is idempotent.
    log "re-seeding Gitea casino repo with IMAGE_OWNER=$OWNER (Argo CD will sync)"
    IMAGE_OWNER="$OWNER" IMAGE_TAG="$TAG" bash "$REPO_ROOT/gitops/install/seed-gitea.sh"

    # Nudge Argo CD to refresh immediately instead of waiting for its poll. The
    # hard-refresh annotation is watched by the application controller; if argocd
    # isn't installed/this Application isn't present yet, this is a harmless no-op.
    if $KUBECTL -n argocd get application "$ARGOCD_APP" >/dev/null 2>&1; then
      log "triggering Argo CD hard refresh of Application '$ARGOCD_APP'"
      $KUBECTL -n argocd annotate application "$ARGOCD_APP" \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 \
        || warn "could not annotate Application '$ARGOCD_APP' (it will sync on its next poll)"
    else
      warn "Argo CD Application '$ARGOCD_APP' not found — it will sync once installed"
    fi
    ;;

  direct)
    # No Argo CD — render with the fork owner and apply straight in.
    log "DEPLOY_MODE=direct — rendering + applying ghcr.io/$OWNER/…:$TAG to namespace '$CASINO_NAMESPACE'"
    $KUBECTL create namespace "$CASINO_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
    APPLY_DIR="$(mktemp -d)"
    trap 'rm -rf "$APPLY_DIR"' EXIT
    SRC_DIR="$REPO_ROOT/deploy/casino/k8s" IMAGE_OWNER="$OWNER" IMAGE_TAG="$TAG" \
      CLUSTER_NAME="${CLUSTER_NAME:-${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}}" \
      bash "$REPO_ROOT/deploy/casino/render-images.sh" -o "$APPLY_DIR" \
      || die "render-images.sh failed — refusing to apply unrendered manifests"
    $KUBECTL -n "$CASINO_NAMESPACE" apply -f "$APPLY_DIR"
    # Force a fresh pull of the (possibly same-tag) images.
    $KUBECTL -n "$CASINO_NAMESPACE" rollout restart deploy -l app.kubernetes.io/name=vegas-casino \
      || warn "rollout restart reported errors (new pods still pick up the applied image refs)"
    ;;

  *)
    die "DEPLOY_MODE must be 'gitops' or 'direct' (got '$DEPLOY_MODE')"
    ;;
esac

cat <<EOF

================================================================
 Deployed YOUR build.
   Images:  ghcr.io/$OWNER/$CASINO_IMAGE_REPO/vegasapp-*:$TAG
   Mode:    $DEPLOY_MODE
   Watch:   kubectl -n $CASINO_NAMESPACE get pods -w
$( [[ "$DEPLOY_MODE" == gitops ]] && echo "   Argo CD: kubectl -n argocd get application $ARGOCD_APP" )
================================================================
EOF
