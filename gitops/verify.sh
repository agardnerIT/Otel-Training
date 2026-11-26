#!/usr/bin/env bash
# verify.sh — live runtime verification of the GitOps path (ISI-6796).
#
# Executable form of ISI-6796's acceptance criteria. The manifests/scripts are
# validated offline, but "Application Synced+Healthy" and "a commit triggers a
# sync that updates the running workload" can only be proven against a live
# cluster, so this runs on the first full dry-run / day-of pre-warm.
#
# Run it AFTER the GitOps path is up:
#   bash gitops/bootstrap/bootstrap-gitops.sh
# (or via the orchestrator: DEPLOY_MODE=gitops deploy-environment.sh)
#
# The AC#2 test-commit is deliberately NON-INVASIVE: it adds and then prunes a
# throwaway ConfigMap in the casino namespace via git, so the real casino
# services are never disturbed. This also exercises Argo CD prune.
#
# Exit code 0 = all checks passed. Non-zero = at least one check failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
APP="${ARGOCD_APP:-casino}"
CASINO_NS="${CASINO_NS:-casino}"
GITEA_NS="${GITEA_NS:-gitea}"
GITEA_URL="${GITEA_URL:-http://localhost:30001}"
GITEA_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"
CASINO_ORG="${CASINO_ORG:-casino}"
CASINO_REPO="${CASINO_REPO:-casino}"
EXPECTED_SRC="${EXPECTED_MANIFESTS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/deploy/casino/k8s}"
# In the lite profile seed-gitea.sh deliberately drops some manifests
# (roulette/dice), so §3 must not assert them in the seeded repo or it false-FAILs
# a correct lite deploy (ISI-7657 R1). Pull the authoritative drop list from
# lite-filter.sh (single source of truth) rather than hard-coding filenames.
CASINO_PROFILE="${CASINO_PROFILE:-full}"
LITE_FILTER="$(cd "$SCRIPT_DIR/.." && pwd)/deploy/casino/lite-filter.sh"
LITE_DROPPED=""
if [[ "$CASINO_PROFILE" == "lite" && -x "$LITE_FILTER" ]]; then
  LITE_DROPPED="$("$LITE_FILTER" --list-dropped 2>/dev/null || true)"
fi
STAMP="${STAMP:-manual}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$SCRIPT_DIR/evidence}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE="$EVIDENCE_DIR/verify-gitops-${STAMP}.txt"

PASS=0; FAIL=0
pass() { echo "[PASS] $*" | tee -a "$EVIDENCE"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" | tee -a "$EVIDENCE"; FAIL=$((FAIL+1)); }
info() { echo "       $*" | tee -a "$EVIDENCE"; }
hdr()  { echo | tee -a "$EVIDENCE"; echo "=== $* ===" | tee -a "$EVIDENCE"; }

echo "GitOps path verification — ISI-6796" > "$EVIDENCE"
info "argocd namespace : $ARGOCD_NS"
info "application      : $APP"
info "casino namespace : $CASINO_NS"
info "gitea URL        : $GITEA_URL"
info "evidence file    : $EVIDENCE"

# Wait for the Application to reach sync=Synced AND health=Healthy (or timeout).
wait_app_healthy() {
  local timeout="${1:-180}" i sync health
  for ((i=0; i<timeout; i+=5)); do
    sync=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null)
    health=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null)
    [[ "$sync" == "Synced" && "$health" == "Healthy" ]] && return 0
    sleep 5
  done
  return 1
}

