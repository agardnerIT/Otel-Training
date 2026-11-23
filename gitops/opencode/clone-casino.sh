#!/usr/bin/env bash
# clone-casino.sh — clone the casino repo from the in-cluster Gitea into
# $HOME/casino and configure git so opencode can commit/push/PR without any
# interactive auth (ISI-7711, parent ISI-7706).
#
# Idempotent: if $HOME/casino already exists it just refreshes the remote,
# credentials, identity and hooks. Safe to re-run after a token rotation.
#
# Prereq: ~/.workshop-gitea.env exists (run gitops/opencode/gitea-token.sh first).
# This script sources it if GITEA_TOKEN is not already in the environment.
set -euo pipefail

ENV_FILE="${WORKSHOP_GITEA_ENV:-$HOME/.workshop-gitea.env}"
# shellcheck source=/dev/null
[[ -z "${GITEA_TOKEN:-}" && -f "$ENV_FILE" ]] && source "$ENV_FILE"

GITEA_URL="${GITEA_URL:-http://localhost:30001}"
GITEA_USER="${GITEA_USER:-attendee}"
CASINO_ORG="${CASINO_ORG:-casino}"
CASINO_REPO="${CASINO_REPO:-casino}"
CLONE_DIR="${CASINO_CLONE_DIR:-$HOME/casino}"
GIT_NAME="${GIT_AUTHOR_NAME:-${GITEA_USER}}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-${GITEA_USER}@otel.training}"
# Reuse the training repo's DCO hook if it's reachable from here (optional).
DCO_HOOKS_DIR="${DCO_HOOKS_DIR:-}"

log()  { echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }

if [[ -z "${GITEA_TOKEN:-}" ]]; then
  warn "no GITEA_TOKEN found (looked in env and $ENV_FILE)."
  warn "Run first:  bash gitops/opencode/gitea-token.sh"
  exit 1
fi

HOST="${GITEA_URL#http://}"; HOST="${HOST#https://}"
CLONE_URL="http://${GITEA_USER}:${GITEA_TOKEN}@${HOST}/${CASINO_ORG}/${CASINO_REPO}.git"
# The remote we store is token-free; auth comes from the credential helper below,
# so the token never ends up in .git/config.
REMOTE_URL="http://${HOST}/${CASINO_ORG}/${CASINO_REPO}.git"

# 1) Credential helper: store the token once so every push/clone is silent and
#    the secret lives only in ~/.git-credentials (0600), not in any repo config.
CRED_FILE="$HOME/.git-credentials"
umask 077
touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
# Drop any stale line for this host, then add the current one.
grep -v "@${HOST}/" "$CRED_FILE" > "${CRED_FILE}.tmp" 2>/dev/null || true
mv "${CRED_FILE}.tmp" "$CRED_FILE"
echo "http://${GITEA_USER}:${GITEA_TOKEN}@${HOST}" >> "$CRED_FILE"
chmod 600 "$CRED_FILE"
git config --global credential.helper store
log "configured git credential helper 'store' for $HOST"

# 2) Clone (or refresh an existing clone).
if [[ -d "$CLONE_DIR/.git" ]]; then
  log "$CLONE_DIR already a git repo — refreshing remote + fetching"
  git -C "$CLONE_DIR" remote set-url origin "$REMOTE_URL"
  git -C "$CLONE_DIR" fetch -q origin || warn "fetch failed — check the token/scope"
else
  log "cloning $CASINO_ORG/$CASINO_REPO into $CLONE_DIR"
  rm -rf "$CLONE_DIR"
  git clone -q "$CLONE_URL" "$CLONE_DIR"
  # Rewrite the remote to the token-free URL (auth via the credential helper).
  git -C "$CLONE_DIR" remote set-url origin "$REMOTE_URL"
fi

# 3) Identity + DCO sign-off, so commits pass the same DCO check as the main repo.
git -C "$CLONE_DIR" config user.name  "$GIT_NAME"
git -C "$CLONE_DIR" config user.email "$GIT_EMAIL"

# Reuse the training repo's DCO prepare-commit-msg hook if we can find it, so
# `git commit` auto-appends Signed-off-by without anyone remembering `-s`.
if [[ -z "$DCO_HOOKS_DIR" ]]; then
  for cand in "$(pwd)/.githooks" "$HOME/Otel-Training/.githooks" "$HOME/otel-training/.githooks"; do
    [[ -x "$cand/prepare-commit-msg" ]] && { DCO_HOOKS_DIR="$cand"; break; }
  done
fi
if [[ -n "$DCO_HOOKS_DIR" && -x "$DCO_HOOKS_DIR/prepare-commit-msg" ]]; then
  mkdir -p "$CLONE_DIR/.git/hooks"
  cp "$DCO_HOOKS_DIR/prepare-commit-msg" "$CLONE_DIR/.git/hooks/prepare-commit-msg"
  chmod +x "$CLONE_DIR/.git/hooks/prepare-commit-msg"
  log "installed DCO prepare-commit-msg hook from $DCO_HOOKS_DIR"
else
  warn "DCO hook not found — commits must use 'git commit -s' (gitea-pr.sh signs for you)"
fi

# 4) Seed opencode's AGENTS.md into the clone if we have it alongside this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/AGENTS.md" && ! -f "$CLONE_DIR/AGENTS.md" ]]; then
  cp "$SCRIPT_DIR/AGENTS.md" "$CLONE_DIR/AGENTS.md"
  log "seeded AGENTS.md (opencode git-loop rules) into $CLONE_DIR"
fi

cat <<EOF

================================================================
 casino repo ready for opencode.
   working copy : $CLONE_DIR
   remote       : $REMOTE_URL  (auth via ~/.git-credentials)
   identity     : $GIT_NAME <$GIT_EMAIL>
 Launch opencode there and let it edit -> commit -> push -> PR:
   cd $CLONE_DIR && opencode
 Or open a PR directly after editing:
   bash gitops/opencode/gitea-pr.sh "my change"
================================================================
EOF
