#!/usr/bin/env bash
# configure-dtctl-context.sh — idempotently (re)configure the dtctl `training`
# context so the Dynatrace CLI and its Agent Skill work on EVERY codespace start,
# not just at create time (ISI-7872 / plan ISI-7865).
#
# Root cause it fixes: the context was written ONLY at create time (postCreate ->
# verify-dtctl.sh, the ISI-7848 autoconfig). postStart.sh never re-ran it, so a
# codespace created before DT_TENANT was set — or before the autoconfig landed —
# kept ZERO dtctl config, and the dtctl skill's first call hit
# `config file not found at ~/.config/dtctl/config` with no restart/runtime
# recovery. postStart.sh now re-runs this on every start, so a plain RESTART
# heals a stale codespace with no rebuild.
#
# Contract (same shape as verify-dtctl.sh / dispense-llm.sh):
#   * Non-fatal: any problem warns and returns/exits 0 — never blocks bring-up.
#   * Idempotent: set-context / set-credentials update in place, so re-running or
#     restarting does not duplicate or corrupt ~/.config/dtctl/config.
#   * DT_TENANT / URL absent -> clean skip + the standing guidance line.
#   * Never invents or reuses operator/ingest tokens — only DT_PLATFORM_TOKEN
#     (dt0s16) is attached, and only when it is explicitly present.
#
# Dual-use: `source` it to reuse derive_platform_url + configure_dtctl_context
# (verify-dtctl.sh does this, so the create-time live-auth check does not
# duplicate the set-context logic), or run it directly (postCreate / postStart).
set -uo pipefail

# Helper output (identical to verify-dtctl.sh; harmless if both are in scope).
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }

# derive_platform_url — the canonical DT_PLATFORM_URL-from-DT_TENANT rule
# (docs-site/setup.md: "derived from DT_TENANT when unset"). On Gen3 SaaS the
# tenant base is <id>.live.dynatrace.com (operator + OTLP) while dtctl talks to
# the apps host <id>.apps.dynatrace.com. The only transform is live -> apps, so
# this also handles the *.dynatracelabs.com dev hosts. Echoes the derived URL,
# or nothing if DT_TENANT can't be mapped.
derive_platform_url() {
  local tenant="${1%/}"
  if [[ "$tenant" == *.live.* ]]; then
    printf '%s\n' "${tenant/.live./.apps.}"
  fi
}

# configure_dtctl_context — resolve the apps URL and write/refresh the `training`
# context. Returns 0 always (non-fatal). When DT_PLATFORM_TOKEN is present it
# also attaches credentials, matching the authenticated create-time path.
configure_dtctl_context() {
  local token="${DT_PLATFORM_TOKEN:-}"
  local url="${DT_PLATFORM_URL:-}"
  local tenant="${DT_TENANT:-}"

  # Resolve the apps URL: explicit DT_PLATFORM_URL wins; else derive from DT_TENANT.
  if [[ -z "$url" && -n "$tenant" ]]; then
    url="$(derive_platform_url "$tenant")"
  fi

  if [[ "$url" != https://* ]]; then
    warn "DT_TENANT / DT_PLATFORM_URL not set (or not derivable) — skipping dtctl context setup (non-fatal)."
    warn "set DT_TENANT=https://<id>.live.dynatrace.com (or DT_PLATFORM_URL=https://<id>.apps.dynatrace.com),"
    warn "then restart the codespace, or run: bash .devcontainer/bootstrap/configure-dtctl-context.sh"
    return 0
  fi

  if ! command -v dtctl >/dev/null 2>&1; then
    warn "dtctl not on PATH — cannot configure context (non-fatal). Run install-tools.sh first."
    return 0
  fi

  # Base context (no credentials) — enough for the dtctl skill to RESOLVE its
  # config (no more 'config file not found') and for read-only describe-context,
  # even before a platform token is provided. Idempotent: set-context updates in
  # place.
  if ! dtctl config set-context training --environment "$url" \
         --safety-level readwrite-all >/dev/null 2>&1 \
     || ! dtctl config use-context training >/dev/null 2>&1; then
    warn "could not write the dtctl 'training' context (non-fatal); run: dtctl config set-context --help"
    return 0
  fi

  # Attach credentials only when a platform token (dt0s16) is explicitly present.
  # Never invent or reuse operator/ingest tokens.
  if [[ -n "$token" ]]; then
    if dtctl config set-credentials training-token --token "$token" >/dev/null 2>&1 \
       && dtctl config set-context training --environment "$url" --token-ref training-token \
            --safety-level readwrite-all >/dev/null 2>&1; then
      ok "configured dtctl context 'training' with credentials -> ${url} (~/.config/dtctl/config)"
    else
      warn "context 'training' set, but attaching the platform token failed (non-fatal)."
    fi
  else
    ok "configured dtctl context 'training' (env-only; no platform token) -> ${url}"
    warn "DT_PLATFORM_TOKEN not set — the context has no credentials, so dtctl auth calls stay unauthenticated until you set it (dtctl labs only)."
  fi

  return 0
}

# Run as a script (postCreate / postStart) — but not when sourced (verify-dtctl.sh).
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  bold "== dtctl context self-heal =="
  configure_dtctl_context
fi
