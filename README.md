# Beyond the Honeymoon — OTel in Practice

[![docs](https://github.com/henrikrexed/Otel-Training/actions/workflows/docs.yml/badge.svg)](https://github.com/henrikrexed/Otel-Training/actions/workflows/docs.yml)

A 3-hour, hands-on OpenTelemetry workshop built around the **Vegas Casino** demo app and
delivered at Dynatrace Perform. You instrument, break, and fix a distributed system —
learning SDK configuration, the OpenTelemetry Collector as a control point, sampling
strategy, and cost/cardinality control — every change verified live in Dynatrace.

## 📖 Read the workshop online

👉 **https://henrikrexed.github.io/Otel-Training/**

The full, self-paced attendee walkthrough lives on the published site. To serve it locally
from a Codespace or devcontainer:

    pip install -r requirements-docs.txt
    mkdocs serve   # then open http://localhost:8000

## What is this?

A realistic, intentionally-broken microservice casino where telemetry is missing,
mis-configured, high-cardinality, PII-leaking, or expensive. You fix it the way you would
in production: via the OTel SDK, the Collector pipeline, and a GitOps loop, confirming each
fix in Dynatrace.

## What's covered

- Configuring the OpenTelemetry SDK per-service by file (sampling, exporters, resource attrs)
- The OpenTelemetry Collector as the control point: k8sattributes, transforms, filtering
- Head and tail sampling: cost vs. fidelity trade-offs
- Taming high-cardinality metrics and stripping PII from logs
- Hunting planted defects (broken trace context, cardinality blowups, PII) and fixing them
- An advanced self-paced track: AI-agent instrumentation, business metrics, Weaver, cost,
  and a catalog of extra exercises (dashboards, SLOs, Davis alerts via dtctl)

## How to start

1. **Fork** this repo and **open a Codespace** (or the devcontainer locally).
2. Set the required secrets (see `.devcontainer/` — Dynatrace tenant + tokens, workshop room password).
3. Wait for bootstrap to finish (kind cluster, observability, Dynatrace, GitOps).
4. Verify the environment: `make verify`.
5. Open the workshop and start at **M0 — Environment Setup**:
   https://henrikrexed.github.io/Otel-Training/

## Workshop modules

| Module | What you do |
| --- | --- |
| [M0 — Environment Setup](https://henrikrexed.github.io/Otel-Training/setup/) | Bring up the cluster, obs stack, Dynatrace, GitOps loop |
| [M1 — Tour the broken casino](https://henrikrexed.github.io/Otel-Training/module-1/) | See the app and its missing/broken telemetry |
| [M2 — SDK configuration by file](https://henrikrexed.github.io/Otel-Training/module-2/) | Configure the OTel SDK per service |
| [M3 — The collector as control point](https://henrikrexed.github.io/Otel-Training/module-3/) | Shape telemetry in the Collector pipeline |
| [M4 — Sampling: cost/fidelity](https://henrikrexed.github.io/Otel-Training/module-4/) | Head vs. tail sampling strategy |
| [M5 — Operating at scale](https://henrikrexed.github.io/Otel-Training/module-5/) | Cardinality, PII, cost at scale |
| [Advanced self-paced track](https://henrikrexed.github.io/Otel-Training/advanced/getting-started/) | AI-agent instrumentation, business metrics, Weaver, cost + exercise catalog |
| [Troubleshooting](https://henrikrexed.github.io/Otel-Training/troubleshooting/) | Common environment and telemetry issues |

## Repository layout

    apps/           Vegas Casino demo services (vendored source) + loadgen
    deploy/         Dynatrace install/uninstall + casino k8s manifests
    docs/           Design docs: abstract, 3h training structure, planted-defect inventory
    docs-site/      MkDocs attendee site sources (published to GitHub Pages)
    gitops/         Argo CD / Gitea GitOps loop for the kind cluster
    labs/           Standalone lab assets
    observability/  OTel Operator + logs DaemonSet + gateway collector (Dynatrace OTLP export)
    scripts/        Bootstrap, verification, and CI helper scripts

## About the published site (GitHub Pages)

The attendee site is built with MkDocs (Material theme) and published to GitHub Pages by
`.github/workflows/docs.yml` on every push to `main` that touches `docs-site/`, `mkdocs.yml`,
or the docs tooling. The workflow runs `mkdocs build --strict` and verifies Mermaid diagrams
render in both light and dark palettes before deploying.

## Key docs

- [`docs/training-structure.md`](docs/training-structure.md) — full 3-hour structure: agenda, module-by-module labs, planted-defect inventory, logistics
- [`docs-site/troubleshooting.md`](docs-site/troubleshooting.md) — troubleshooting reference