# Force Argo CD to re-read git now instead of waiting for the ~3-min poll.
refresh_app() {
  kubectl -n "$ARGOCD_NS" annotate application "$APP" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

# --- 0. Prerequisites -------------------------------------------------------
hdr "0. Prerequisites"
command -v kubectl >/dev/null 2>&1 && pass "kubectl on PATH" || fail "kubectl missing"
command -v git >/dev/null 2>&1 && pass "git on PATH" || fail "git missing"
if kubectl cluster-info >/dev/null 2>&1; then
  pass "cluster reachable ($(kubectl config current-context 2>/dev/null))"
else
  fail "no reachable cluster — stand up the codespace/kind cluster first"
  echo; echo "Precondition not met. Aborting." | tee -a "$EVIDENCE"; exit 2
fi
if ! kubectl -n "$ARGOCD_NS" get application "$APP" >/dev/null 2>&1; then
  fail "Argo CD application '$APP' not found — run gitops/bootstrap/bootstrap-gitops.sh first"
  echo; echo "Precondition not met. Aborting." | tee -a "$EVIDENCE"; exit 2
fi
kubectl -n "$GITEA_NS" get deploy gitea >/dev/null 2>&1 \
  && pass "gitea deployment present" || fail "gitea deployment missing"

# --- 0.5 Argo CD UI reachable on NodePort 30002 (ISI-7551) ------------------
# The "Argo CD UI does not load" failure (ISI-7545/7551) is NOT covered by the
# sync/health checks below: the application-controller can sync the casino while
# argocd-server is still serving HTTPS on a mis-patched Service, so the UI 404s/
# TLS-errors at http://localhost:30002. Assert the three things install-argocd.sh
# sets, so a half-exposed UI fails the M0 banner loudly instead of silently
# regressing.
hdr "0.5 Argo CD UI exposed on NodePort 30002 (insecure http)"
ARGO_UI_NODEPORT="${ARGO_UI_NODEPORT:-30002}"
svc_type=$(kubectl -n "$ARGOCD_NS" get svc argocd-server -o jsonpath='{.spec.type}' 2>/dev/null)
[[ "$svc_type" == "NodePort" ]] \
  && pass "argocd-server Service type is NodePort" \
  || fail "argocd-server Service type is '${svc_type:-none}' (expected NodePort)"
# The http port must map 80 -> targetPort 8080 on nodePort 30002, and there must
# be no stray https port left squatting on another forwarded NodePort (30000).
ui_np=$(kubectl -n "$ARGOCD_NS" get svc argocd-server \
  -o jsonpath="{.spec.ports[?(@.nodePort==$ARGO_UI_NODEPORT)].targetPort}" 2>/dev/null)
[[ "$ui_np" == "8080" ]] \
  && pass "argocd-server exposes http on NodePort $ARGO_UI_NODEPORT -> targetPort 8080" \
  || fail "no http NodePort $ARGO_UI_NODEPORT -> 8080 on argocd-server (got targetPort '${ui_np:-none}')"
stray_https=$(kubectl -n "$ARGOCD_NS" get svc argocd-server \
  -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null)
[[ -z "$stray_https" ]] \
  && pass "no stray https NodePort on argocd-server (http-only, ISI-7533 band kept clean)" \
  || fail "argocd-server still exposes an https NodePort ($stray_https) — collides with the casino band"
insecure=$(kubectl -n "$ARGOCD_NS" get cm argocd-cmd-params-cm \
  -o jsonpath='{.data.server\.insecure}' 2>/dev/null)
[[ "$insecure" == "true" ]] \
  && pass "argocd-cmd-params-cm server.insecure=true (UI serves plain http)" \
  || fail "server.insecure is '${insecure:-unset}' (expected true) — http://localhost:$ARGO_UI_NODEPORT will TLS-fail"
if kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=5s >/dev/null 2>&1; then
  pass "argocd-server Deployment is Ready (UI backend up)"
else
  fail "argocd-server not Ready — UI at :$ARGO_UI_NODEPORT will not load"
fi

# --- 1. AC: Application healthy + synced against the hosted repo ------------
hdr "1. Argo CD Application Synced + Healthy (AC #1)"
refresh_app
if wait_app_healthy 180; then
  pass "application '$APP' is Synced + Healthy"
else
  sync=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null)
  fail "application not Synced+Healthy (sync=${sync:-?} health=${health:-?})"
fi
REPO_URL=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)
SRC_PATH=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.spec.source.path}' 2>/dev/null)
info "source: $REPO_URL (path=$SRC_PATH)"
if echo "$REPO_URL" | grep -q "gitea-http.${GITEA_NS}.svc"; then
  pass "Application sources the in-cluster Gitea repo"
else
  fail "Application repoURL does not point at the Gitea git host"
fi

# --- 2. AC: a test commit triggers a sync that updates the workload ---------
hdr "2. Test commit -> sync -> live cluster updates (AC #2)"
MARKER="gitops-verify-${STAMP}-$$"
WORK="$(mktemp -d)"
PUSH_URL="http://${GITEA_USER}:${GITEA_PASS}@${GITEA_URL#http://}/${CASINO_ORG}/${CASINO_REPO}.git"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

if git clone -q "$PUSH_URL" "$WORK" 2>>"$EVIDENCE"; then
  pass "cloned the casino repo from Gitea"
