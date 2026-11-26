#!/usr/bin/env bash
# postCreate.sh — runs ONCE when the codespace/devcontainer is first created.
#
# Tools are already baked into the image, so here we only:
#   1. verify the toolchain (self-heal any missing binary)
#   2. create the kind cluster
#   3. record cold-start timing for day-of pre-warm guidance
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_TS=$(date +%s)
TIMING_FILE="$HOME/.otel-training-coldstart.txt"

log() { echo "==> $*"; }

# Single `.env` flow (ISI-7629 / #61): load the ONE canonical repo-root `.env`
# into this bootstrap process (and into interactive shells) BEFORE anything
# reads PARTICIPANT_ID / FULL_DEPLOY / DT_* — so a local rebuild picks up the
# attendee's values with no manual `make`/`source`. No-op in Codespaces (vars
# arrive as secrets via remoteEnv).
# shellcheck source=/dev/null
source "$SCRIPT_DIR/load-env.sh"

# Enable the DCO sign-off hook (.githooks/prepare-commit-msg) so every commit made
# in the codespace carries a Signed-off-by trailer (the upstream repo enforces DCO).
# Non-fatal: a missing git identity or a non-git checkout must not block bring-up.
log "enabling DCO sign-off git hook"
git config core.hooksPath .githooks 2>/dev/null || log "WARN: could not set core.hooksPath (non-fatal); run 'make dco-setup' later."

log "verifying toolchain (self-heal if needed)"
bash "$SCRIPT_DIR/install-tools.sh"

# dtctl is the one toolchain binary whose download is non-fatal (region/proxy),
# so prove it landed right after bootstrap (ISI-7175). Non-fatal here too — a
# missing dtctl must not block the codespace from opening — but it prints a loud,
# actionable warning so attendees fix it before the Dynatrace-for-AI skills need
# it. `make verify` re-asserts the same check as a gating step.
bash "$SCRIPT_DIR/verify-dtctl.sh" || {
  echo "WARN: dtctl verify failed — see output above; re-install with:" >&2
  echo "WARN:   FORCE=1 bash .devcontainer/bootstrap/install-tools.sh" >&2
}

# Write/refresh the dtctl `training` context through the canonical helper
# (ISI-7872). verify-dtctl.sh above already persists the context via the same
# shared function, but calling configure-dtctl-context.sh here explicitly makes
# create-time and start-time use the identical code path (postStart.sh runs the
# same script on every start, so a restart heals a stale codespace). Writes an
# env-only context when no DT_PLATFORM_TOKEN exists, so the dtctl skill never
# hits "config file not found". Idempotent + non-fatal (self-skips when
# DT_TENANT/URL is absent).
log "configuring the dtctl 'training' context"
bash "$SCRIPT_DIR/configure-dtctl-context.sh" || log "WARN: configure-dtctl-context.sh reported an issue (non-fatal)."

# Mint the workshop LLM proxy credential and point opencode at it BEFORE the
# stack comes up, so the advanced instrumentation lab has its AI agent ready.
# dispense-llm.sh is non-fatal and self-skips when the WORKSHOP_* secrets are
# absent (i.e. outside the facilitated workshop), so this never blocks bring-up.
log "wiring the workshop LLM proxy (opencode)"
bash "$SCRIPT_DIR/dispense-llm.sh" || log "WARN: dispense-llm.sh reported an issue; opencode AI steps may be unavailable (non-fatal)."

# Install the Dynatrace dtctl Agent Skill into opencode (ISI-7176). Runs after
# both dtctl (verify-dtctl.sh above) and opencode (install-tools.sh) are known
# present. Explicit `--for opencode --global` install to
# ~/.config/opencode/skills/dtctl/; non-fatal and idempotent, and the skill
# re-uses the existing DT platform token (dt0s16) — no new secret.
log "installing the dtctl Agent Skill for opencode"
bash "$SCRIPT_DIR/install-dtctl-skill.sh" || log "WARN: install-dtctl-skill.sh reported an issue; the dtctl skill may be unavailable in opencode (non-fatal)."

# Install the Dynatrace-for-AI domain skills for opencode (ISI-7177 B3): DQL
# syntax, observability patterns, k8s/cloud context (38 dt-* skills). Separate
# from the dtctl skill above — dtctl ships its own installer, while these are a
# plain skills repo we fetch and copy (deterministic, node-free, version-pinned;
# see install-opencode-skills.sh). Both land in ~/.config/opencode/skills. Non-
# fatal so a network/region hiccup never blocks the codespace; verify-opencode-
# skills.sh is the loud gate right after, mirroring the dtctl verify above.
log "installing Dynatrace-for-AI opencode skills"
bash "$SCRIPT_DIR/install-opencode-skills.sh" || true
bash "$SCRIPT_DIR/verify-opencode-skills.sh" || {
  echo "WARN: opencode skills verify failed — see output above; re-install with:" >&2
  echo "WARN:   bash .devcontainer/bootstrap/install-opencode-skills.sh" >&2
}

log "standing up kind cluster"
bash "$SCRIPT_DIR/create-cluster.sh"

# FULL_DEPLOY toggle (ISI-6837 / ISI-7530). Attendees launch from main, so the
# full training stack must come up with ZERO manual steps — hence the default is
# ON here (and in devcontainer.json remoteEnv). Chaining into the orchestrator
# brings up observability + Dynatrace (SKIPped when DT_* absent) + Gateway API +
# GitOps-synced casino. A developer who only wants the base cluster sets
# FULL_DEPLOY=off in their host/localEnv. Idempotent either way.
case "${FULL_DEPLOY:-on}" in
  on|1|true|yes)
    log "FULL_DEPLOY=${FULL_DEPLOY:-on} — deploying the full training environment"
    bash "$SCRIPT_DIR/deploy-environment.sh" || {
      echo "WARN: full deploy reported errors; inspect and re-run:" >&2
      echo "WARN:   bash .devcontainer/bootstrap/deploy-environment.sh" >&2
    }
    ;;
  *)
    log "FULL_DEPLOY=${FULL_DEPLOY} — base cluster only (run 'bash .devcontainer/bootstrap/deploy-environment.sh' to deploy the stack)"
    ;;
esac

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
{
  echo "cold_start_seconds=$ELAPSED"
  echo "recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$TIMING_FILE"

cat <<EOF

================================================================
 OTel Training devcontainer is ready.
 - kind cluster:  ${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}
 - cold start:    ${ELAPSED}s  (saved to $TIMING_FILE)
 Verify with:     kubectl get nodes   &&   dtctl version   &&   opencode --version
 opencode skills: bash .devcontainer/bootstrap/verify-opencode-skills.sh
 Next tickets build the casino app, observability stack, and
 Dynatrace operator on top of this base.
================================================================
EOF
