#!/usr/bin/env bash
# render-images.sh — resolve the ${IMAGE_OWNER}/${IMAGE_TAG} placeholders in the
# casino manifests (deploy/casino/k8s/*.yaml) into a concrete owner + tag.
#
# This is the single, plain-text image-owner substitution point for the casino
# app (ISI-7587 D4). It deliberately uses `sed` — NOT kustomize/Helm — to keep
# the manifests plain YAML an attendee can read end-to-end (ISI-6794), while
# letting the deploy path repoint images at a fork's GHCR namespace.
#
# Why placeholders instead of a hardcoded owner: on first launch a fresh fork
# pulls the UPSTREAM BASELINE public images (IMAGE_OWNER defaults to the upstream
# owner). When an attendee edits casino app code, their fork's Actions publish
# ghcr.io/<them>/otel-training/vegasapp-<svc>, and the "deploy my build" step
# re-renders with IMAGE_OWNER=<them> (ISI-7589 c3).
#
# Switchable image SOURCE (ISI-7640 / WS-C): IMAGE_SOURCE=gitea repoints the 7
# casino-built vegasapp images from GHCR to the in-cluster Gitea container
# registry alias established by the WS-D spike (ISI-7638):
# gitea.local:30001/<owner>/vegasapp-<svc>. This stays the same plain-text sed
# contract (NO kustomize), so the default (GHCR, D1) render is byte-identical to
# before and the Gitea flip is purely additive. Pull is public/anonymous — no
# imagePullSecret is added either way (D3). Infra images (postgres, redis, curl)
# and the upstream grafana/k6 loadgen (D4) are not casino-built and are left
# untouched in both modes.
#
# Usage:
#   render-images.sh                 # render k8s/ -> stdout (concatenated), GHCR
#   render-images.sh -o OUTDIR       # render each file into OUTDIR (preserves names)
#   IMAGE_OWNER=alice IMAGE_TAG=latest render-images.sh -o /tmp/rendered
#   IMAGE_SOURCE=gitea render-images.sh -o /tmp/rendered   # flip to the Gitea alias
#
# Env:
#   IMAGE_OWNER   GHCR namespace owner       (default: henrikrexed — upstream baseline)
#   IMAGE_TAG     image tag                  (default: ./IMAGE_VERSION, else latest)
#   CLUSTER_NAME  per-attendee cluster name  (default: otel-training) — rendered into
#                 K8S_CLUSTER_NAME + each OTEL_RESOURCE_ATTRIBUTES so every attendee's
#                 telemetry carries a unique k8s.cluster.name for per-participant DQL
#                 filtering on a shared tenant (ISI-7654 / D1).
#   IMAGE_SOURCE  ghcr | gitea               (default: ghcr) — image registry to target.
#                 gitea rewrites casino images to the ISI-7638 registry alias.
#   GITEA_REGISTRY  Gitea registry alias     (default: gitea.local:30001) — WS-D contract.
#   GITEA_OWNER     Gitea packages owner/org (default: casino) — CASINO_ORG in seed-gitea.sh.
#   SRC_DIR       source manifests directory (default: <this dir>/k8s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default tag = the immutable version CI publishes (ISI-7625 D1). IMAGE_VERSION
# is the single source of truth, read by both this renderer and the build
# workflow (.github/workflows/casino-images.yml) so the tag the manifests pin
# always exists as a published package. Fall back to :latest only if the file
# is absent (older checkouts / unexpected layout).
VERSION_FILE="$SCRIPT_DIR/IMAGE_VERSION"
if [[ -r "$VERSION_FILE" ]]; then
  DEFAULT_TAG="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
DEFAULT_TAG="${DEFAULT_TAG:-latest}"

IMAGE_OWNER="${IMAGE_OWNER:-henrikrexed}"
IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_TAG}"
# Per-attendee cluster name (ISI-7654 / D1). Defaults to the shared historical
# name so a render without a cluster name is a no-op change vs the old hardcode.
CLUSTER_NAME="${CLUSTER_NAME:-otel-training}"
SRC_DIR="${SRC_DIR:-$SCRIPT_DIR/k8s}"

# Image source switch (ISI-7640 / WS-C). ghcr = default running state (D1);
# gitea = the in-cluster Gitea registry alias from the WS-D spike (ISI-7638).
IMAGE_SOURCE="${IMAGE_SOURCE:-ghcr}"
GITEA_REGISTRY="${GITEA_REGISTRY:-gitea.local:30001}"
GITEA_OWNER="${GITEA_OWNER:-casino}"
case "$IMAGE_SOURCE" in
  ghcr|gitea) ;;
  *) echo "render-images.sh: IMAGE_SOURCE must be 'ghcr' or 'gitea', got '$IMAGE_SOURCE'" >&2; exit 2 ;;
esac

OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "render-images.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$SRC_DIR" ]]; then
  echo "render-images.sh: SRC_DIR not found: $SRC_DIR" >&2
  exit 1
fi

# GHCR namespaces are lowercase; a fork owner login may be mixed-case. Normalise
# defensively so a substituted reference is always a valid image name.
IMAGE_OWNER="$(printf '%s' "$IMAGE_OWNER" | tr '[:upper:]' '[:lower:]')"

# Only these placeholders are substituted — nothing else in the YAML is touched.
# When IMAGE_SOURCE=gitea, a second, additive sed rewrites ONLY the casino-built
# vegasapp images (ghcr.io/<owner>/otel-training/vegasapp-*) to the Gitea alias
# (<GITEA_REGISTRY>/<GITEA_OWNER>/vegasapp-*). The owner segment is already a
# concrete value by then, so [^/]* matches it; the tag is preserved. postgres,
# redis, curl and grafana/k6 don't match the pattern and stay on their upstreams.
render() {
  sed -e "s|\${IMAGE_OWNER}|${IMAGE_OWNER}|g" \
      -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
      -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" "$1" \
  | if [[ "$IMAGE_SOURCE" == "gitea" ]]; then
      sed -e "s|ghcr\.io/[^/]*/otel-training/vegasapp-|${GITEA_REGISTRY}/${GITEA_OWNER}/vegasapp-|g"
    else
      cat
    fi
}

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  for f in "$SRC_DIR"/*.yaml; do
    render "$f" > "$OUT_DIR/$(basename "$f")"
  done
  echo "render-images.sh: wrote $(ls "$SRC_DIR"/*.yaml | wc -l | tr -d ' ') manifest(s) to $OUT_DIR (source=$IMAGE_SOURCE owner=$IMAGE_OWNER tag=$IMAGE_TAG cluster=$CLUSTER_NAME)" >&2
else
  for f in "$SRC_DIR"/*.yaml; do
    render "$f"
    echo "---"
  done
fi