else
  fail "could not clone the casino repo from Gitea at $GITEA_URL"
  echo; echo "Cannot run the commit->sync check without the repo." | tee -a "$EVIDENCE"
  hdr "Summary"; info "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# 2a. Add a throwaway ConfigMap via git -> expect it to appear on the cluster.
cat > "$WORK/k8s/zz-gitops-verify.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-verify
data:
  marker: "${MARKER}"
YAML
(
  cd "$WORK"
  git config user.email "verify@otel.training"; git config user.name "gitops-verify"
  git add k8s/zz-gitops-verify.yaml
  git commit -q -m "verify: add gitops-verify ConfigMap (${MARKER})"
  git push -q "$PUSH_URL" HEAD:main
) && pass "pushed a test commit (adds ConfigMap ${MARKER})" || fail "git push (add) failed"

refresh_app
synced_marker=""
for ((i=0; i<180; i+=5)); do
  synced_marker=$(kubectl -n "$CASINO_NS" get configmap gitops-verify \
    -o jsonpath='{.data.marker}' 2>/dev/null)
  [[ "$synced_marker" == "$MARKER" ]] && break
  sleep 5
done
if [[ "$synced_marker" == "$MARKER" ]]; then
  pass "commit synced to the cluster — ConfigMap gitops-verify has marker '$MARKER'"
else
  fail "commit did not reach the cluster within 180s (got '${synced_marker:-<none>}')"
fi

# 2b. Remove it via git -> expect Argo CD prune to delete it from the cluster.
(
  cd "$WORK"
  git rm -q k8s/zz-gitops-verify.yaml
  git commit -q -m "verify: remove gitops-verify ConfigMap (prune check)"
  git push -q "$PUSH_URL" HEAD:main
) && pass "pushed a second commit (removes the ConfigMap)" || fail "git push (remove) failed"

refresh_app
pruned=1
for ((i=0; i<180; i+=5)); do
  if ! kubectl -n "$CASINO_NS" get configmap gitops-verify >/dev/null 2>&1; then pruned=0; break; fi
  sleep 5
done
if [[ "$pruned" -eq 0 ]]; then
  pass "Argo CD pruned the ConfigMap after it left git (prune + selfHeal work)"
else
  fail "ConfigMap still present after removal commit — prune did not run"
  kubectl -n "$CASINO_NS" delete configmap gitops-verify --ignore-not-found >/dev/null 2>&1 || true
fi
wait_app_healthy 120 >/dev/null 2>&1 \
  && pass "application back to Synced + Healthy after the test" \
  || info "application not yet re-synced after cleanup — check the UI"

