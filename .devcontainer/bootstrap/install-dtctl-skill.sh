#!/usr/bin/env bash
# install-dtctl-skill.sh — install the Dynatrace **dtctl Agent Skill** into the
# attendee's terminal agents during codespace bootstrap (ISI-7176, ISI-7169·B2,
# ISI-7655/ISI-7633-C).
#
# We INSTALL the ready-made skill that ships embedded in the dtctl CLI — we do
# not author it. Once installed, the agent auto-loads it so attendees can drive
# Dynatrace (incidents, DQL, logs, SLOs, dashboards…) from the terminal agent.
#
# --- Per-client install for cross-client coverage (ISI-7655) -----------------
# The advanced lab is opencode-first (ISI-7558), but attendees may also run
# Claude Code, and the board wants the Dynatrace tooling available in BOTH. The
# `dtctl skills install --cross-client` flag floated in the parent ticket is
# FICTIONAL — verified against dtctl 0.17.0 AND the pinned v0.45.0 the codespace
# installs: the only skills-install flags are `--for {claude,copilot,cursor,
# kiro,opencode}`, `--global`, `--force`, `--list` (and the global `--plain`
# output mode). There is no single cross-client switch. So we achieve
# cross-client coverage the supported way: LOOP the install, once per client.
#
# We target each agent EXPLICITLY and install GLOBALLY. We do NOT rely on
# auto-detect: detection is driven by per-agent env vars (OPENCODE, CLAUDE…)
# that are not set in a plain non-interactive bootstrap shell, so a bare
# `dtctl skills install` with no `--for` would pick the wrong agent (or none).
# Pinning `--for <client>` makes every attendee's install deterministic.
#
# Resolved install targets (verified against pinned dtctl v0.45.0 /
# `dtctl skills install --list`; both `opencode` and `claude` report
# supports_global=true):
#   --for opencode --global  ->  ~/.config/opencode/skills/dtctl/SKILL.md
#   --for claude   --global  ->  ~/.claude/skills/dtctl/  (SKILL.md; older builds
#                                 wrote ~/.claude/commands/dtctl.md)
# Both are the agent's documented GLOBAL skill-discovery directory.
#
# Fallback: older dtctl builds (<0.45) do not support global install for some
# agents and instead install project-scoped. opencode/Claude Code both walk up
# from the cwd to the git worktree root and load `.opencode/skills/*/SKILL.md` /
# `.claude/skills/*/SKILL.md` (and the legacy command-file layouts), so a
# repo-root project install is loaded in every workshop session too. We try
# global first, then fall back to project-scoped — per client.
#
# --- Auth --------------------------------------------------------------------
# The skill operates Dynatrace through the dtctl CLI, which authenticates with
# the EXISTING DT platform token (dt0s16) already provisioned in the codespace
# env (DT_PLATFORM_TOKEN / DT_ENVIRONMENT — see .devcontainer/.env.example and
# ISI-7165). No new secret is introduced here. Installing the skill itself needs
# no credentials — it only copies embedded files onto disk.
#
# --- Contract (same shape as verify-dtctl.sh / dispense-llm.sh) --------------
#   * Non-interactive: `--force` + `--plain`, no prompts.
#   * Idempotent: re-running is a no-op unless FORCE=1.
#   * Non-fatal: any failure warns and exits 0 so it never blocks bring-up.
#   * Records/pins the installed skill version (== the dtctl version, since the
#     skill is embedded in the CLI binary) to a marker file, one line per client.
set -uo pipefail

SKILL_NAME="dtctl"
MARKER="${HOME}/.otel-training-dtctl-skill.txt"

# Clients to install the dtctl skill for, for cross-client coverage. Overridable
# for mirrors/tests (e.g. DTCTL_SKILL_CLIENTS="opencode" to narrow). Both of the
# defaults report supports_global=true under `dtctl skills install --list`.
read -r -a CLIENTS <<< "${DTCTL_SKILL_CLIENTS:-opencode claude}"

log()  { echo "==> dtctl-skill: $*"; }
warn() { echo "==> dtctl-skill: WARN: $*" >&2; }

# --- 1. Precondition: dtctl must be present ----------------------------------
# The skill ships embedded in the dtctl binary, so dtctl is the only hard
# dependency. The agent binaries (opencode / claude) are NOT required to install
# the skill files — they are static files the agent loads later — so we install
# for every client regardless of which agent binary is on PATH, and only report
# binary presence informationally.
if ! command -v dtctl >/dev/null 2>&1; then
  warn "dtctl is not on PATH — skipping skill install (non-fatal)."
  warn "run the toolchain first:  FORCE=1 bash .devcontainer/bootstrap/install-tools.sh"
  exit 0
fi

DTCTL_VER="$(dtctl version 2>/dev/null | head -1 | sed 's/^dtctl version //' || echo unknown)"
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)"

for agent_bin in opencode claude; do
  if command -v "$agent_bin" >/dev/null 2>&1; then
    log "agent present: ${agent_bin} ($("$agent_bin" --version 2>/dev/null | head -1 || echo 'version check deferred'))"
  else
    log "agent not on PATH: ${agent_bin} (skill still installed for it; the files load if it is used later)"
  fi
done

