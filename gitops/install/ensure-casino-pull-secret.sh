#!/usr/bin/env bash
# ensure-casino-pull-secret.sh — in-repo fallback for private casino images (ISI-7585).
#
# The 8 casino services run from ghcr.io/henrikrexed/vegasapp-*:0.39, which live
# in a PRIVATE personal GHCR namespace. Anonymous pulls return 403, so a fresh
# codespace lands the casino pods in ImagePullBackOff.
#
# Two ways to fix this (approved plan ISI-7577 §4 Track 1, decision D2):
#
#   PREFERRED (D2 default) — make the vegasapp-* packages PUBLIC. One-time
#     account-owner action in the GitHub UI; after that, anonymous pulls just
#     work and NO pull secret is needed. This script becomes a no-op (it skips
#     when no token is provided) and the `ghcr-pull` reference on the
#     vegas-casino ServiceAccount is harmless (kubelet falls back to anonymous).
#
#   FALLBACK (this script) — when a package-read token IS available, create a
#     `ghcr-pull` docker-registry Secret in the casino namespace so the private
#     images pull with auth. The vegas-casino ServiceAccount (k8s/00-config.yaml)
#     already references `ghcr-pull`, so every casino pod picks it up.
#
# IMPORTANT: the DEFAULT attendee GITHUB_PAT does NOT have read:packages on the
# henrikrexed/vegasapp-* packages (verified: PAT-authenticated manifest pull
# returns 404). For the fallback to actually pull, set CASINO_PULL_TOKEN to a
# token that CAN read those packages (read:packages on henrikrexed/vegasapp-*).
# If no such token is set, this script assumes the images are public and exits 0
# without creating a secret — never aborts the bootstrap.
#
# Idempotent and non-fatal: safe to re-run; a failure here must not stop GitOps
# bring-up (the images may already be public).
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
CASINO_NAMESPACE="${CASINO_NAMESPACE:-casino}"
PULL_SECRET_NAME="${CASINO_PULL_SECRET_NAME:-ghcr-pull}"
REGISTRY="${CASINO_REGISTRY:-ghcr.io}"

# Prefer an explicit, purpose-minted package-read token. Fall back to the tokens a
# fork codespace naturally carries (GITHUB_TOKEN / GH_TOKEN) and then GITHUB_PAT.
# For a FORK's OWN private images (ISI-7589 c3) these usually DO have read:packages
# on the attendee's namespace, so the fork pull works; for the upstream baseline
# (public) no token is needed at all and this script is a no-op.
TOKEN="${CASINO_PULL_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_PAT:-}}}}"
# ghcr.io ignores the username for token auth, but it must be non-empty.
USERNAME="${CASINO_PULL_USER:-${GITHUB_USER:-${GITHUB_ACTOR:-henrikrexed}}}"

log() { echo "==> ensure-casino-pull-secret: $*"; }

if [[ -z "$TOKEN" ]]; then
  log "no CASINO_PULL_TOKEN/GITHUB_TOKEN/GH_TOKEN/GITHUB_PAT set — assuming casino images are PUBLIC (D2 default); skipping pull secret."
  exit 0
fi

log "creating namespace '$CASINO_NAMESPACE' (idempotent; Argo CD also CreateNamespace=true)"
$KUBECTL create namespace "$CASINO_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

log "creating/updating docker-registry secret '$PULL_SECRET_NAME' in '$CASINO_NAMESPACE' (server=$REGISTRY)"
$KUBECTL -n "$CASINO_NAMESPACE" create secret docker-registry "$PULL_SECRET_NAME" \
  --docker-server="$REGISTRY" \
  --docker-username="$USERNAME" \
  --docker-password="$TOKEN" \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

log "done — casino pods pull private images via '$PULL_SECRET_NAME' (referenced by the vegas-casino ServiceAccount)."
log "NOTE: if pods still ImagePullBackOff with 403, the token lacks read:packages on henrikrexed/vegasapp-* — make the packages PUBLIC (D2 default) instead."
