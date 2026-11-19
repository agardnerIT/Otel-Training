#!/usr/bin/env bash
# lite-filter.sh — apply the casino "lite" profile to a directory of (already
# rendered) casino manifests, IN PLACE (ISI-7653 / ISI-7633-A).
#
# Lite = the smallest casino that still tells the full lab story. Per the WS7
# footprint audit (ISI-7633), roulette + dice are the ONLY two services that no
# lab uniquely depends on, so lite drops exactly those. The loadgen is then told
# to stop driving the dropped routes so it emits zero avoidable errors.
#
# Minimum viable topology lite preserves (full lab story):
#   scoring + slots + blackjack + frontend + redis + postgres + loadgen + gateway.
#
# This is a seed-time PLAIN-TEXT filter, deliberately NOT a kustomize overlay:
# the casino manifests stay plain YAML served from a flat directory so the
# edit -> commit -> Argo-sync lab mechanic (ISI-6796) keeps working unchanged.
# It is the single source of truth for "what lite drops" — both the Gitea seed
# (gitops/install/seed-gitea.sh) and the direct kubectl-apply path
# (.devcontainer/bootstrap/deploy-environment.sh) call it on a throwaway copy of
# the manifests, never on the committed source.
#
# Usage:  lite-filter.sh <manifests-dir>     # mutates files in <manifests-dir>
set -euo pipefail

DIR="${1:?usage: lite-filter.sh <manifests-dir>}"
[[ -d "$DIR" ]] || { echo "lite-filter.sh: not a directory: $DIR" >&2; exit 1; }

# 1) Drop the two games no lab uniquely needs (WS7 audit, ISI-7633). Each file
#    carries a game's Deployment + Service, so removing the file removes the
#    whole service from the applied/synced set.
LITE_DROP=(31-roulette.yaml 32-dice.yaml)
for f in "${LITE_DROP[@]}"; do
  if [[ -e "$DIR/$f" ]]; then
    rm -f "$DIR/$f"
    echo "lite-filter: dropped $f"
  fi
done

# 2) Narrow the k6 loadgen to the surviving games so it never calls the dropped
#    roulette/dice routes (which would 5xx now that those services are gone). The
#    load script reads GAMES (ISI-7653); the manifest ships the full four-game set
#    as a marker, so this seds it down to the lite subset. k6 already tolerates
#    non-2xx (thresholds:{} in the script), so this is a cleanliness win, not a
#    correctness gate — if the marker is ever renamed the loadgen still runs.
LOADGEN="$DIR/60-loadgen-k6.yaml"
if [[ -f "$LOADGEN" ]]; then
  if grep -q 'slots,roulette,dice,blackjack' "$LOADGEN"; then
    tmp="$(mktemp)"
    sed 's|slots,roulette,dice,blackjack|slots,blackjack|' "$LOADGEN" > "$tmp"
    mv "$tmp" "$LOADGEN"
    echo "lite-filter: set loadgen GAMES=slots,blackjack"
  else
    echo "lite-filter: WARN: GAMES marker not found in 60-loadgen-k6.yaml — loadgen may call dropped routes (non-fatal; k6 tolerates non-2xx)" >&2
  fi
fi
