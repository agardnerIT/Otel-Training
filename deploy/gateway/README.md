# Gateway API — exposing the casino out of the devcontainer (ISI-6795)

This component makes the Vegas Casino reachable from a **browser outside the
devcontainer**, so each attendee can play the app and drive load against their
own cluster.

It uses the **Gateway API** (not legacy Ingress): a `Gateway` + `HTTPRoute`
implemented by **kgateway** (CNCF, Envoy-based — ISI-7546).

```
browser ──▶ forwarded :30000 ──▶ kind node :30000 (NodePort)
            (Codespaces/VS Code)        │
                                        ▼
                     kgateway data plane (Envoy)  ──HTTPRoute──▶  vegas-casino-frontend:3000
                     Gateway "casino" :80 listener
```

## Pieces

| Where | What | Owner |
|-------|------|-------|
| `deploy/gateway/install.sh` | Gateway API CRDs + kgateway CRDs + controller (GatewayClass `kgateway`) | bootstrap (cluster infra) |
| `deploy/casino/k8s/70-gateway.yaml` | the `casino` Gateway (`:80` HTTP listener), references the GatewayParameters | **Argo CD** (casino app) |
| `deploy/casino/k8s/71-httproute.yaml` | routes `/` → `vegas-casino-frontend:3000` | **Argo CD** (casino app) |
| `deploy/casino/k8s/72-gatewayparameters.yaml` | pins the kgateway proxy Service to NodePort 30000 | **Argo CD** (casino app) |

The Gateway, HTTPRoute, and GatewayParameters live with the rest of the casino
manifests so the **edit → commit → auto-sync** lab mechanic (ISI-6796) covers
routing *and* exposure. The CRDs they depend on are installed by `install.sh`,
which the environment orchestrator runs **before** the casino phase.

> **Why the GatewayParameters is an app manifest, not cluster infra.** kgateway
> provisions the Envoy proxy Deployment + Service in the Gateway's own namespace
> (`casino`). The Gateway's `spec.infrastructure.parametersRef` is namespace-local,
> so the `GatewayParameters` it points at must live in `casino` too. That's a
> cleaner split than NGF's cluster-default `NginxProxy` override: the NodePort
> config now sits next to the Gateway and syncs through Argo like everything else.

Pinned versions (`versions.env`): Gateway API `v1.7.0`, kgateway `v2.5.0`.

## Install

```bash
bash deploy/gateway/install.sh
```

Idempotent — safe to re-run (`helm upgrade -i`). It installs the standard
Gateway API CRDs, then the kgateway CRDs + controller (GatewayClass `kgateway`)
into the `kgateway-system` namespace. It does **not** apply any NodePort
override: that is the Argo-owned `72-gatewayparameters.yaml`, which switches the
proxy Service to **NodePort 30000** when the casino Gateway is synced.

> kgateway's default proxy Service type is `LoadBalancer`, which never gets an
> address on a bare kind cluster. The `GatewayParameters` NodePort override is
> what makes the casino reachable. NodePorts must be in `30000-32767`, so we use
> `30000` (port `80` is not a legal NodePort) — the same band `kind-config.yaml`
> publishes and `devcontainer.json` forwards.

## How the URL is surfaced out of the devcontainer

This is the whole point of the ticket. The chain is already wired end to end:

1. **Gateway listener `:80`** is pinned by the `GatewayParameters` to **NodePort
   30000** on the kind node.
2. **`kind-config.yaml`** maps the node's `containerPort: 30000` → **host 30000**
   (`extraPortMappings`).
3. **`devcontainer.json`** lists `30000` in `forwardPorts`, so VS Code / GitHub
   Codespaces automatically forwards it and shows it in the **Ports** panel.

So an attendee opens the casino by:

- **GitHub Codespaces** → **Ports** tab → click the globe on port **30000**
  (a `https://<name>-30000.app.github.dev` URL), or
- **VS Code Dev Containers / local** → open **http://localhost:30000**.

No host header is pinned on the Gateway/HTTPRoute, so the generated
`*.app.github.dev` forwarding host works unchanged.

### Fallback (no Gateway, e.g. debugging)

```bash
kubectl -n casino port-forward svc/vegas-casino-frontend 3000:3000
# then open http://localhost:3000
```

## Verify

```bash
bash deploy/gateway/verify.sh
```

- **Offline** (no cluster): structurally validates the three manifests
  (Gateway, HTTPRoute, GatewayParameters).
- **Live** (inside the codespace): checks CRDs, controller readiness,
  GatewayClass/Gateway/HTTPRoute status, the GatewayParameters NodePort, the
  NodePort Service, and that the casino UI actually answers through the Gateway
  (in-cluster and via `http://localhost:30000`).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `:30000` not answering | Gateway not synced yet | `kubectl -n casino get gateway,httproute,gatewayparameters`; sync the casino Argo app |
| Gateway stuck `Programmed=False` | CRDs/controller missing | re-run `deploy/gateway/install.sh` |
| HTTPRoute `ResolvedRefs=False` | frontend Service absent | ensure the casino app is deployed (`kubectl -n casino get svc vegas-casino-frontend`) |
| NodePort Service missing in `casino` | kgateway hasn't provisioned the data plane | confirm the `casino` Gateway exists and `GatewayClass kgateway` is `Accepted` |
| NodePort Service exists but on a random port | GatewayParameters not applied/linked | confirm `72-gatewayparameters.yaml` synced and the Gateway's `parametersRef` names `casino-nodeport` |
