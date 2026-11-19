#!/usr/bin/env bash
# Offline validation for the observability stack (ISI-6792 acceptance).
#
# 1. Extracts .spec.config from each OpenTelemetryCollector CR and validates it
#    with `otelcol validate` (downloads the pinned otelcol-contrib if needed).
# 2. Asserts the pipeline-order contract:
#      memory_limiter FIRST, k8sattributes before cumulative_to_delta,
#      cumulative_to_delta only on metrics, NO `batch` processor (deprecated),
#      and exporter-level batching (sending_queue.batch) enabled on every exporter.
# 3. Renders the pinned operator + cert-manager manifests with kubectl --dry-run
#    server-side if a cluster is reachable (skipped offline).
#
# Works inside the devcontainer AND on any machine with curl+yq (no cluster
# needed for steps 1–2).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${HERE}/versions.env"

BIN_DIR="${BIN_DIR:-/tmp/otelcol-bin}"
OTELCOL="${BIN_DIR}/otelcol-contrib"
YQ="${YQ:-yq}"

fail=0
log() { printf '\033[1;34m[validate]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[validate] FAIL:\033[0m %s\n' "$*" >&2; fail=1; }

if ! command -v "$YQ" >/dev/null 2>&1; then YQ="$(command -v yq4 || true)"; fi
command -v "$YQ" >/dev/null 2>&1 || { echo "yq (v4) not found. Install: https://github.com/mikefarah/yq" >&2; exit 2; }

# --- fetch pinned otelcol if needed ------------------------------------------
# Prefer an otelcol-contrib baked into the devcontainer image by install-tools.sh
# (ISI-7628/#66). Only download when it is genuinely absent, and when we do,
# detect the arch (do NOT hard-code amd64 — broke on Apple-Silicon/arm64) using
# the same mapping as install-tools.sh, retry, and verify the SHA256 checksum.
if [[ ! -x "$OTELCOL" ]]; then
  # Only trust a baked-in otelcol-contrib if it matches the pinned version. The
  # canonical `cumulative_to_delta` name (ISI-7647) is unknown to builds older
  # than 0.164.0, so a stale PATH binary would reject the config spuriously.
  if command -v otelcol-contrib >/dev/null 2>&1 \
       && otelcol-contrib --version 2>/dev/null | grep -qw "${OTEL_COLLECTOR_VERSION#v}"; then
    OTELCOL="$(command -v otelcol-contrib)"
    log "using baked-in otelcol-contrib: ${OTELCOL}"
  else
    ver="${OTEL_COLLECTOR_VERSION#v}"
    case "$(uname -m)" in
      x86_64|amd64)  arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) echo "[validate] FAIL: unsupported arch for otelcol download: $(uname -m)" >&2; exit 2 ;;
    esac
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    log "otelcol-contrib not baked in — downloading ${ver} (${os}/${arch}) -> ${OTELCOL}"
    mkdir -p "$BIN_DIR"
    base="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${ver}"
    asset="otelcol-contrib_${ver}_${os}_${arch}.tar.gz"
    got=""
    for n in 1 2 3; do
      if curl -fsSL --retry 3 --retry-delay 2 -o /tmp/otelcol.$$.tgz "${base}/${asset}"; then got=1; break; fi
      echo "[validate] download attempt ${n}/3 failed; retrying..." >&2; sleep $((n * 2))
    done
    [[ -n "$got" ]] || { echo "[validate] FAIL: could not download ${asset} after retries" >&2; exit 2; }
    # Checksum (best-effort: skip only if sha256sum or the per-asset .sha256 side
    # file is unavailable; a real mismatch is fatal). GoReleaser publishes a
    # bare-hash <asset>.sha256 next to each asset.
    if command -v sha256sum >/dev/null 2>&1; then
      want="$(curl -fsSL "${base}/${asset}.sha256" 2>/dev/null | awk 'NF{print $1; exit}')"
      if [[ -n "$want" ]]; then
        have="$(sha256sum /tmp/otelcol.$$.tgz | awk '{print $1}')"
        [[ "$want" == "$have" ]] || { echo "[validate] FAIL: otelcol checksum mismatch (want $want, got $have)" >&2; rm -f /tmp/otelcol.$$.tgz; exit 2; }
        log "otelcol checksum verified"
      fi
    fi
    tar -xzf /tmp/otelcol.$$.tgz -C "$BIN_DIR" otelcol-contrib
    chmod +x "$OTELCOL"
    rm -f /tmp/otelcol.$$.tgz
  fi
fi

# --- 1. otelcol validate on each CR's embedded config ------------------------
# Deterministic offline env for `${env:...}` expansion inside the configs.
export DT_TENANT="${DT_TENANT:-https://validate.invalid}"
export DT_INGEST_TOKEN="${DT_INGEST_TOKEN:-validate-token}"

