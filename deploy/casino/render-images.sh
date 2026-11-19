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
# Usage:
#   render-images.sh                 # render k8s/ -> stdout (concatenated)
#   render-images.sh -o OUTDIR       # render each file into OUTDIR (preserves names)
#   IMAGE_OWNER=alice IMAGE_TAG=latest render-images.sh -o /tmp/rendered
#
# Env:
#   IMAGE_OWNER   GHCR namespace owner       (default: henrikrexed — upstream baseline)
#   IMAGE_TAG     image tag                  (default: ./IMAGE_VERSION, else latest)
#   CLUSTER_NAME  per-attendee cluster name  (default: otel-training) — rendered into
#                 K8S_CLUSTER_NAME + each OTEL_RESOURCE_ATTRIBUTES so every attendee's
#                 telemetry carries a unique k8s.cluster.name for per-participant DQL
#                 filtering on a shared tenant (ISI-7654 / D1).
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
render() {
  sed -e "s|\${IMAGE_OWNER}|${IMAGE_OWNER}|g" \
      -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
      -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" "$1"
}

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  for f in "$SRC_DIR"/*.yaml; do
    render "$f" > "$OUT_DIR/$(basename "$f")"
  done
  echo "render-images.sh: wrote $(ls "$SRC_DIR"/*.yaml | wc -l | tr -d ' ') manifest(s) to $OUT_DIR (owner=$IMAGE_OWNER tag=$IMAGE_TAG cluster=$CLUSTER_NAME)" >&2
else
  for f in "$SRC_DIR"/*.yaml; do
    render "$f"
    echo "---"
  done
fi
