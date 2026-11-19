#!/usr/bin/env bash
# load-env.sh — load the ONE canonical repo-root `.env` into the environment.
#
# This is the single `.env` flow (ISI-7629 / #61). There is exactly one sample,
# the repo-root `.env.sample`; attendees copy it to `.env`, fill it in, and
# REBUILD the container — no manual `make` or `source` is ever required:
#
#   * SOURCE it (from the top of postCreate.sh / postStart.sh) and it exports
#     every non-empty value from `.env` into the current bootstrap process, so
#     create-cluster.sh / deploy-environment.sh and the FULL_DEPLOY toggle all
#     see the attendee's values on a plain container rebuild.
#   * It also installs a small, idempotent snippet in ~/.bashrc so brand-new
#     interactive terminals pick the same `.env` up automatically — again with
#     no `source` step.
#
# In GitHub Codespaces there is normally NO `.env` (the same variables arrive as
# Codespaces secrets through devcontainer.json `remoteEnv`); this script then
# does nothing and never clobbers a secret. To avoid overriding a Codespaces
# secret with a committed-blank line, the in-process load skips EMPTY values.
#
# Safe to source more than once. Never calls `exit` (it is sourced).

# Resolve the repo root (two levels up from .devcontainer/bootstrap).
_le_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_le_repo_root="$(cd "$_le_script_dir/../.." && pwd)"
_le_env_file="${OTEL_TRAINING_ENV_FILE:-$_le_repo_root/.env}"

if [ -f "$_le_env_file" ]; then
  echo "==> loading environment from $_le_env_file (ISI-7629 single .env flow)"
  # Export only non-empty KEY=VALUE lines so a blank line in a committed .env
  # can never shadow a Codespaces secret already present in the environment.
  while IFS= read -r _le_line || [ -n "$_le_line" ]; do
    case "$_le_line" in
      ''|'#'*) continue ;;                       # blank or comment
    esac
    _le_key="${_le_line%%=*}"
    _le_val="${_le_line#*=}"
    # trim a leading "export " and surrounding whitespace on the key
    _le_key="${_le_key#export }"
    _le_key="$(printf '%s' "$_le_key" | tr -d '[:space:]')"
    [ -n "$_le_key" ] || continue
    [ "$_le_line" = "${_le_line#*=}" ] && continue   # no '=' -> not an assignment
    # strip optional surrounding quotes on the value
    _le_val="${_le_val%\"}"; _le_val="${_le_val#\"}"
    _le_val="${_le_val%\'}"; _le_val="${_le_val#\'}"
    [ -n "$_le_val" ] || continue                    # skip empty values
    export "$_le_key=$_le_val"
  done < "$_le_env_file"
else
  echo "==> no $_le_env_file (expected in Codespaces — vars come from secrets)"
fi

# Install an idempotent ~/.bashrc hook so interactive shells get `.env` too,
# without the attendee ever typing `source`. Guarded by a marker so repeated
# bootstraps don't append duplicates.
_le_bashrc="${HOME:-/home/vscode}/.bashrc"
_le_marker="# >>> otel-training .env (ISI-7629) >>>"
if [ -w "$(dirname "$_le_bashrc")" ] && ! grep -qF "$_le_marker" "$_le_bashrc" 2>/dev/null; then
  {
    echo ""
    echo "$_le_marker"
    echo "# Auto-load the single canonical repo-root .env into interactive shells."
    echo "if [ -f \"$_le_env_file\" ]; then set -a; . \"$_le_env_file\"; set +a; fi"
    echo "# <<< otel-training .env (ISI-7629) <<<"
  } >> "$_le_bashrc"
fi

unset _le_script_dir _le_repo_root _le_env_file _le_line _le_key _le_val _le_bashrc _le_marker
