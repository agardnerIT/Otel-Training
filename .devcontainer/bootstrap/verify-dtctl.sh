#!/usr/bin/env bash
# verify-dtctl.sh — prove the Dynatrace platform CLI is installed, runnable, and
# (when a platform token is present) actually AUTHENTICATED in the attendee
# codespace (ISI-7175, ISI-7169·B1, ISI-7630 #60).
#
# install-tools.sh installs dtctl, but its download is deliberately NON-fatal
# (a region/network hiccup must not break the rest of the toolchain). That means
# an attendee could silently end up WITHOUT dtctl and only discover it later when
# the Dynatrace-for-AI skills (B2/B3) that depend on the CLI fail. This check
# surfaces that immediately, right after bootstrap, as a first-class gate.
#
# It runs in two tiers:
#   * ALWAYS: prove the binary is on PATH and `dtctl version` exits cleanly
#     (cluster-independent, no secrets needed).
#   * WHEN DT_PLATFORM_TOKEN is set: a real LIVE auth call. DT_PLATFORM_TOKEN is
#     optional (only the dtctl labs need it), so its absence is a SKIP, not a
#     failure — but when present, a bad token / missing scope must fail loudly
#     here rather than mid-lab. The platform URL is taken from DT_PLATFORM_URL,
#     or DERIVED from DT_TENANT (<id>.live... -> <id>.apps...).
#
# Exit codes:
#   0  dtctl present + `dtctl version` ok; AND (auth skipped OR auth succeeded)
#   1  dtctl missing / `dtctl version` failed; OR DT_PLATFORM_TOKEN set but the
#      live auth call failed (bad token, missing scope, wrong URL)
#
# Version drift (installed != pinned) is a WARNING, not a failure — a custom
# DTCTL_DOWNLOAD_URL / DTCTL_VERSION=latest is a supported override.
set -uo pipefail

# Pinned reference — keep in sync with install-tools.sh / verify-arch.sh.
DTCTL_VERSION="${DTCTL_VERSION:-v0.45.0}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

# derive_platform_url — the canonical DT_PLATFORM_URL-from-DT_TENANT rule
# (docs-site/setup.md: "derived from DT_TENANT when unset"). On Gen3 SaaS the
# tenant base is <id>.live.dynatrace.com (operator + OTLP) while dtctl talks to
# the apps host <id>.apps.dynatrace.com. The only transform is live -> apps,
# so this also handles the *.dynatracelabs.com dev hosts. Echoes the derived
# URL, or nothing if DT_TENANT can't be mapped.
derive_platform_url() {
  local tenant="${1%/}"
  if [[ "$tenant" == *.live.* ]]; then
    printf '%s\n' "${tenant/.live./.apps.}"
  fi
}

bold "== dtctl verify (pinned ${DTCTL_VERSION}) =="

# 1. Is it on PATH at all?
path="$(command -v dtctl 2>/dev/null || true)"
if [[ -z "$path" ]]; then
  bad "dtctl is NOT on PATH"
  cat >&2 <<EOF

The Dynatrace CLI did not install. The download in install-tools.sh is non-fatal,
so bootstrap continued without it. Re-install (honours TARGETARCH/uname + the pin):

  FORCE=1 bash .devcontainer/bootstrap/install-tools.sh

Behind a proxy / in an air-gapped region, point it at a reachable asset:

  DTCTL_DOWNLOAD_URL=<direct .tar.gz or binary> FORCE=1 \\
    bash .devcontainer/bootstrap/install-tools.sh

The Dynatrace-for-AI skills (ISI-7169 B2/B3) need this CLI present.
EOF
  exit 1
fi
ok "dtctl on PATH: ${path}"

# 2. Does `dtctl version` actually run? (the real AC)
if ! ver_out="$(dtctl version 2>&1)"; then
  bad "'dtctl version' failed to execute:"
  printf '%s\n' "$ver_out" >&2
  exit 1
fi
ok "'dtctl version' succeeded"
printf '      %s\n' "$ver_out"

# 3. Soft version-drift check (warn only).
want="${DTCTL_VERSION#v}"
if printf '%s' "$ver_out" | grep -q -- "$want"; then
  ok "reported version matches pin (${DTCTL_VERSION})"
else
  warn "reported version does not contain the pin '${want}' — override or drift (non-fatal)"
fi

# 4. Point dtctl at the environment — and, when a token is present, prove auth.
# DT_PLATFORM_TOKEN is OPTIONAL (dtctl labs only), so its absence is never a
# failure. But it must NOT leave dtctl context-less (the "no context" wall from
# ISI-7847): whenever we can resolve the tenant URL we still persist a real
# 'training' context so `dtctl get dashboards` knows WHERE it is. Two outcomes:
#   * token present -> persist an AUTHENTICATED context (+ a live auth check)
#   * token absent  -> persist an ENVIRONMENT-ONLY context and print the ONE
#     copy-paste line that attaches credentials later (ISI-7848).
DT_PLATFORM_TOKEN="${DT_PLATFORM_TOKEN:-}"
DT_PLATFORM_URL="${DT_PLATFORM_URL:-}"
DT_TENANT="${DT_TENANT:-}"

