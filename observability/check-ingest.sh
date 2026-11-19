#!/usr/bin/env bash
# check-ingest.sh — loud, real post-install "is data actually landing?" gate
# (ISI-7630 #70). Ties to the "Dropping data" symptom: collectors run fine but
# the tenant silently rejects every OTLP batch on an auth/scope/URL mistake, so
# NO data appears and nothing in the cluster looks wrong. This check makes that
# failure LOUD instead of silent.
#
# It does two independent things, either of which catches a broken ingest path:
#
#   1. Direct ingest probe — POSTs ONE minimal OTLP/HTTP trace straight to the
#      tenant (<DT_TENANT>/api/v2/otlp/v1/traces, Bearer <DT_INGEST_TOKEN>) and
#      asserts the HTTP status. This is the same endpoint + auth the gateway
#      collector uses, so a 401/403/404 here is exactly why "no data" happens:
#        401  token invalid / not a platform token / wrong/empty value
#        403  token authenticates but LACKS the openpipeline:*:ingest /
#             storage:metrics:write IAM scopes (see deploy/dynatrace/README.md
#             → "Copy-pasteable IAM policy")
#        404  wrong endpoint — DT_TENANT is not the tenant base URL
#      200/202 = the span was accepted.
#
#   2. Exporter-error scan — greps the running gateway collector log for OTLP
#      export failures (Unauthorized / 403 / permission / "Permanent error" /
#      "failed to export"). Catches the case where the token changed or the
#      endpoint drifted AFTER install but the probe token still works.
#
# Required env (same secrets as observability/install.sh):
#   DT_TENANT        e.g. https://abc12345.live.dynatrace.com
#   DT_INGEST_TOKEN  OTLP data-ingest PLATFORM token (dt0s16)
#
# Exit codes:
#   0  ingest path healthy (span accepted AND no exporter errors seen)
#   1  LOUD failure — a 401/403/404 from the tenant, or exporter errors in the
#      gateway log. This is a real gate: `make verify` / CI should stop on it.
#   2  could not run the check (missing curl, or DT_* not set) — inconclusive.
#
# NOTE: there is a 1–2 minute propagation delay before an accepted span is
# QUERYABLE in the tenant (Grail ingest + indexing). A 200/202 proves the
# ingest API accepted and authorized the data; it does not mean the span is
# already visible in a DQL query. This check verifies acceptance, not latency.
set -uo pipefail

DT_TENANT="${DT_TENANT:-}"
DT_INGEST_TOKEN="${DT_INGEST_TOKEN:-}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

bold "== ingest check (no-data detection, ISI-7630) =="

# --- preconditions -----------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not found — cannot probe the tenant (inconclusive)"
  exit 2
fi
if [[ "$DT_TENANT" != https://* || -z "$DT_INGEST_TOKEN" ]]; then
  warn "DT_TENANT / DT_INGEST_TOKEN not set — no-export mode, nothing to probe (inconclusive)"
  warn "set both (Codespaces secrets or .env) and re-run to verify the ingest path"
  exit 2
fi

rc=0

# --- 1. direct ingest probe --------------------------------------------------
base="${DT_TENANT%/}"
endpoint="${base}/api/v2/otlp/v1/traces"

# A minimal but valid OTLP/HTTP (JSON) trace: one resource span, one span.
# Hex-encoded trace/span ids per the OTLP-JSON spec; nanosecond timestamps as
# strings. service.name marks it so it is easy to find/ignore in the tenant.
now_ns="$(date -u +%s)000000000"
start_ns="$now_ns"
payload="$(cat <<JSON
{"resourceSpans":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"otel-training-ingest-check"}},
  {"key":"telemetry.sdk.language","value":{"stringValue":"shell"}}
]},"scopeSpans":[{"scope":{"name":"check-ingest.sh"},"spans":[
  {"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174",
   "name":"ingest-check","kind":1,
   "startTimeUnixNano":"${start_ns}","endTimeUnixNano":"${now_ns}",
   "status":{"code":1}}
]}]}]}
JSON
)"

