#!/usr/bin/env bash
# verify-opencode-skills.sh — prove the attendee codespace is LAB-READY for the
# opencode-first advanced track (ISI-7558): opencode itself is present AND all
# three Agent-Skill sets the lab leans on are installed and loadable —
#   • observability / OpenTelemetry skills  (ISI-7563 · Child B, otel-*)
#   • Dynatrace-for-AI domain skills        (ISI-7177 · B3, dt-*)
#   • the dtctl CLI skill                    (ISI-7176 · B2, dtctl)
#
# install-opencode-skills.sh + install-dtctl-skill.sh copy these into opencode's
# skills dir but are deliberately NON-fatal (a region/network hiccup must not
# block the codespace from opening). This check surfaces an absent/malformed
# skill — or a missing opencode binary — immediately, as a first-class readiness
# gate at M0, the same role verify-dtctl.sh plays for the dtctl binary. postCreate
# runs it best-effort/loud (ISI-7555 pattern): it exits 1 on a gap so the gate is
# real, but bootstrap wraps it in `|| WARN` so the codespace still opens.
#
# What "loadable by opencode" means here (grounded in the opencode skills docs):
# opencode discovers skills by scanning fixed GLOBAL directories for
# <skill>/SKILL.md files with YAML frontmatter (name + description). So the
# deterministic proof that opencode WILL load a skill is: the SKILL.md exists in
# one of those directories and has valid frontmatter. We assert exactly that for
# a representative set from each skill package.
#
# Exit codes:
#   0  opencode present AND every required skill present with valid frontmatter
#   1  opencode missing, or one or more required skills missing/malformed
set -uo pipefail

# Required skill sets, one representative handful per installed package. Each is
# overridable so a mirror/offline run can narrow or widen the gate.
#   OPENCODE_REQUIRED_OBS_SKILLS   — henrikrexed/observability-agent-skills (otel-*)
#   OPENCODE_REQUIRED_SKILLS       — Dynatrace/dynatrace-for-ai (dt-*)  [legacy name kept]
#   OPENCODE_REQUIRED_DTCTL_SKILLS — the dtctl CLI skill (install-dtctl-skill.sh)
SET_NAMES=(
  "observability / OpenTelemetry (otel-*)"
  "Dynatrace-for-AI (dt-*)"
  "dtctl CLI skill"
)
SET_SKILLS=(
  "${OPENCODE_REQUIRED_OBS_SKILLS:-otel-instrumentation otel-ottl otel-dynatrace}"
  "${OPENCODE_REQUIRED_SKILLS:-dt-dql-essentials dt-obs-kubernetes dt-obs-services}"
  "${OPENCODE_REQUIRED_DTCTL_SKILLS:-dtctl}"
)

# opencode GLOBAL skills directories, in the precedence order opencode scans.
# (Project-level .opencode/skills etc. also work but bootstrap installs globally.)
CANDIDATE_DIRS=(
  "${OPENCODE_SKILLS_DIR:-}"
  "$HOME/.config/opencode/skills"
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

bold "== opencode lab-readiness verify (opencode + obs + Dynatrace-for-AI + dtctl skills) =="

missing=0

# 1. opencode binary present — the advanced lab is opencode-first, so this is a
#    gate, not a bonus. install-tools.sh installs it earlier in bootstrap.
if command -v opencode >/dev/null 2>&1; then
  ok "opencode on PATH: $(opencode --version 2>/dev/null || echo 'version check deferred')"
else
  bad "opencode NOT on PATH — the advanced lab is opencode-first; install-tools.sh installs it"
  missing=$((missing + 1))
fi

# Locate the SKILL.md for a skill across the candidate opencode dirs.
find_skill_md() {
  local name="$1" dir
  for dir in "${CANDIDATE_DIRS[@]}"; do
    [[ -n "$dir" && -f "$dir/$name/SKILL.md" ]] && { printf '%s\n' "$dir/$name/SKILL.md"; return 0; }
  done
  return 1
}

# A SKILL.md "opencode can load" must open with a YAML frontmatter block that
# carries at least name: and description:.
has_valid_frontmatter() {
  local f="$1"
  head -n1 "$f" | grep -q '^---[[:space:]]*$' || return 1
  local fm; fm="$(awk 'NR>1{ if($0 ~ /^---[[:space:]]*$/) exit; print }' "$f")"
  printf '%s\n' "$fm" | grep -q '^name:' || return 1
  printf '%s\n' "$fm" | grep -q '^description:' || return 1
  return 0
}

# 2. Each skill set: assert a representative handful is present + loadable.
for i in "${!SET_NAMES[@]}"; do
  bold "— ${SET_NAMES[$i]}"
  # shellcheck disable=SC2206
  skills=(${SET_SKILLS[$i]})
  for sk in "${skills[@]}"; do
    if md="$(find_skill_md "$sk")"; then
      if has_valid_frontmatter "$md"; then
        pin="$(cat "$(dirname "$md")/.installed-from" 2>/dev/null || echo 'unpinned')"
        ok "${sk}: loadable (${md#"$HOME"/}) [${pin}]"
      else
        bad "${sk}: SKILL.md present but frontmatter invalid (${md}) — opencode will skip it"
        missing=$((missing + 1))
      fi
    else
      bad "${sk}: not found in any opencode skills directory"
      missing=$((missing + 1))
    fi
  done
done

# Show the recorded pin manifest if present (install-opencode-skills.sh lock).
for dir in "${CANDIDATE_DIRS[@]}"; do
  [[ -n "$dir" && -f "$dir/.dynatrace-skills.lock" ]] && {
    bold "recorded pins (${dir}/.dynatrace-skills.lock):"
    sed 's/^/    /' "$dir/.dynatrace-skills.lock"
    break
  }
done

if [[ "$missing" -ne 0 ]]; then
  bad "RESULT: ${missing} lab-readiness check(s) failed (opencode and/or skills missing/malformed)"
  cat >&2 <<EOF

The codespace is not fully lab-ready. The install steps are non-fatal, so
bootstrap continued without them. (Re)install the opencode skills with:

  bash .devcontainer/bootstrap/install-opencode-skills.sh   # obs + Dynatrace-for-AI
  bash .devcontainer/bootstrap/install-dtctl-skill.sh        # dtctl CLI skill

Behind a proxy / in an air-gapped region, point the installer at a reachable
source (per-repo override or the global fallback):

  OPENCODE_SKILLS_SRC_DIR=<local checkout of the repo> \\
    bash .devcontainer/bootstrap/install-opencode-skills.sh

If opencode itself is missing, re-run the toolchain install:

  FORCE=1 bash .devcontainer/bootstrap/install-tools.sh
EOF
  exit 1
fi

bold "RESULT: lab-ready — opencode present and all skill sets loadable"
exit 0
