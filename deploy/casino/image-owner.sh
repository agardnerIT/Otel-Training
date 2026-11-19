#!/usr/bin/env bash
# image-owner.sh — resolve which GHCR namespace the casino images are pulled from
# (ISI-7589 c3). Sourceable library + a small CLI for debugging.
#
# The casino manifests carry ${IMAGE_OWNER}/${IMAGE_TAG} placeholders (ISI-7587).
# render-images.sh substitutes them; THIS file decides the *owner* value, so the
# seed/deploy path can be FORK-AWARE without ever breaking a brand-new fork:
#
#   * Baseline-first (accepted plan ISI-7577 §4.1 / D4). A fresh fork launches on
#     the UPSTREAM baseline public images with zero pre-build — resolution returns
#     the upstream owner unless a fork build is PROVEN to exist.
#   * Fork-aware. The owner is derived from the fork's git origin (same pattern as
#     PARTICIPANT_ID). A real fork is only adopted once a tag PREFLIGHT confirms
#     the fork actually published ghcr.io/<fork>/otel-training/vegasapp-* at the
#     pinned tag — otherwise we stay on baseline and say so. This keeps the
#     automatic bring-up self-healing: before the attendee builds, baseline; after
#     their Actions publish, their images; and it never pulls a non-existent ref
#     (which would be ImagePullBackOff).
#   * Explicit override always wins. If IMAGE_OWNER is already set in the env
#     (e.g. `deploy-my-build.sh` exports IMAGE_OWNER=<me>), it is honoured verbatim
#     and no preflight is done — the attendee asked for a specific owner.
#
# Deliberately plain sed/curl, no kustomize/Helm — same contract as
# render-images.sh (ISI-6794 plain-YAML + Argo CD decision).
#
# Usage (CLI, for debugging):
#   deploy/casino/image-owner.sh owner           # print the resolved image owner
#   deploy/casino/image-owner.sh fork-owner      # print the owner derived from origin
#   deploy/casino/image-owner.sh preflight OWNER [TAG]   # exit 0 if fork images exist
#
# Usage (library):
#   source deploy/casino/image-owner.sh
#   IMAGE_OWNER="$(casino_resolve_image_owner)"; export IMAGE_OWNER

# NB: no `set -e` here — this file is SOURCED by scripts that manage their own
# error policy, and a non-zero preflight must never abort the caller.

CASINO_UPSTREAM_OWNER="${CASINO_UPSTREAM_OWNER:-henrikrexed}"
CASINO_IMAGE_REPO="${CASINO_IMAGE_REPO:-otel-training}"
# Representative image the preflight probes. CI publishes the whole vegasapp-*
# set together on one push (.github/workflows/casino-images.yml matrix), so the
# presence of one image at the pinned tag is a sound proxy for "the fork build
# finished". frontend is always deployed in every profile.
CASINO_PREFLIGHT_IMAGE="${CASINO_PREFLIGHT_IMAGE:-vegasapp-frontend}"
CASINO_REGISTRY_HOST="${CASINO_REGISTRY_HOST:-ghcr.io}"

_cio_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Human-readable reason for the last resolution. Initialised so `set -u` callers
# never trip on it; the resolver also logs the reason to stderr so it survives a
# command-substitution call (where this global is set only in the subshell).
CASINO_IMAGE_OWNER_REASON=""

_cio_log()  { echo "==> image-owner: $*" >&2; }

# casino_default_tag — the immutable version CI publishes (deploy/casino/IMAGE_VERSION),
# matching render-images.sh's default. Falls back to :latest if the file is absent.
casino_default_tag() {
  local vf="$_cio_dir/IMAGE_VERSION" t=""
  [[ -r "$vf" ]] && t="$(tr -d '[:space:]' < "$vf")"
  echo "${t:-latest}"
}

# casino_fork_owner_from_origin [repo_dir] — parse the GitHub owner out of the
# repo's `origin` remote. Handles https (optionally with an embedded token) and
# ssh forms. Lowercased (GHCR namespaces are lowercase). Falls back to the
# upstream owner when origin is missing / unparseable (local clone, no remote).
casino_fork_owner_from_origin() {
  local repo_dir="${1:-$_cio_dir}" url owner
  url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    echo "$CASINO_UPSTREAM_OWNER"; return 0
  fi
  # Strip scheme + any user:token@ credentials, then take the path segment after
  # the host. Works for:
  #   https://github.com/OWNER/repo.git
  #   https://x-access-token:TOKEN@github.com/OWNER/repo.git
  #   git@github.com:OWNER/repo.git
  #   ssh://git@github.com/OWNER/repo.git
  owner="$(printf '%s' "$url" \
    | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#^[^@/]*@##; s#^[^/:]+[/:]##; s#/.*$##')"
  owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$owner" ]]; then
    echo "$CASINO_UPSTREAM_OWNER"; return 0
  fi
  echo "$owner"
}