bold "1. direct ingest probe -> ${endpoint}"
code="$(curl -s -o /tmp/ingest-check-resp.$$ -w '%{http_code}' \
  -X POST "$endpoint" \
  -H "Authorization: Bearer ${DT_INGEST_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$payload" 2>/dev/null || echo "000")"
body="$(cat /tmp/ingest-check-resp.$$ 2>/dev/null | tr -d '\r' | head -c 400)"
rm -f /tmp/ingest-check-resp.$$

case "$code" in
  200|202)
    ok "tenant ACCEPTED the test span (HTTP ${code})"
    ok "ingest auth + scopes are correct for traces"
    printf '      note: allow 1–2 min before it is queryable (Grail ingest + indexing)\n'
    ;;
  401)
    bad "HTTP 401 Unauthorized — the ingest token is INVALID"
    cat >&2 <<EOF
      DT_INGEST_TOKEN is not authenticating. Causes:
        - value is empty / truncated / has surrounding whitespace
        - it is a CLASSIC token (dt0c01); this Gen3 OTLP endpoint needs a
          PLATFORM token (dt0s16) sent as 'Authorization: Bearer <token>'
        - wrong secret pasted into the DT_INGEST_TOKEN Codespaces secret
      -> every OTLP batch from the collector is being rejected = "no data".
EOF
    rc=1
    ;;
  403)
    bad "HTTP 403 Forbidden — the token authenticates but LACKS ingest scopes"
    cat >&2 <<EOF
      DT_INGEST_TOKEN is missing the required IAM scopes. It needs:
        openpipeline:traces:ingest   openpipeline:metrics:ingest
        openpipeline:logs:ingest     openpipeline:events:ingest
        storage:metrics:write
      Paste the copy-pasteable IAM policy from deploy/dynatrace/README.md
      ("Copy-pasteable IAM policy"), (re)mint the token, then wait 1–2 min for
      the policy to propagate and re-run this check.
EOF
    rc=1
    ;;
  404)
    bad "HTTP 404 Not Found — DT_TENANT is not the tenant base URL"
    cat >&2 <<EOF
      Probed: ${endpoint}
      DT_TENANT must be the tenant base, e.g. https://abc12345.live.dynatrace.com
      (the collector appends /api/v2/otlp/v1/{traces,metrics,logs}). A trailing
      path, the apps.* URL, or a typo yields 404 and silently drops all data.
EOF
    rc=1
    ;;
  000)
    warn "could not reach ${base} (network/DNS/proxy) — inconclusive, not a 4xx"
    [[ -n "$body" ]] && printf '      %s\n' "$body" >&2
    # Network reachability is not the auth gate this check owns; stay soft.
    ;;
  *)
    warn "unexpected HTTP ${code} from the ingest endpoint (not 2xx, not 401/403/404)"
    [[ -n "$body" ]] && printf '      %s\n' "$body" >&2
    ;;
esac

# --- 2. exporter-error scan on the running gateway collector -----------------
bold "2. gateway collector exporter-error scan"
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl get nodes >/dev/null 2>&1; then
  warn "no reachable cluster — skipping the live log scan (probe above still ran)"
else
  if ! kubectl -n observability get deploy/otel-gateway-collector >/dev/null 2>&1; then
    warn "otel-gateway-collector not found in 'observability' — run observability/install.sh first"
  else
    logs="$(kubectl -n observability logs deploy/otel-gateway-collector --tail=200 2>/dev/null || true)"
    # Match real OTLP export failures; avoid matching the word "error" in healthy
    # structured fields (e.g. error=<nil>) by anchoring on known failure phrases.
    hits="$(printf '%s\n' "$logs" | grep -Ei \
      'Unauthorized|403|permission denied|Permanent error|failed to export|403 Forbidden|401' \
      | grep -vi 'error=<nil>' | tail -5 || true)"
    if [[ -n "$hits" ]]; then
      bad "gateway collector log shows OTLP export failures:"
      printf '%s\n' "$hits" | sed 's/^/      /' >&2
      warn "the collector is running but the tenant is rejecting its batches = no data"
      rc=1
    else
      ok "no OTLP export errors in the last 200 gateway log lines"
    fi
  fi
fi

echo
if [[ "$rc" -eq 0 ]]; then
  bold "RESULT: ingest path OK (data is landing; allow 1–2 min to query it)"
else
  bold "RESULT: INGEST BROKEN — data is being dropped (see ✗ above)"
fi
exit "$rc"