# --- 3. AC: manifests are the single source of truth (coord. w/ ISI-6794) ---
hdr "3. Manifests single source of truth (AC #3, coord. ISI-6794)"
if [[ -d "$EXPECTED_SRC" ]]; then
  pass "canonical manifests present at $EXPECTED_SRC (owned by ISI-6794)"
  # The repo's k8s/ should carry the same manifest filenames the seed pushed.
  missing=0
  for f in "$EXPECTED_SRC"/*.yaml; do
    [[ -e "$f" ]] || continue
    bn=$(basename "$f")
    # Skip manifests the lite profile intentionally drops from the seed, so a
    # correct lite seed does not false-FAIL (ISI-7657 R1). Empty in full mode.
    if [[ -n "$LITE_DROPPED" ]] && printf '%s\n' "$LITE_DROPPED" | grep -qxF "$bn"; then
      info "skipping $bn (dropped by CASINO_PROFILE=lite)"; continue
    fi
    if [[ -f "$WORK/k8s/$bn" ]]; then :; else missing=$((missing+1)); info "repo missing $bn"; fi
  done
  [[ "$missing" -eq 0 ]] \
    && pass "every canonical manifest is present in the synced repo (k8s/)$([[ -n "$LITE_DROPPED" ]] && echo ' [lite: roulette/dice excluded]')" \
    || fail "$missing canonical manifest(s) not found in the repo — reseed (seed-gitea.sh)"
  # Image placeholders must be RESOLVED in the seeded repo (ISI-7587). A literal
  # ${IMAGE_OWNER}/${IMAGE_TAG} reaching Argo CD is InvalidImageName and the pods
  # never pull — a failure the filename check above cannot see. seed-gitea.sh
  # renders via render-images.sh; this asserts that actually happened.
  if grep -rqE '\$\{IMAGE_OWNER\}|\$\{IMAGE_TAG\}' "$WORK/k8s"/*.yaml 2>/dev/null; then
    fail "unresolved image placeholder(s) in seeded manifests — seed-gitea.sh did not render (InvalidImageName risk)"
  else
    pass "seeded manifests carry concrete image refs (no \${IMAGE_OWNER}/\${IMAGE_TAG} placeholders)"
  fi
  # Per-attendee cluster name must be RESOLVED + consistent so an attendee can
  # filter their own data on a shared tenant with `k8s.cluster.name` ==
  # PARTICIPANT_ID (ISI-7654 / D1). Assert: no literal ${CLUSTER_NAME} survived,
  # the ConfigMap value matches the live cluster name, and every service's
  # OTEL_RESOURCE_ATTRIBUTES carries that same k8s.cluster.name.
  EXPECT_CLUSTER="${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}"
  if grep -rqE '\$\{CLUSTER_NAME\}' "$WORK/k8s"/*.yaml 2>/dev/null; then
    fail "unresolved \${CLUSTER_NAME} in seeded manifests — seed-gitea.sh did not render the cluster name (per-participant filtering broken)"
  else
    seeded_cm=$(grep -hoE 'K8S_CLUSTER_NAME: *"[^"]*"' "$WORK/k8s"/00-config.yaml 2>/dev/null | sed -E 's/.*"([^"]*)".*/\1/')
    if [[ "$seeded_cm" == "$EXPECT_CLUSTER" ]]; then
      pass "seeded ConfigMap K8S_CLUSTER_NAME = '$seeded_cm' (matches live cluster)"
    else
      fail "seeded ConfigMap K8S_CLUSTER_NAME='$seeded_cm' != expected cluster '$EXPECT_CLUSTER'"
    fi
    attr_misses=0
    for f in "$WORK/k8s"/[2-5]*.yaml; do
      [[ -e "$f" ]] || continue
      grep -q "k8s.cluster.name=${EXPECT_CLUSTER}\b" "$f" 2>/dev/null \
        || { attr_misses=$((attr_misses+1)); info "$(basename "$f") missing k8s.cluster.name=${EXPECT_CLUSTER} in OTEL_RESOURCE_ATTRIBUTES"; }
    done
    [[ "$attr_misses" -eq 0 ]] \
      && pass "every casino service emits k8s.cluster.name=${EXPECT_CLUSTER} (per-participant DQL scope works)" \
      || fail "$attr_misses service manifest(s) do not emit k8s.cluster.name=${EXPECT_CLUSTER}"
  fi
else
  info "canonical manifests dir $EXPECTED_SRC absent on this branch — skipping file match"
fi
# Casino workloads on the cluster must be Argo CD-tracked (not hand-applied).
JSONPATH="{range .items[*]}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{'\n'}{end}"
tracked=$(kubectl -n "$CASINO_NS" get deploy -o jsonpath="$JSONPATH" 2>/dev/null \
  | grep -c "^${APP}:") || tracked=0
if [[ "${tracked:-0}" -gt 0 ]]; then
  pass "$tracked casino deployment(s) are Argo CD-tracked (git is authoritative)"
else
  info "no tracking-id annotations found — ok if the casino app has no Deployments yet,"
  info "otherwise confirm Argo CD (not kubectl) applied them"
fi

# --- 4. opencode -> Gitea git loop (ISI-7711, optional) ---------------------
# Only runs when a Gitea token has been minted (~/.workshop-gitea.env present).
# Proves opencode can drive the git loop (token auth + branch + PR round-trip)
# without disturbing k8s/** or the running casino. Absent token = skipped (not a
# failure) so the ISI-6796 ACs above are unaffected on environments that have
# not opted into the opencode loop.
hdr "4. opencode -> Gitea git loop (AC: ISI-7711, optional)"
OPENCODE_VERIFY="$SCRIPT_DIR/opencode/verify-opencode-git.sh"
GITEA_ENV_FILE="${WORKSHOP_GITEA_ENV:-$HOME/.workshop-gitea.env}"
if [[ ! -f "$OPENCODE_VERIFY" ]]; then
  info "opencode verify script not present ($OPENCODE_VERIFY) — skipping"
elif [[ ! -f "$GITEA_ENV_FILE" ]]; then
  info "no Gitea token yet ($GITEA_ENV_FILE absent) — run 'make gitea-token' to enable the opencode loop; skipping"
else
  if bash "$OPENCODE_VERIFY" | tee -a "$EVIDENCE"; then
    pass "opencode -> Gitea git loop round-trips (token + branch + PR)"
  else
    fail "opencode -> Gitea git loop verification failed — see output above"
  fi