# _cio_registry_token owner — mint a ghcr.io pull-scope bearer token for the
# frontend repo. Anonymous works for PUBLIC packages; a token (CASINO_PULL_TOKEN /
# GITHUB_TOKEN / GH_TOKEN / GITHUB_PAT) lets the preflight also see a PRIVATE fork
# build. Prints the bearer token, or nothing on failure.
_cio_registry_token() {
  local owner="$1" scope resp tok
  scope="repository:${owner}/${CASINO_IMAGE_REPO}/${CASINO_PREFLIGHT_IMAGE}:pull"
  local pat="${CASINO_PULL_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_PAT:-}}}}"
  if [[ -n "$pat" ]]; then
    resp="$(curl -fsS --max-time 10 -u "x:${pat}" \
      "https://${CASINO_REGISTRY_HOST}/token?service=${CASINO_REGISTRY_HOST}&scope=${scope}" 2>/dev/null || true)"
  else
    resp="$(curl -fsS --max-time 10 \
      "https://${CASINO_REGISTRY_HOST}/token?service=${CASINO_REGISTRY_HOST}&scope=${scope}" 2>/dev/null || true)"
  fi
  # Response is JSON: {"token":"..."} (ghcr also returns access_token). Parse
  # without jq (may be absent).
  tok="$(printf '%s' "$resp" | sed -E 's/.*"(access_)?token":"([^"]+)".*/\2/;t;d')"
  printf '%s' "$tok"
}

# casino_preflight_image owner [tag] [image] — exit 0 iff the image manifest for
# ghcr.io/<owner>/otel-training/<image>:<tag> EXISTS (HTTP 200). Any other outcome
# (404, 401/403 unauthorised, network error, curl missing) → non-zero = "not
# proven to exist", so the caller stays on baseline. Short-timeout + fail-soft:
# never hangs or aborts a bring-up.
casino_preflight_image() {
  local owner="$1" tag="${2:-$(casino_default_tag)}" image="${3:-$CASINO_PREFLIGHT_IMAGE}"
  command -v curl >/dev/null 2>&1 || return 1
  local bearer code
  bearer="$(_cio_registry_token "$owner")"
  [[ -n "$bearer" ]] || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer ${bearer}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://${CASINO_REGISTRY_HOST}/v2/${owner}/${CASINO_IMAGE_REPO}/${image}/manifests/${tag}" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

# casino_resolve_image_owner [repo_dir] — the resolution the seed/deploy path uses.
# Prints the owner to use; sets CASINO_IMAGE_OWNER_REASON for logging.
casino_resolve_image_owner() {
  local repo_dir="${1:-$_cio_dir}" tag fork
  tag="${IMAGE_TAG:-$(casino_default_tag)}"

  # 1) Explicit override wins, no preflight — the attendee / caller asked for it.
  if [[ -n "${IMAGE_OWNER:-}" ]]; then
    CASINO_IMAGE_OWNER_REASON="explicit IMAGE_OWNER override"
    _cio_log "owner='$(printf '%s' "$IMAGE_OWNER" | tr '[:upper:]' '[:lower:]')' — $CASINO_IMAGE_OWNER_REASON"
    printf '%s' "$(printf '%s' "$IMAGE_OWNER" | tr '[:upper:]' '[:lower:]')"
    return 0
  fi

  # 2) Derive the fork owner from origin. Upstream == baseline, no preflight.
  fork="$(casino_fork_owner_from_origin "$repo_dir")"
  if [[ "$fork" == "$CASINO_UPSTREAM_OWNER" ]]; then
    CASINO_IMAGE_OWNER_REASON="origin is the upstream repo — baseline images"
    _cio_log "owner='$CASINO_UPSTREAM_OWNER' — $CASINO_IMAGE_OWNER_REASON"
    printf '%s' "$CASINO_UPSTREAM_OWNER"
    return 0
  fi

  # 3) A real fork — only adopt it if the fork build is PROVEN published.
  if casino_preflight_image "$fork" "$tag"; then
    CASINO_IMAGE_OWNER_REASON="fork build detected at ghcr.io/${fork}/${CASINO_IMAGE_REPO}/*:${tag}"
    _cio_log "owner='$fork' — $CASINO_IMAGE_OWNER_REASON"
    printf '%s' "$fork"
    return 0
  fi

  CASINO_IMAGE_OWNER_REASON="fork '${fork}' has no published vegasapp-* at tag ${tag} yet — staying on upstream baseline (run deploy-my-build.sh after your fork Actions finish)"
  _cio_log "owner='$CASINO_UPSTREAM_OWNER' — $CASINO_IMAGE_OWNER_REASON"
  printf '%s' "$CASINO_UPSTREAM_OWNER"
  return 0
}

# CLI entrypoint — only when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
  cmd="${1:-owner}"
  case "$cmd" in
    owner)
      # The resolver logs the reason to stderr itself; just print the owner.
      casino_resolve_image_owner
      echo
      ;;
    fork-owner)
      casino_fork_owner_from_origin
      ;;
    preflight)
      [[ $# -ge 2 ]] || { echo "usage: image-owner.sh preflight OWNER [TAG]" >&2; exit 2; }
      if casino_preflight_image "$2" "${3:-}"; then
        _cio_log "PRESENT: ghcr.io/$2/${CASINO_IMAGE_REPO}/${CASINO_PREFLIGHT_IMAGE}:${3:-$(casino_default_tag)}"
      else
        _cio_log "ABSENT:  ghcr.io/$2/${CASINO_IMAGE_REPO}/${CASINO_PREFLIGHT_IMAGE}:${3:-$(casino_default_tag)}"
        exit 1
      fi
      ;;
    -h|--help|help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "image-owner.sh: unknown command '$cmd' (try: owner | fork-owner | preflight)" >&2
      exit 2
      ;;
  esac
fi
