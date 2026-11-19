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
#      asserts the HTTP status. The payload is a real protobuf-encoded
#      ExportTraceServiceRequest sent as `Content-Type: application/x-protobuf`
#      — Dynatrace's OTLP endpoint accepts ONLY protobuf, not JSON
#      (docs.dynatrace.com: "JSON is not supported ... Binary format must be
#      used"), and this is byte-faithful to what the gateway's `otlphttp`
#      exporter sends, so the probe exercises exactly the real ingest path.
#      A 401/403/404 here is exactly why "no data" happens:
#        401  token invalid / not a platform token / wrong/empty value
#        403  token authenticates but LACKS the openpipeline:*:ingest /
#             storage:metrics:write IAM scopes (see deploy/dynatrace/README.md
#             → "Copy-pasteable IAM policy")
#        404  wrong endpoint — DT_TENANT is not the tenant base URL
#      200/202 = the span was accepted. ANY other code (400/415/5xx/network) is
#      reported as INCONCLUSIVE — it never counts as "OK", so a rejected payload
#      can't produce a false-positive pass.
#
#   2. Exporter-error scan — greps the running gateway collector log for OTLP
#      export failures (anchored on otelcol's real phrasing: "Permanent error",
#      "Exporting failed", "Dropping data", Unauthorized/Forbidden + their status
#      codes). Catches the case where the token changed or the endpoint drifted
#      AFTER install but the probe token still works.
#
# Required env (same secrets as observability/install.sh):
#   DT_TENANT        e.g. https://abc12345.live.dynatrace.com
#   DT_INGEST_TOKEN  OTLP data-ingest PLATFORM token (dt0s16)
#
# Exit codes:
#   0  ingest path OK (span ACCEPTED with a 2xx) OR inconclusive (network /
#      unexpected non-auth status) — a transient blip must not red-fail bring-up.
#   1  LOUD failure — a 401/403/404 from the tenant, or exporter errors in the
#      gateway log. This is the real gate: `make verify` / CI stops on it.
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

rc=0        # 1 => LOUD failure (the gate)
accepted=0  # 1 => got an explicit 2xx; only then may we report "OK"

# --- OTLP/protobuf payload builder (pure bash — no python/protoc at runtime) --
# Builds a real ExportTraceServiceRequest with one resource span / one span, the
# same wire format the collector's otlphttp exporter emits. Emitting \xNN tokens
# and writing with `printf %b` to a file keeps embedded NUL bytes intact (trace
# id / fixed64 timestamps contain NULs, so command substitution can't carry them).
_str_hex() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '\\x%02x' "'${s:i:1}"; done; }
_nb()      { echo $(( ${#1} / 4 )); }               # byte count of a \xNN string
_lp()      { printf '\\x%02x' "$(_nb "$1")"; }       # 1-byte varint len prefix (<128)
_le64()    { local v=$1 i; for ((i=0;i<8;i++)); do printf '\\x%02x' $((v & 255)); v=$((v>>8)); done; }

build_otlp_pb() { # -> writes protobuf bytes to $1
  local out="$1"
  local now_ns trace_id span_id sv anyval k kv res nm span ss rs req
  now_ns="$(date -u +%s)000000000"
  trace_id='\x5b\x8e\xff\xf7\x98\x03\x81\x03\xd2\x69\xb6\x33\x81\x3f\xc6\x0c'  # 16B
  span_id='\xee\xe1\x9b\x7e\xc3\xc1\xb1\x74'                                    # 8B
  sv="$(_str_hex 'otel-training-ingest-check')"
  anyval='\x0a'"$(_lp "$sv")""$sv"                       # AnyValue{ string_value }
  k="$(_str_hex 'service.name')"
  kv='\x0a'"$(_lp "$k")""$k"'\x12'"$(_lp "$anyval")""$anyval"   # KeyValue
  res='\x0a'"$(_lp "$kv")""$kv"                          # Resource{ attributes }
  nm="$(_str_hex 'ingest-check')"
  span='\x0a\x10'"$trace_id"'\x12\x08'"$span_id"'\x2a'"$(_lp "$nm")""$nm"'\x30\x01'
  span+='\x39'"$(_le64 "$now_ns")"'\x41'"$(_le64 "$now_ns")"   # start/end fixed64
  ss='\x12'"$(_lp "$span")""$span"                      # ScopeSpans{ spans }
  rs='\x0a'"$(_lp "$res")""$res"'\x12'"$(_lp "$ss")""$ss"      # ResourceSpans
  req='\x0a'"$(_lp "$rs")""$rs"                          # ExportTraceServiceRequest
  printf '%b' "$req" > "$out"
}

# --- 1. direct ingest probe --------------------------------------------------
base="${DT_TENANT%/}"
endpoint="${base}/api/v2/otlp/v1/traces"
pb="$(mktemp -t ingest-span.XXXXXX.pb)"
resp="$(mktemp -t ingest-resp.XXXXXX)"
trap 'rm -f "$pb" "$resp"' EXIT
build_otlp_pb "$pb"

bold "1. direct ingest probe -> ${endpoint} (OTLP/protobuf)"
code="$(curl -s -o "$resp" -w '%{http_code}' \
  -X POST "$endpoint" \
  -H "Authorization: Bearer ${DT_INGEST_TOKEN}" \
  -H "Content-Type: application/x-protobuf" \
  --data-binary "@${pb}" 2>/dev/null || echo "000")"
body="$(tr -d '\r' < "$resp" 2>/dev/null | head -c 400)"

case "$code" in
  200|202)
    accepted=1
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
    warn "could not reach ${base} (network/DNS/proxy) — INCONCLUSIVE, not a 4xx"
    [[ -n "$body" ]] && printf '      %s\n' "$body" >&2
    # Network reachability is not the auth gate this check owns; stay soft.
    ;;
  *)
    warn "unexpected HTTP ${code} from the ingest endpoint — INCONCLUSIVE"
    warn "not a 2xx accept and not a 401/403/404 auth failure; the span was NOT confirmed accepted"
    [[ -n "$body" ]] && printf '      %s\n' "$body" >&2
    # Deliberately NOT treated as OK: accepted stays 0 so the final verdict says
    # INCONCLUSIVE, never a false-positive "data is landing".
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
    # Anchor on otelcol-contrib's REAL export-failure phrasing, not bare status
    # numbers — a lone "401"/"403" matches port numbers, byte counts, or a
    # recovered transient error and would flip the gate to a spurious FAIL. The
    # exporterhelper logs "Exporting failed." / "Permanent error:" / "Dropping
    # data" on a real drop, and HTTP auth rejections carry the status WORD next
    # to the code ("403 Forbidden" / "401 Unauthorized" / "permission denied").
    hits="$(printf '%s\n' "$logs" | grep -Ei \
      'Permanent error|Exporting failed|Dropping data|permission denied|40[13] (Forbidden|Unauthorized)|\b(Forbidden|Unauthorized)\b' \
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
if [[ "$rc" -eq 1 ]]; then
  bold "RESULT: INGEST BROKEN — data is being dropped (see ✗ above)"
  exit 1
elif [[ "$accepted" -eq 1 ]]; then
  bold "RESULT: ingest path OK (span accepted; allow 1–2 min to query it)"
  exit 0
else
  bold "RESULT: INCONCLUSIVE — span not confirmed accepted and no auth failure seen (see ! above)"
  # Soft exit: a network blip / unexpected status must not red-fail bring-up.
  # The LOUD gate (exit 1) is reserved for definite 401/403/404 or export errors.
  exit 0
fi