# Resolve the apps URL once — both paths use it. Explicit DT_PLATFORM_URL wins;
# else derive from DT_TENANT (live -> apps).
url="$DT_PLATFORM_URL"
if [[ -z "$url" ]]; then
  url="$(derive_platform_url "$DT_TENANT")"
  [[ -n "$url" ]] && ok "derived DT_PLATFORM_URL from DT_TENANT: ${url}"
fi

# --- No platform token: configure the environment, defer credentials. ---
if [[ -z "$DT_PLATFORM_TOKEN" ]]; then
  warn "DT_PLATFORM_TOKEN not set — skipping live auth (dtctl labs are optional)"
  if [[ "$url" == https://* ]]; then
    # Persist an environment-only context so dtctl knows the tenant — no bare
    # "no context" error mid-lab. We deliberately do NOT invent a token or reuse
    # the operator/ingest tokens: those carry different scopes and would fail
    # dtctl auth. Idempotent (set-context updates in place) and non-fatal.
    if dtctl config set-context training --environment "$url" \
         --safety-level readwrite-all >/dev/null 2>&1 \
       && dtctl config use-context training >/dev/null 2>&1; then
      ok "configured dtctl context 'training' -> ${url} (credentials pending)"
      bold "Attach dtctl credentials once you have a DT_PLATFORM_TOKEN (dt0s16 — see docs-site/setup.md):"
      printf '  dtctl config set-credentials training-token --token "$DT_PLATFORM_TOKEN" \\\n'
      printf '    && dtctl config set-context training --environment %s --token-ref training-token --safety-level readwrite-all \\\n' "$url"
      printf '    && dtctl config use-context training\n'
      bold "RESULT: dtctl OK (environment context set; credentials pending)"
    else
      warn "could not write the default dtctl config; run: dtctl config set-context --help"
      bold "RESULT: dtctl OK (binary only; could not persist context)"
    fi
  else
    warn "no DT_PLATFORM_URL/DT_TENANT to point dtctl at — leaving it unconfigured"
    bold "RESULT: dtctl OK (binary only; no environment resolved)"
  fi
  exit 0
fi

# --- Platform token present: require a usable URL, then live-auth. ---
if [[ "$url" != https://* ]]; then
  bad "DT_PLATFORM_TOKEN is set but no usable platform URL"
  cat >&2 <<EOF

  dtctl needs the apps host (https://<id>.apps.dynatrace.com). Either:
    - set DT_PLATFORM_URL explicitly, or
    - set DT_TENANT to the tenant base (https://<id>.live.dynatrace.com) so it
      can be derived (live -> apps).
EOF
  exit 1
fi

bold "4. live auth check -> ${url}"
# Build an EPHEMERAL dtctl config so we never touch the attendee's real
# ~/.config/dtctl/config. doctor's "Authentication" check is a real call to the
# platform metadata API, so a bad token (401) or missing scope (403) fails here.
CFG="$(mktemp -t dtctl-verify.XXXXXX.yaml)"
trap 'rm -f "$CFG"' EXIT
dctl() { dtctl --config "$CFG" --no-agent --plain "$@"; }

if ! dctl config set-credentials verify-token --token "$DT_PLATFORM_TOKEN" >/dev/null 2>&1 \
  || ! dctl config set-context verify --environment "$url" --token-ref verify-token \
        --safety-level readonly >/dev/null 2>&1 \
  || ! dctl config use-context verify >/dev/null 2>&1; then
  bad "could not stage an ephemeral dtctl context (unexpected dtctl error)"
  exit 1
fi

# `dtctl doctor` runs: version, config, context, token retrieval, CONNECTIVITY,
# and AUTHENTICATION (user identity). Any FAIL => non-zero. Filter the resty
# retry noise but keep the check lines.
if doctor_out="$(dctl doctor --context verify 2>&1)"; then
  printf '%s\n' "$doctor_out" | grep -E '^\[(OK|FAIL)\]' | sed 's/^/      /'
  ok "dtctl authenticated against the tenant"

  # Persist a REAL context so plain `dtctl doctor` / `dtctl query` work with no
  # manual steps (the ephemeral config above is deleted on exit). Idempotent:
  # set-credentials/set-context update in place. Never fails the verify.
  if dtctl config set-credentials training-token --token "$DT_PLATFORM_TOKEN" >/dev/null 2>&1 \
    && dtctl config set-context training --environment "$url" --token-ref training-token \
         --safety-level readwrite-all >/dev/null 2>&1 \
    && dtctl config use-context training >/dev/null 2>&1; then
    ok "configured dtctl context 'training' (~/.config/dtctl/config)"
  else
    warn "could not write the default dtctl config; run: dtctl config set-context --help"
  fi
  bold "RESULT: dtctl OK (authenticated)"
  exit 0
else
  printf '%s\n' "$doctor_out" | grep -E '^\[(OK|FAIL)\]' | sed 's/^/      /' >&2
  bad "dtctl could NOT authenticate against ${url}"
  cat >&2 <<EOF

  The platform CLI is installed but DT_PLATFORM_TOKEN does not work against the
  tenant. Common causes:
    - token invalid / truncated / not a platform token (dt0s16)
    - token lacks the dtctl scopes (see docs-site/setup.md "DT_PLATFORM_TOKEN")
    - wrong platform URL — check DT_PLATFORM_URL / DT_TENANT (apps vs live host)
  Re-run after fixing:  bash .devcontainer/bootstrap/verify-dtctl.sh
EOF
  exit 1
fi
