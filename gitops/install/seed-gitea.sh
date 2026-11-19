#!/usr/bin/env bash
# seed-gitea.sh — create the attendee's git host account + casino repo, then push
# the canonical casino manifests so Argo CD has something to sync (ISI-6796).
#
# Single source of truth: the manifests pushed here come from the casino app-deploy
# ticket (ISI-6794), published to deploy/casino/k8s (the default below). Override
# CASINO_MANIFESTS_DIR to seed a different directory (e.g. gitops/seed/k8s for the
# original replicas-only placeholder demo). Re-running is safe (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GITEA_NS="${GITEA_NS:-gitea}"
GITEA_URL="${GITEA_URL:-http://localhost:30001}"     # forwarded NodePort in the codespace
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-attendee@otel.training}"
CASINO_ORG="${CASINO_ORG:-casino}"
CASINO_REPO="${CASINO_REPO:-casino}"
CASINO_MANIFESTS_DIR="${CASINO_MANIFESTS_DIR:-$REPO_ROOT/deploy/casino/k8s}"
KUBECTL="${KUBECTL:-kubectl}"

log()  { echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }
api() { curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" -H "Content-Type: application/json" "$@"; }

# Readiness wait is best-effort + loud (ISI-7555). On a loaded 8 GB codespace
# (obs + Dynatrace + NGF + Gitea all rolling at once) Gitea can miss a short
# window. A fatal timeout here used to abort the whole GitOps bring-up — seed is
# called under `set -e` from bootstrap-gitops.sh — BEFORE Argo CD installed, so
# there was no `argocd` namespace and no casino. Wait longer and never let the
# wait itself kill the run; the API/push steps below retry, and
# bootstrap-gitops.sh now treats a non-zero seed as non-fatal so Argo CD still
# installs and syncs once the repo lands.
log "waiting for Gitea to be ready (best-effort; up to 300s)"
$KUBECTL -n "$GITEA_NS" rollout status deploy/gitea --timeout=300s \
  || warn "Gitea deploy not Ready within 300s — continuing; API/push steps retry below"

# 1) Admin user — created inside the pod (SQLite), idempotent.
log "ensuring Gitea admin user '$GITEA_ADMIN_USER'"
# Wait for a running Gitea pod before exec'ing — under a slow roll the pod name
# may not exist yet (empty -> exec fails under set -e). Patient + non-fatal
# (ISI-7555); the HTTP API wait below is the real gate.
POD=""
for i in $(seq 1 30); do
  POD="$($KUBECTL -n "$GITEA_NS" get pod -l app.kubernetes.io/name=gitea \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$POD" ]] && break
  sleep 2
done
if [[ -n "$POD" ]]; then
  # gitea/gitea:1.22.6 runs the container as root, and Gitea *fatally refuses* to
  # run its CLI as root ("Gitea is not supposed to be run as root"). Exec the CLI
  # as the image's unprivileged 'git' user (uid 1000) via `su git -c`, and point
  # it at the baked app.ini explicitly (su may drop GITEA_* env) so it finds the
  # SQLite DB. The old `sh -c '... || echo user already exists'` ran as root, so
  # the create ALWAYS failed and the `|| echo` MASKED it — no admin user, so every
  # subsequent -u attendee:pass API call 401'd and the repo was never created
  # (ISI-7566). Capture output and distinguish a genuine "already exists"
  # (idempotent success) from a real failure; never swallow the error.
  create_rc=0
  create_out="$($KUBECTL -n "$GITEA_NS" exec "$POD" -- su git -c \
    "gitea --config /data/gitea/conf/app.ini admin user create \
       --username '$GITEA_ADMIN_USER' --password '$GITEA_ADMIN_PASS' \
       --email '$GITEA_ADMIN_EMAIL' --admin --must-change-password=false" 2>&1)" || create_rc=$?
  if [[ "$create_rc" -eq 0 ]]; then
    log "admin user '$GITEA_ADMIN_USER' created"
  elif echo "$create_out" | grep -qiE 'already exist'; then
    log "admin user '$GITEA_ADMIN_USER' already exists — ok (idempotent)"
  else
    warn "admin user create FAILED (rc=$create_rc): ${create_out:-<no output>}"
    warn "seeding will almost certainly be incomplete; the repo-existence gate in step 3 will surface it loudly and bail non-fatally so a re-run finishes it"
  fi
else
  warn "no Gitea pod found after ~60s — skipping in-pod admin create; the HTTP API wait below will gate the seed"