validate_config() { # file, cr-name
  local file="$1" name="$2"
  local tmp
  tmp="$(mktemp)"
  # The operator passes spec.config through VERBATIM (ISI-6806 live finding) —
  # validate exactly what ships; no manual `$${` un-escaping.
  "$YQ" '.spec.config' "$file" > "$tmp"
  if "$OTELCOL" validate --config "$tmp" >/dev/null 2>"$tmp.err"; then
    log "otelcol validate OK: ${name}"
  else
    err "otelcol validate FAILED for ${name}:"
    cat "$tmp.err" >&2
  fi
  rm -f "$tmp" "$tmp.err"
}

validate_config "${HERE}/collectors/gateway.yaml"  "otel-gateway (deployment)"
validate_config "${HERE}/collectors/daemonset.yaml" "otel-logs (daemonset)"

# --- 2. pipeline-order contract ----------------------------------------------
check_order() { # file, name, pipeline, expected-csv
  local file="$1" name="$2" pipeline="$3" expected="$4"
  local actual
  actual="$("$YQ" ".spec.config.service.pipelines.${pipeline}.processors | join(\", \")" "$file")"
  if [[ "$actual" == "$expected" ]]; then
    log "pipeline order OK: ${name}/${pipeline} = [${actual}]"
  else
    err "pipeline order WRONG: ${name}/${pipeline}"
    err "  expected: [${expected}]"
    err "  actual:   [${actual}]"
  fi
}

GW="${HERE}/collectors/gateway.yaml"
check_order "$GW" gateway traces  "memory_limiter, k8sattributes"
check_order "$GW" gateway metrics "memory_limiter, k8sattributes, cumulative_to_delta"
check_order "$GW" gateway logs    "memory_limiter, k8sattributes"
DS="${HERE}/collectors/daemonset.yaml"
check_order "$DS" daemonset logs  "memory_limiter"

# memory_limiter first / no batch processor anywhere, k8sattributes before
# cumulative_to_delta, cumulative_to_delta never outside metrics.
for file in "$GW" "$DS"; do
  name="$("$YQ" '.metadata.name' "$file")"
  while IFS= read -r line; do
    [[ "$line" == "" ]] && continue
    pipe="${line%%:*}"; procs="${line#*: }"
    first="${procs%%,*}"
    [[ "$first" == "memory_limiter" ]] || err "${name}/${pipe}: memory_limiter is not first"
    [[ ",${procs//, /,}," != *",batch,"* ]] || err "${name}/${pipe}: deprecated batch processor present (use exporter sending_queue.batch)"
    if [[ ",${procs}," == *",cumulative_to_delta,"* && "$pipe" != "metrics" ]]; then
      err "${name}/${pipe}: cumulative_to_delta outside the metrics pipeline"
    fi
  done < <("$YQ" '.spec.config.service.pipelines | to_entries | map(.key + ": " + (.value.processors | join(", "))) | .[]' "$file")
done

# --- 2b. exporter-level batching ---------------------------------------------
# Every exporter must enable sending_queue.batch (replacement for the batch processor).
for file in "$GW" "$DS"; do
  name="$("$YQ" '.metadata.name' "$file")"
  while IFS= read -r exp; do
    [[ "$exp" == "" ]] && continue
    en="$("$YQ" ".spec.config.exporters.\"${exp}\".sending_queue.batch.enabled" "$file")"
    [[ "$en" == "true" ]] && log "exporter batching OK: ${name}/${exp}" \
      || err "${name}/${exp}: sending_queue.batch.enabled is not true"
  done < <("$YQ" '.spec.config.exporters | keys | .[]' "$file")
done

# --- 3. k8s manifest sanity (cluster optional) --------------------------------
if kubectl get nodes >/dev/null 2>&1; then
  log "cluster reachable: kubectl dry-run on CRs"
  # CRD-ordering guard (ISI-7628/#64): the collector-CR dry-runs below need the
  # OpenTelemetryCollector CRD, which the OTel Operator installs. If the operator
  # isn't up yet the dry-run fails with an opaque 'no matches for kind
  # "OpenTelemetryCollector"'. Check the CRD FIRST so the error names the real
  # cause and points at the fix, instead of looking like a bad manifest.
  if ! kubectl get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; then
    err "OpenTelemetryCollector CRD missing — the OpenTelemetry Operator is not installed yet."
    err "  Install the observability stack first:  bash ${HERE##*/}/install.sh"
    err "  (cert-manager + the OTel Operator create the CRDs these collector CRs need.)"
  else
    kubectl apply --dry-run=server -f "${HERE}/collectors/namespace.yaml" >/dev/null || err "namespace dry-run failed"
    kubectl apply --dry-run=server -f "${HERE}/collectors/gateway.yaml"   >/dev/null || err "gateway CR dry-run failed"
    kubectl apply --dry-run=server -f "${HERE}/collectors/daemonset.yaml" >/dev/null || err "daemonset CR dry-run failed"
  fi
else
  log "no cluster reachable — skipping server-side dry-run (steps 1-2 already ran)"
fi

if [[ "$fail" -eq 0 ]]; then
  log "ALL CHECKS PASSED"
  exit 0
else
  err "validation failed — see output above"
  exit 1
fi