# Resolve the SKILL.md / command file the given CLIENT will load — checked in
# priority order (global dir first, then the project paths the fallback / older
# dtctl builds use). We look for the file on disk rather than parsing dtctl's
# stdout so the check holds regardless of its output mode (human table vs agent
# JSON envelope). Covers both the v0.45 skills-dir layout and the legacy
# command-file layout for each agent.
installed_skill_path() {
  local client="$1" cand candidates=()
  case "$client" in
    opencode)
      candidates=(
        "${HOME}/.config/opencode/skills/${SKILL_NAME}/SKILL.md"
        "${REPO_ROOT}/.opencode/skills/${SKILL_NAME}/SKILL.md"
        "${REPO_ROOT}/.opencode/commands/${SKILL_NAME}.md"
      )
      ;;
    claude)
      candidates=(
        "${HOME}/.claude/skills/${SKILL_NAME}/SKILL.md"
        "${HOME}/.claude/commands/${SKILL_NAME}.md"
        "${REPO_ROOT}/.claude/skills/${SKILL_NAME}/SKILL.md"
        "${REPO_ROOT}/.claude/commands/${SKILL_NAME}.md"
      )
      ;;
    *)
      # Generic best-effort for any other agent: common global + project spots.
      candidates=(
        "${HOME}/.config/${client}/skills/${SKILL_NAME}/SKILL.md"
        "${REPO_ROOT}/.${client}/skills/${SKILL_NAME}/SKILL.md"
        "${REPO_ROOT}/.${client}/commands/${SKILL_NAME}.md"
      )
      ;;
  esac
  for cand in "${candidates[@]}"; do
    if [[ -f "$cand" ]]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

# --- 2. Idempotency ----------------------------------------------------------
# Skip entirely only when EVERY requested client already has a skill file.
# Otherwise fall through and (re)install the ones that are missing.
if [[ "${FORCE:-0}" != "1" ]]; then
  all_present=1
  for client in "${CLIENTS[@]}"; do
    installed_skill_path "$client" >/dev/null 2>&1 || { all_present=0; break; }
  done
  if [[ "$all_present" == "1" ]]; then
    log "dtctl skill already installed for all clients (${CLIENTS[*]}) — skipping."
    log "(set FORCE=1 to reinstall / refresh.)"
    exit 0
  fi
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# --- 3. Install: explicit target, global, non-interactive — one per client ---
# Try a global install first, fall back to a project-scoped install at the repo
# root. One client failing does not abort the others.
install_for_client() {
  local client="$1"
  log "installing the dtctl Agent Skill for ${client} (global, non-interactive)…"
  if dtctl skills install --for "$client" --global --force --plain >"$OUT" 2>&1; then
    sed 's/^/    /' "$OUT"
    return 0
  fi
  warn "global ${client} install failed — dtctl said:"
  sed 's/^/    /' "$OUT" >&2
  log "falling back to a project-scoped install at the repo root (${REPO_ROOT})."
  log "${client} walks up to the git worktree root, so a repo-root skill is loaded"
  log "in every workshop session too."
  if ( cd "$REPO_ROOT" && dtctl skills install --for "$client" --force --plain ) >"$OUT" 2>&1; then
    sed 's/^/    /' "$OUT"
    return 0
  fi
  warn "project-scoped ${client} install also failed — dtctl said:"
  sed 's/^/    /' "$OUT" >&2
  return 1
}

for client in "${CLIENTS[@]}"; do
  install_for_client "$client" || true
done

# --- 4. Verify each client can actually see an installed skill file ----------
# Build the marker as we go so it records exactly what each client received.
installed_count=0
{
  echo "skill=${SKILL_NAME}"
  echo "dtctl_version=${DTCTL_VER}"
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${MARKER}"

for client in "${CLIENTS[@]}"; do
  found="$(installed_skill_path "$client" || true)"
  if [[ -n "$found" ]]; then
    log "dtctl skill installed for ${client} at: ${found}"
    echo "client=${client} installed_path=${found}" >> "${MARKER}"
    installed_count=$((installed_count + 1))
  else
    warn "could not verify an installed dtctl skill file for ${client} (non-fatal)."
    echo "client=${client} installed_path=MISSING" >> "${MARKER}"
  fi
done

if [[ "$installed_count" -eq 0 ]]; then
  warn "no dtctl skill could be verified for any client (${CLIENTS[*]}) — non-fatal."
  warn "inspect with:  dtctl skills install --list"
  warn "retry with:    FORCE=1 bash .devcontainer/bootstrap/install-dtctl-skill.sh"
  exit 0
fi

log "recorded install marker at ${MARKER}:"
sed 's/^/    /' "${MARKER}"

cat <<EOF

================================================================
 dtctl Agent Skill installed for: ${CLIENTS[*]}  (${installed_count}/${#CLIENTS[@]} verified)
   via:    dtctl ${DTCTL_VER}  (skill embedded in the CLI)
 Each agent auto-loads this skill (name: '${SKILL_NAME}'). It drives
 Dynatrace via the dtctl CLI, authenticated by the EXISTING platform
 token (dt0s16) in DT_PLATFORM_TOKEN / DT_ENVIRONMENT — no new secret.
 Confirm any time with:  dtctl skills install --list
================================================================
EOF
exit 0