fi

# 2) Wait for the HTTP API to answer through the forwarded NodePort. Loud on
# timeout instead of silently falling through to blind API calls (ISI-7555): if
# the API never answers, bail non-zero so bootstrap-gitops.sh records the seed
# as incomplete and moves on to install Argo CD — a re-run finishes the seed.
log "waiting for Gitea HTTP API at $GITEA_URL (up to 120s)"
API_UP=0
for i in $(seq 1 60); do
  if curl -fsS "$GITEA_URL/api/healthz" >/dev/null 2>&1; then API_UP=1; break; fi
  sleep 2
done
if [[ "$API_UP" -ne 1 ]]; then
  warn "Gitea HTTP API did not answer at $GITEA_URL within 120s — skipping repo seed this pass."
  warn "Argo CD still installs; re-run deploy (idempotent) once Gitea is up to seed the casino repo."
  exit 1
fi

# 3) Organisation + repo (ignore 'already exists'), then VERIFY the repo is
# reachable with the admin creds before we try to push. Previously a missing
# admin user made these -u attendee:pass calls 401 silently (swallowed by
# `|| true`), and the only symptom was a confusing 404 on the git push five
# retries later (ISI-7566). Re-checking the repo with a GET turns that into a
# single loud, actionable WARN and keeps the seed re-runnable.
log "ensuring org '$CASINO_ORG' and repo '$CASINO_REPO'"
ensure_org_repo() {
  api -X POST "$GITEA_URL/api/v1/orgs" \
    -d "{\"username\":\"$CASINO_ORG\"}" >/dev/null 2>&1 || true
  api -X POST "$GITEA_URL/api/v1/orgs/$CASINO_ORG/repos" \
    -d "{\"name\":\"$CASINO_REPO\",\"default_branch\":\"main\",\"auto_init\":false}" >/dev/null 2>&1 || true
}
ensure_org_repo

# Confirm the repo exists (GET /repos/org/repo) with admin auth before pushing.
# Retry create+check a few times to ride out a slow first-settle.
REPO_OK=0
for i in $(seq 1 10); do
  if api "$GITEA_URL/api/v1/repos/$CASINO_ORG/$CASINO_REPO" >/dev/null 2>&1; then REPO_OK=1; break; fi
  ensure_org_repo
  sleep 3
done
if [[ "$REPO_OK" -ne 1 ]]; then
  warn "casino repo '$CASINO_ORG/$CASINO_REPO' is NOT reachable with admin creds ($GITEA_ADMIN_USER) — seeding is incomplete."
  warn "Most likely the admin user was never created (see step 1 above). Argo CD still installs; re-run deploy (idempotent) once Gitea admin auth works to finish seeding."
  exit 1
fi
log "casino repo '$CASINO_ORG/$CASINO_REPO' confirmed reachable with admin creds"

# 4) Push the canonical manifests.
if [[ ! -d "$CASINO_MANIFESTS_DIR" ]]; then
  echo "ERROR: CASINO_MANIFESTS_DIR not found: $CASINO_MANIFESTS_DIR" >&2
  exit 1
fi
PUSH_URL="http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@${GITEA_URL#http://}/${CASINO_ORG}/${CASINO_REPO}.git"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log "pushing manifests from $CASINO_MANIFESTS_DIR"
mkdir -p "$WORK/k8s"
# Resolve the ${IMAGE_OWNER}/${IMAGE_TAG} image placeholders (ISI-7587) to
# concrete values BEFORE pushing, so Argo CD syncs valid image refs instead of
# literal "${IMAGE_OWNER}" (which would be InvalidImageName). This is the single
# seed-time substitution point (plain-text sed, no kustomize — preserves the
# ISI-6794 plain-YAML + Argo decision). Baseline defaults (upstream owner,
# :latest) come from render-images.sh; c3 (ISI-7589) exports IMAGE_OWNER derived
# from the fork origin + adds a tag preflight ahead of this call. Fall back to a
# raw copy only if the renderer is absent (older placeholder-free manifests).
# Per-attendee cluster name baked into the seeded manifests (ISI-7654 / D1): the
# live kind cluster name ($KIND_CLUSTER_NAME == $PARTICIPANT_ID) becomes
# K8S_CLUSTER_NAME + the k8s.cluster.name resource attribute on every service, so
# a shared Dynatrace tenant can be filtered per participant. Resolved the same way
# as create-cluster.sh / deploy-environment.sh; defaults to otel-training.
CLUSTER_NAME="${CLUSTER_NAME:-${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}}"
# Fork-aware image owner (ISI-7589 c3). Baseline-first: if this repo's origin is
# the upstream repo, or a fork has not yet published its vegasapp-* images at the
# pinned tag, IMAGE_OWNER resolves to the upstream owner so a brand-new fork comes
# up on the baseline public images with zero pre-build. Once the attendee's fork
# build is published (or IMAGE_OWNER is set explicitly, e.g. by deploy-my-build.sh),
# it resolves to their namespace. The resolver only probes the registry for a real
# fork; it never fails the seed. Export it so render-images.sh substitutes it.
IMAGE_OWNER_HELPER="$REPO_ROOT/deploy/casino/image-owner.sh"
if [[ -f "$IMAGE_OWNER_HELPER" ]]; then
  # shellcheck source=deploy/casino/image-owner.sh
  source "$IMAGE_OWNER_HELPER"
  # casino_resolve_image_owner logs its reason to stderr; capture just the owner.
  IMAGE_OWNER="$(casino_resolve_image_owner "$REPO_ROOT")"
  export IMAGE_OWNER
  log "image owner resolved to '$IMAGE_OWNER'"
