#!/usr/bin/env bash
# preflight.sh — local Docker Desktop / host reliability checks (ISI-7629 / #65).
#
# Running kind + the casino + collectors + operators needs real host headroom,
# and a Linux/WSL2 host needs enough inotify watches or file watchers silently
# fail. These are the failure modes that make a LOCAL dev-container run flaky
# where a Codespace "just works". This script surfaces them early with concrete
# remediation.
#
# Design: WARN, never block. Codespaces can't tune host sysctls, and we must
# never stop a container from opening — so every check prints guidance and the
# script always exits 0. Call it before create-cluster.sh stands up kind.
#
# It also lists kind clusters so a stray, differently-named cluster from an
# earlier run is visible (and can be cleaned with CLEANUP_STRAY=1, see below).
set -uo pipefail

# --- Floors (minimum local machine) -----------------------------------------
# Mirror devcontainer.json hostRequirements (4 cpu / 8gb / 32gb) as soft floors.
MIN_CPUS="${PREFLIGHT_MIN_CPUS:-4}"
MIN_MEM_GB="${PREFLIGHT_MIN_MEM_GB:-8}"
MIN_WATCHES="${PREFLIGHT_MIN_WATCHES:-524288}"
MIN_INSTANCES="${PREFLIGHT_MIN_INSTANCES:-512}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}"

BOLD=$'\033[1m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[1;32m'; RST=$'\033[0m'
hdr()  { echo; echo "${BOLD}==> preflight: $*${RST}"; }
ok()   { echo "    ${GREEN}✓${RST} $*"; }
warn() { echo "    ${YELLOW}!${RST} $*"; }

warned=0

hdr "CPU / memory floor (local minimum ${MIN_CPUS} vCPU / ${MIN_MEM_GB} GB)"
cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
if [ "$cpus" -ge "$MIN_CPUS" ] 2>/dev/null; then
  ok "CPUs: $cpus (>= $MIN_CPUS)"
else
  warned=1
  warn "CPUs: $cpus (< $MIN_CPUS). On Docker Desktop raise Settings → Resources →"
  warn "  CPUs to at least ${MIN_CPUS}; kind + casino + collectors will thrash below that."
fi

mem_kb="$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
# Round to the nearest GB (+512 MiB before the divide): a nominal-8 GB host
# reports ~7.7 GiB of MemTotal, which a floor divide would mis-flag as 7.
mem_gb=$(( (mem_kb + 524288) / 1024 / 1024 ))
if [ "$mem_gb" -ge "$MIN_MEM_GB" ] 2>/dev/null; then
  ok "Memory: ${mem_gb} GB (>= ${MIN_MEM_GB} GB)"
else
  warned=1
  warn "Memory: ${mem_gb} GB (< ${MIN_MEM_GB} GB). On Docker Desktop raise Settings →"
  warn "  Resources → Memory to at least ${MIN_MEM_GB} GB (WSL2: set it in .wslconfig)."
fi

hdr "inotify limits (file watchers for kind / kubectl / collectors)"
watches="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
instances="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
if [ "$watches" -ge "$MIN_WATCHES" ] 2>/dev/null; then
  ok "fs.inotify.max_user_watches: $watches (>= $MIN_WATCHES)"
else
  warned=1
  warn "fs.inotify.max_user_watches: $watches (< $MIN_WATCHES). Raise it on the host:"
  warn "  sudo sysctl -w fs.inotify.max_user_watches=$MIN_WATCHES"
  warn "  (persist: echo 'fs.inotify.max_user_watches=$MIN_WATCHES' | sudo tee /etc/sysctl.d/99-otel-training.conf)"
fi
if [ "$instances" -ge "$MIN_INSTANCES" ] 2>/dev/null; then
  ok "fs.inotify.max_user_instances: $instances (>= $MIN_INSTANCES)"
else
  warned=1
  warn "fs.inotify.max_user_instances: $instances (< $MIN_INSTANCES). Raise it on the host:"
  warn "  sudo sysctl -w fs.inotify.max_user_instances=$MIN_INSTANCES"
fi

hdr "kind clusters (stray-cluster check — this run uses '${CLUSTER_NAME}')"
if command -v kind >/dev/null 2>&1; then
  mapfile -t clusters < <(kind get clusters 2>/dev/null || true)
  if [ "${#clusters[@]}" -eq 0 ]; then
    ok "no kind clusters yet — a clean create of '${CLUSTER_NAME}'"
  else
    strays=()
    for c in "${clusters[@]}"; do
      [ -n "$c" ] || continue
      if [ "$c" = "$CLUSTER_NAME" ]; then
        ok "found expected cluster '$c'"
      else
        strays+=("$c")
      fi
    done
    if [ "${#strays[@]}" -gt 0 ]; then
      warned=1
      warn "stray kind cluster(s) not matching '${CLUSTER_NAME}': ${strays[*]}"
      warn "  A second, differently-named cluster wastes memory and confuses telemetry."
      if [ "${CLEANUP_STRAY:-0}" = "1" ]; then
        for s in "${strays[@]}"; do
          warn "  CLEANUP_STRAY=1 → deleting stray cluster '$s'"
          kind delete cluster --name "$s" || warn "  (failed to delete '$s' — remove it manually)"
        done
      else
        warn "  Remove one with:  kind delete cluster --name <name>"
        warn "  Or re-run with CLEANUP_STRAY=1 to delete every cluster except '${CLUSTER_NAME}'."
      fi
    fi
  fi
else
  warn "kind not on PATH yet (install-tools.sh runs first in postCreate)"
fi

echo
if [ "$warned" -eq 0 ]; then
  ok "preflight clean — host looks ready for a local run"
else
  warn "preflight raised warnings above. They are non-fatal; address them for a smooth local run."
fi
exit 0
