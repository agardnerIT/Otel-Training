#!/usr/bin/env bash
# gitea-token.sh — mint a scoped Gitea personal access token so opencode (and the
# attendee) can drive the full git loop against the in-cluster Gitea from the
# Codespace CLI (ISI-7711, parent ISI-7706).
#
# What it does (idempotent):
#   1. Waits for the forwarded Gitea API (localhost:30001) to answer.
#   2. Deletes any existing token named 'opencode' (tokens are only shown once at
#      creation, so re-running always rotates to a fresh, known value).
#   3. Creates a new 'opencode' token scoped to write:repository + read:user.
#   4. Writes ~/.workshop-gitea.env (0600) with GITEA_TOKEN / GITEA_URL /
#      GITEA_USER so the rest of the loop (clone-casino.sh, gitea-pr.sh,
#      opencode) can source it.
#
# On any failure it prints the Gitea-UI fallback (Settings -> Applications ->
# Generate Token) and exits non-zero, but never leaves a half-written env file.
#
# Grounding: credentials + NodePort come from gitops/install/seed-gitea.sh
# (attendee / trainingpass123, http://localhost:30001).
set -euo pipefail

GITEA_URL="${GITEA_URL:-http://localhost:30001}"
GITEA_USER="${GITEA_USER:-${GITEA_ADMIN_USER:-attendee}}"
GITEA_PASS="${GITEA_PASS:-${GITEA_ADMIN_PASS:-trainingpass123}}"
TOKEN_NAME="${GITEA_TOKEN_NAME:-opencode}"
# Gitea 1.22 fine-grained scopes. write:repository implies read:repository;
# read:user lets opencode resolve the current user for PR authorship.
TOKEN_SCOPES="${GITEA_TOKEN_SCOPES:-write:repository,read:user}"
ENV_FILE="${WORKSHOP_GITEA_ENV:-$HOME/.workshop-gitea.env}"

log()  { echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }

ui_fallback() {
  cat >&2 <<EOF

------------------------------------------------------------------
 Could not mint a Gitea token automatically.
 Create one by hand in the Gitea UI, then paste it below:

   1. Open   $GITEA_URL/user/settings/applications
      (login: $GITEA_USER / $GITEA_PASS)
   2. "Generate New Token" — name: $TOKEN_NAME
      scopes: write:repository, read:user
   3. Copy the token, then run:

        GITEA_TOKEN=<paste> bash gitops/opencode/gitea-token.sh --from-env

 (that will just write ~/.workshop-gitea.env from the pasted token).
------------------------------------------------------------------
EOF
}

write_env_file() {
  local token="$1"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Written by gitops/opencode/gitea-token.sh — DO NOT COMMIT.
# Source this to drive the in-cluster Gitea from the CLI / opencode.
export GITEA_URL="$GITEA_URL"
export GITEA_USER="$GITEA_USER"
export GITEA_TOKEN="$token"
EOF
  chmod 600 "$ENV_FILE"
  log "wrote $ENV_FILE (0600)"
}

# --from-env: skip the API, just persist a token the caller already has
# (GITEA_TOKEN in the environment). This is the UI-fallback landing path.
if [[ "${1:-}" == "--from-env" ]]; then
  if [[ -z "${GITEA_TOKEN:-}" ]]; then
    warn "--from-env needs GITEA_TOKEN set in the environment"
    ui_fallback
    exit 1
  fi
  write_env_file "$GITEA_TOKEN"
  log "persisted the pasted token. You can now: source $ENV_FILE && bash gitops/opencode/clone-casino.sh"
  exit 0
fi

api() {
  curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" -H "Accept: application/json" "$@"
}

# 1) Wait for the forwarded Gitea API to answer.
log "waiting for Gitea API at $GITEA_URL (up to 60s)"
UP=0
for _ in $(seq 1 30); do
  if curl -fsS "$GITEA_URL/api/healthz" >/dev/null 2>&1; then UP=1; break; fi
  sleep 2
done
if [[ "$UP" -ne 1 ]]; then
  warn "Gitea API did not answer at $GITEA_URL within 60s."
  warn "Is the NodePort forwarded? Try: kubectl -n gitea get svc; kubectl -n gitea rollout status deploy/gitea"
  ui_fallback
  exit 1
fi

# 2) Delete an existing token of the same name so re-runs always rotate to a
#    fresh, known value (Gitea only returns the secret at creation time).
log "removing any existing '$TOKEN_NAME' token (idempotent rotate)"
api -X DELETE "$GITEA_URL/api/v1/users/$GITEA_USER/tokens/$TOKEN_NAME" >/dev/null 2>&1 || true

# 3) Create the token. scopes is a JSON array in Gitea 1.22's API.
log "creating '$TOKEN_NAME' token (scopes: $TOKEN_SCOPES)"
SCOPES_JSON="$(printf '%s' "$TOKEN_SCOPES" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}}')"
RESP="$(api -X POST "$GITEA_URL/api/v1/users/$GITEA_USER/tokens" \
  -d "{\"name\":\"$TOKEN_NAME\",\"scopes\":[$SCOPES_JSON]}" 2>/dev/null || true)"

TOKEN="$(printf '%s' "$RESP" | sed -n 's/.*"sha1":"\([^"]*\)".*/\1/p')"
if [[ -z "$TOKEN" ]]; then
  warn "token creation returned no sha1. Raw response: ${RESP:-<empty>}"
  ui_fallback
  exit 1
fi

# 4) Persist it.
write_env_file "$TOKEN"

cat <<EOF

================================================================
 Gitea token minted for '$GITEA_USER'.
   token name : $TOKEN_NAME   (scopes: $TOKEN_SCOPES)
   env file   : $ENV_FILE  (0600, gitignored)
 Next:
   source $ENV_FILE
   bash gitops/opencode/clone-casino.sh
================================================================
EOF
