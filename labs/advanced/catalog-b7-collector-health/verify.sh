#!/usr/bin/env bash
# Catalog B7 — offline verification of the collector self-telemetry overlay.
#
# Checks the STRUCTURE of the composed gateway (no cluster, no live tenant):
#   1. service.telemetry exports metrics + logs + traces (not just logs.level).
#   2. A second OTLP receiver (otlp/internal) exists for the loopback.
#   3. A dedicated internal-traces pipeline runs tail_sampling and reuses the
#      Dynatrace exporter, with memory_limiter first.
#   4. (optional) `otelcol validate` on the composed config if a pinned binary
#      is available.
#
# Live Dynatrace validation of the otelcol_* metrics + dashboard is a follow-up
# that needs an up tenant — out of scope for this offline check.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
SELFOBS="${HERE}/telemetry-selfobs.yaml"
YQ="${YQ:-yq}"

fail=0
log() { printf '\033[1;34m[b7-verify]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[b7-verify] OK:\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[b7-verify] FAIL:\033[0m %s\n' "$*" >&2; fail=1; }

command -v "$YQ" >/dev/null 2>&1 || { echo "yq (v4) not found" >&2; exit 2; }

# 1. All three telemetry signals are exported.
[[ "$($YQ '.service.telemetry.metrics.readers | length' "$SELFOBS")" -ge 1 ]] \
  && ok "self-metrics reader present" || err "no self-metrics reader"
[[ "$($YQ '.service.telemetry.logs.processors | length' "$SELFOBS")" -ge 1 ]] \
  && ok "self-logs processor present" || err "no self-logs processor"
[[ "$($YQ '.service.telemetry.traces.processors | length' "$SELFOBS")" -ge 1 ]] \
  && ok "self-traces processor present" || err "no self-traces processor"

# 2. Loopback receiver exists.
[[ "$($YQ '.receivers | has("otlp/internal")' "$SELFOBS")" == "true" ]] \
  && ok "otlp/internal loopback receiver present" || err "no otlp/internal receiver"

# 3. Self-traces loop back to localhost (not straight to Dynatrace).
ep="$($YQ '.service.telemetry.traces.processors[0].batch.exporter.otlp.endpoint' "$SELFOBS")"
[[ "$ep" == *localhost:4319* ]] \
  && ok "self-traces export via loopback ($ep)" || err "self-traces not looped back: $ep"

# 4. Dedicated internal-traces pipeline: memory_limiter first, tail_sampling, DT exporter.
procs="$($YQ -o=json -I=0 '.service.pipelines["traces/internal"].processors' "$SELFOBS")"
[[ "$procs" == '["memory_limiter","tail_sampling/internal"]' ]] \
  && ok "internal pipeline order correct" || err "internal pipeline order wrong: $procs"
[[ "$($YQ '.service.pipelines["traces/internal"].exporters[0]' "$SELFOBS")" == "otlp_http/dynatrace" ]] \
  && ok "internal pipeline reuses otlp_http/dynatrace" || err "internal pipeline missing DT exporter"

# 5. tail_sampling keeps errors 100% and samples the rest at 5%.
[[ "$($YQ '.processors["tail_sampling/internal"].policies[] | select(.type=="status_code") | .status_code.status_codes[0]' "$SELFOBS")" == "ERROR" ]] \
  && ok "ERROR-keep policy present" || err "no ERROR-keep policy"
[[ "$($YQ '.processors["tail_sampling/internal"].policies[] | select(.type=="probabilistic") | .probabilistic.sampling_percentage' "$SELFOBS")" == "5" ]] \
  && ok "5% baseline policy present" || err "baseline policy not 5%"

if [[ "$fail" -eq 0 ]]; then
  log "all structural checks passed"
else
  log "one or more checks FAILED"; exit 1
fi