fi
RENDER="$REPO_ROOT/deploy/casino/render-images.sh"
if [[ -f "$RENDER" ]]; then
  log "rendering image owner/tag + cluster name (IMAGE_OWNER=${IMAGE_OWNER:-henrikrexed} IMAGE_TAG=${IMAGE_TAG:-$(tr -d '[:space:]' < "$REPO_ROOT/deploy/casino/IMAGE_VERSION" 2>/dev/null || echo latest)} CLUSTER_NAME=${CLUSTER_NAME})"
  SRC_DIR="$CASINO_MANIFESTS_DIR" CLUSTER_NAME="$CLUSTER_NAME" bash "$RENDER" -o "$WORK/k8s"
else
  warn "render-images.sh not found — copying manifests verbatim (image placeholders will NOT be resolved)"
  cp -r "$CASINO_MANIFESTS_DIR"/. "$WORK/k8s/"
fi

# Casino "lite" profile (ISI-7653): drop roulette+dice and narrow the loadgen to
# the surviving games before pushing, so Argo CD only ever sees the lite set.
# Seed-time plain-text filter (no kustomize — same contract as render-images.sh);
# $WORK/k8s is a throwaway temp so the committed source manifests are untouched.
# Default is "full": the knob is a no-op unless CASINO_PROFILE=lite.
CASINO_PROFILE="${CASINO_PROFILE:-full}"
if [[ "$CASINO_PROFILE" == "lite" ]]; then
  LITE_FILTER="$REPO_ROOT/deploy/casino/lite-filter.sh"
  if [[ -f "$LITE_FILTER" ]]; then
    log "CASINO_PROFILE=lite — dropping roulette+dice and narrowing the loadgen"
    bash "$LITE_FILTER" "$WORK/k8s" || warn "lite-filter reported errors (continuing; seeding whatever remains)"
  else
    warn "CASINO_PROFILE=lite but $LITE_FILTER not found — seeding the FULL manifest set"
  fi
fi
(
  cd "$WORK"
  git init -q -b main
  git config user.email "$GITEA_ADMIN_EMAIL"
  git config user.name "$GITEA_ADMIN_USER"
  git add .
  git commit -q -m "Seed casino manifests (source of truth: ISI-6794)"
  # Retry the push — on a slow codespace the org/repo create above may still be
  # settling the first time around (ISI-7555). Idempotent (force-push to main).
  pushed=0
  for i in $(seq 1 5); do
    if git push -q -f "$PUSH_URL" main; then pushed=1; break; fi
    sleep 3
  done
  [[ "$pushed" -eq 1 ]] || { echo "ERROR: failed to push casino manifests to Gitea after 5 tries" >&2; exit 1; }
)

cat <<EOF

================================================================
 Gitea seeded.
   Repo (UI):      $GITEA_URL/$CASINO_ORG/$CASINO_REPO
   Repo (in-cluster for Argo CD):
                   http://gitea-http.$GITEA_NS.svc:3000/$CASINO_ORG/$CASINO_REPO.git
   Login:          $GITEA_ADMIN_USER / $GITEA_ADMIN_PASS
   Edit a file under k8s/, commit, push  ->  Argo CD auto-syncs it.
================================================================
EOF
