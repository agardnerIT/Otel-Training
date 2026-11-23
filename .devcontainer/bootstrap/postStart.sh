#!/usr/bin/env bash
# postStart.sh — runs EVERY time the codespace starts (including stop/resume).
#
# A kind cluster lives inside the docker-in-docker daemon, which is wiped on a
# full rebuild but preserved across a stop/resume. This re-attaches the kubeconfig
# and heals the cluster if the daemon restarted, so attendees always resume into a
# healthy `kubectl get nodes`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "==> $*"; }

# Single `.env` flow (ISI-7629 / #61): reload the canonical repo-root `.env` on
# every start/resume so a FULL_DEPLOY reconverge and the cluster name stay in
# sync with the attendee's values. No-op in Codespaces.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/load-env.sh"

log "ensuring kind cluster is healthy after start/resume"
bash "$SCRIPT_DIR/create-cluster.sh" || {
  echo "WARN: cluster not healthy on start; re-run manually:" >&2
  echo "WARN:   bash .devcontainer/bootstrap/create-cluster.sh" >&2
  exit 0   # non-fatal: don't block the codespace from opening
}

# opencode⇄Gitea credentials (ISI-7711). gitea-token.sh writes
# ~/.workshop-gitea.env (GITEA_TOKEN/URL/USER). Source it here so any Gitea step
# in this script has the creds, and install a one-time managed snippet so every
# attendee shell (and opencode) picks up the creds and gets the helper scripts
# on PATH. All idempotent + non-fatal — a codespace that never minted a token
# still opens cleanly.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSHOP_GITEA_ENV="$HOME/.workshop-gitea.env"
if [ -f "$WORKSHOP_GITEA_ENV" ]; then
  log "sourcing Gitea credentials from $WORKSHOP_GITEA_ENV"
  # shellcheck disable=SC1090
  set -a; . "$WORKSHOP_GITEA_ENV" || true; set +a
fi
BASHRC="$HOME/.bashrc"
MARKER="# >>> otel-training opencode<->gitea (ISI-7711) >>>"
if [ -f "$BASHRC" ] && ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  log "wiring opencode⇄Gitea into ~/.bashrc (token + helper scripts on PATH)"
  {
    echo "$MARKER"
    echo '[ -f "$HOME/.workshop-gitea.env" ] && set -a && . "$HOME/.workshop-gitea.env" && set +a'
    echo "export PATH=\"$REPO_ROOT/gitops/opencode:\$PATH\""
    echo "# <<< otel-training opencode<->gitea (ISI-7711) <<<"
  } >> "$BASHRC" || true
fi
