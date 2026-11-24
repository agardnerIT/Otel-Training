#!/usr/bin/env bash
# Catalog B7 — deploy the collector pipeline-health dashboard with dtctl.
#
# dtctl is installed by the codespace bootstrap (verify with `dtctl version`;
# ISI-7175) and authenticates with the platform token (dt0s16...) already in the
# environment — no extra secret. In the exercise, opencode drives the `dtctl`
# skill to GENERATE this document from the collector's otelcol_* self-telemetry;
# this script is the equivalent manual apply so facilitators can deploy the
# reference directly.
#
# dtctl is kubectl-style: `apply -f <file>` (with `--dry-run` to validate first),
# not a `dashboard <verb>` command group. The dashboard identity comes from the
# document body (the `name` field), so we stamp PARTICIPANT_ID into a copy.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${HERE}/collector-health-dashboard.json"
NAME="${PARTICIPANT_ID:-casino}-collector-health"

# Stamp the per-attendee name into the document body (identity is in the JSON,
# not a flag). Requires jq (present in the codespace).
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT
jq --arg n "${NAME}" '.name = $n' "${DOC}" > "${RENDERED}"

# Validate before deploying (dt-app-dashboards discipline: never push an
# unvalidated dashboard). --dry-run is fail-closed on a bad schema or DQL.
dtctl apply -f "${RENDERED}" --dry-run

# Create or update the dashboard.
dtctl apply -f "${RENDERED}"

echo "Deployed dashboard: ${NAME}"
echo "Open it from Dynatrace > Dashboards, or re-run with an edited ${DOC}."
