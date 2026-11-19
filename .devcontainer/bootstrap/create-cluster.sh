#!/usr/bin/env bash
# create-cluster.sh — stand up (or re-attach to) the attendee's kind cluster.
#
# Idempotent: if the cluster already exists it only refreshes the kubeconfig and
# waits for readiness, so it is safe to call from both postCreate and postStart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Records the cluster name this repo actually created, so a later run with the
# knobs unset re-attaches to it instead of spawning a second default-named
# cluster (ISI-7629 / #65 — deterministic naming).
STATE_FILE="${OTEL_TRAINING_CLUSTER_STATE:-$HOME/.otel-training-cluster}"

# Deterministic cluster name resolution (ISI-7629 / #65):
#   1. KIND_CLUSTER_NAME wins when explicitly set (advanced override).
#   2. else PARTICIPANT_ID (the attendee-unique knob).
#   3. else the name we recorded on a PREVIOUS create — so an unset-knob rerun
#      re-attaches to the same cluster instead of creating a second one named
#      `otel-training` beside it.
#   4. else the `otel-training` default.
if [[ -n "${KIND_CLUSTER_NAME:-}" ]]; then
  CLUSTER_NAME="$KIND_CLUSTER_NAME"
elif [[ -n "${PARTICIPANT_ID:-}" ]]; then
  CLUSTER_NAME="$PARTICIPANT_ID"
elif [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
  CLUSTER_NAME="$(tr -d '[:space:]' < "$STATE_FILE")"
else
  CLUSTER_NAME="otel-training"
fi
export KIND_CLUSTER_NAME="$CLUSTER_NAME"   # make the resolved name authoritative downstream
KIND_CONFIG="${KIND_CONFIG:-$SCRIPT_DIR/kind-config.yaml}"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

log() { echo "==> $*"; }

# Local host/reliability preflight (non-fatal). Surfaces inotify/cpu/memory
# floors and any stray differently-named kind cluster before we create ours.
if [[ -x "$SCRIPT_DIR/preflight.sh" || -f "$SCRIPT_DIR/preflight.sh" ]]; then
  KIND_CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/preflight.sh" || true
fi

wait_for_docker() {
  # docker-in-docker may still be starting when onCreate fires.
  local tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 60 ]]; then
      echo "ERROR: Docker daemon did not become ready in time." >&2
      exit 1
    fi
    log "waiting for Docker daemon... ($tries)"
    sleep 2
  done
  log "Docker is ready"
}

ensure_cluster() {
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "kind cluster '$CLUSTER_NAME' already exists — exporting kubeconfig"
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_PATH"
  else
    log "creating kind cluster '$CLUSTER_NAME'"
    kind create cluster \
      --name "$CLUSTER_NAME" \
      --config "$KIND_CONFIG" \
      --kubeconfig "$KUBECONFIG_PATH" \
      --wait 120s
  fi
}

wait_ready() {
  log "waiting for node(s) to be Ready"
  kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready nodes --all --timeout=120s
  kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
}

record_state() {
  # Persist the resolved name so a later knob-unset rerun re-attaches here
  # rather than spawning a second `otel-training` cluster (deterministic naming).
  printf '%s\n' "$CLUSTER_NAME" > "$STATE_FILE" 2>/dev/null || true
}

main() {
  wait_for_docker
  ensure_cluster
  record_state
  wait_ready
  log "cluster '$CLUSTER_NAME' healthy; KUBECONFIG=$KUBECONFIG_PATH"
}
main "$@"
