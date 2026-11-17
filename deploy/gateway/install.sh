#!/usr/bin/env bash
# install.sh — install the Gateway API exposure layer for the casino (ISI-6795).
#
# This stands up the CLUSTER INFRA only — the CRDs and the controller that the
# casino's Gateway/HTTPRoute (deploy/casino/k8s/70-gateway.yaml + 71-httproute.yaml,
# owned by Argo CD) need to attach to. It deliberately does NOT apply the Gateway,
# HTTPRoute, or GatewayParameters: those belong to the casino app so the
# edit -> commit -> sync lab mechanic covers routing + exposure too.
#
# What it installs:
#   1. Gateway API standard CRDs (v1.7.0)
#   2. kgateway CRDs + controller (v2.5.0) — provides GatewayClass `kgateway`
#      (CNCF, Envoy-based Gateway API implementation — ISI-7546, was NGINX
#      Gateway Fabric).
#
# How the casino lands on NodePort 30000: the casino's Gateway references a
# GatewayParameters (deploy/casino/k8s/72-gatewayparameters.yaml, Argo-owned, in
# the casino namespace) via spec.infrastructure.parametersRef. That object pins
# the proxy Service kgateway provisions to service.type=NodePort, nodePort 30000.
# kind maps node 30000 -> host 30000 and the devcontainer forwards it. No
# cluster-infra NodePort override is needed here anymore (unlike NGF): the
# per-Gateway override lives with the app, so attendees edit it in the lab.
#
# Idempotent: safe to re-run (postStart-style healing). Requires kubectl + helm
# + an up kind cluster (devcontainer base, ISI-6791). Runs BEFORE the casino
# phase so the CRDs + GatewayClass exist before Argo CD (or a direct apply)
# syncs the Gateway/HTTPRoute/GatewayParameters.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${HERE}/versions.env"

log()  { printf '\033[1;34m[gateway]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gateway] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[gateway] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found — run inside the devcontainer"
command -v helm    >/dev/null || die "helm not found — run inside the devcontainer (install-tools.sh installs it)"
kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster — is the kind cluster up (ISI-6791)?"

KGW_NS="${KGW_NS:-kgateway-system}"

# --- 1. Gateway API standard CRDs -------------------------------------------
# The HTTPRoute/Gateway/GatewayClass kinds. Applied with --server-side to avoid
# the last-applied-configuration annotation bloat on large CRDs. kgateway's own
# CRDs (GatewayParameters/...) come from the kgateway-crds Helm chart below.
if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
   && kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  log "Gateway API CRDs already present — re-asserting ${GATEWAY_API_VERSION}"
else
  log "installing Gateway API standard CRDs ${GATEWAY_API_VERSION}"
fi
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- 2. kgateway CRDs + controller ------------------------------------------
# kgateway ships as OCI Helm charts: a CRDs chart (GatewayParameters and the
# other gateway.kgateway.dev kinds) and the controller chart. `helm upgrade -i`
# is idempotent — re-running just re-asserts the pinned version.
log "installing kgateway CRDs ${KGATEWAY_VERSION}"
helm upgrade -i kgateway-crds \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --namespace "${KGW_NS}" --create-namespace \
  --version "${KGATEWAY_VERSION}" \
  --wait

log "installing kgateway controller ${KGATEWAY_VERSION} (GatewayClass 'kgateway')"
helm upgrade -i kgateway \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --namespace "${KGW_NS}" \
  --version "${KGATEWAY_VERSION}" \
  --set controller.image.pullPolicy=IfNotPresent \
  --wait

# --- 3. Health ---------------------------------------------------------------
log "waiting for the kgateway controller to become ready"
kubectl -n "${KGW_NS}" rollout status deploy/kgateway --timeout=300s

log "Gateway API layer installed. The casino's Gateway + GatewayParameters"
log "(deploy/casino/k8s) will provision the kgateway data plane in the casino"
log "namespace on NodePort ${CASINO_HTTP_NODEPORT}."
cat <<EOF
  kubectl get gatewayclass kgateway
  kubectl -n casino get gateway,httproute,gatewayparameters
  kubectl -n casino get svc -o wide | grep ${CASINO_HTTP_NODEPORT}
  # then open the forwarded :${CASINO_HTTP_NODEPORT} URL (see deploy/gateway/README.md)
EOF