fi

# --- 5. Gitea CI host: Actions on, runner online, registry reachable (ISI-7639) ---
# WS-A "Done when": Gitea Actions is on, a runner shows online, and /v2/ responds
# through the WS-D alias. Additive — a GitOps path without the CI host (older
# bootstrap) still passes sections 0-4. (Section number is 5 here because main's
# verify.sh already uses section 4 for the opencode->Gitea loop, ISI-7711.)
hdr "5. Gitea CI host — Actions + runner + registry (ISI-7639, WS-A)"
RUNNER_DEPLOY="${RUNNER_DEPLOY:-gitea-act-runner}"
REGISTRY_ALIAS="${REGISTRY_ALIAS:-gitea.local:30001}"

# 5a. Actions enabled — assert the live Gitea config, not just the manifest.
actions_on=$(kubectl -n "$GITEA_NS" get configmap gitea-config \
  -o jsonpath='{.data.GITEA__actions__ENABLED}' 2>/dev/null)
if [[ "$actions_on" == "true" ]]; then
  pass "Gitea Actions enabled (GITEA__actions__ENABLED=true)"
else
  fail "Gitea Actions not enabled in gitea-config (got '${actions_on:-<none>}')"
fi

# 5b. Runner online — Deployment Available AND act_runner registered/heartbeating.
if kubectl -n "$GITEA_NS" get deploy "$RUNNER_DEPLOY" >/dev/null 2>&1; then
  avail=$(kubectl -n "$GITEA_NS" get deploy "$RUNNER_DEPLOY" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  if [[ "${avail:-0}" -ge 1 ]]; then
    pass "runner Deployment '$RUNNER_DEPLOY' is Available ($avail replica)"
  else
    fail "runner Deployment '$RUNNER_DEPLOY' has no available replica"
  fi
  RPOD=$(kubectl -n "$GITEA_NS" get pod -l app.kubernetes.io/name="$RUNNER_DEPLOY" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$RPOD" ]] && kubectl -n "$GITEA_NS" logs "$RPOD" -c runner 2>/dev/null \
       | grep -qiE 'runner.*registered|declare successfully|ping.*success|starting runner'; then
    pass "act_runner registered + online (log shows registration/heartbeat)"
  else
    fail "act_runner not confirmed online — check: kubectl -n $GITEA_NS logs deploy/$RUNNER_DEPLOY -c runner"
  fi
else
  fail "runner Deployment '$RUNNER_DEPLOY' missing — run gitops/install/register-gitea-runner.sh"
fi

# 5c. Container registry reachable via the WS-D alias. Try the alias host FIRST
# (gitea.local:30001) so this actually exercises the /etc/hosts alias resolution
# create-cluster.sh wires (gitea.local -> 127.0.0.1); fall back to the plain
# NodePort host if the alias is not on /etc/hosts. A 200/401 from /v2/ both prove
# the registry is up (401 = up but anonymous pull disabled; still "reachable").
ALIAS_URL="http://${REGISTRY_ALIAS}/v2/"
NODE_URL="http://${GITEA_URL#http://}"; NODE_URL="${NODE_URL%/}/v2/"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "${GITEA_USER}:${GITEA_PASS}" "$ALIAS_URL" 2>/dev/null)
if [[ "$code" == "200" || "$code" == "401" ]]; then
  pass "Gitea registry /v2/ reachable via the WS-D alias ($ALIAS_URL, HTTP $code)"
else
  info "alias host $REGISTRY_ALIAS not resolvable from here (HTTP ${code:-000}) — retrying via the NodePort"
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "${GITEA_USER}:${GITEA_PASS}" "$NODE_URL" 2>/dev/null)
  if [[ "$code" == "200" || "$code" == "401" ]]; then
    pass "Gitea registry /v2/ reachable via the NodePort ($NODE_URL, HTTP $code; alias maps to this endpoint)"
  else
    fail "Gitea registry /v2/ not reachable (HTTP ${code:-000} at $NODE_URL) — is [packages] enabled?"
  fi
fi

# --- Summary ----------------------------------------------------------------
hdr "Summary"
info "PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "[OK] All ISI-6796 acceptance checks passed." | tee -a "$EVIDENCE"; exit 0
else
  echo "[!!] $FAIL check(s) failed — see $EVIDENCE" | tee -a "$EVIDENCE"; exit 1
fi
