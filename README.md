# Beyond the Honeymoon — OTel in Practice

[![docs](https://github.com/henrikrexed/Otel-Training/actions/workflows/docs.yml/badge.svg)](https://github.com/henrikrexed/Otel-Training/actions/workflows/docs.yml)

One complete, hands-on OpenTelemetry guide built around the **Vegas Casino** demo app —
a continuous **M0–M10** module arc split by two 15-minute breaks — delivered at Dynatrace
Perform. You instrument, break, and fix a distributed system — learning SDK configuration,
the OpenTelemetry Collector as a control point, sampling strategy, and cost/cardinality
control — every change verified live in Dynatrace.

## 📖 Read the guide online

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
- AI-agent instrumentation: the `opencode` agent produces the fixes, you review and verify
- Business metrics on the money path (counters, histograms, live dashboard tiles)
- Semantic conventions enforced with Weaver (versioned registry, CI gates)
- The OpenTelemetry Collector as the control point: k8sattributes, transforms, filtering
- Head and tail sampling: cost vs. fidelity trade-offs
- Taming high-cardinality metrics and stripping PII from logs
- The cost of observability
- Hunting planted defects (broken trace context, cardinality blowups, PII) and fixing them
- Optional *Extra exercises* catalog as part of the one guide: dashboards, SLOs, and Davis
  alerts via dtctl

## How to start

1. **Fork** this repo and **open a Codespace** (or the devcontainer locally).
2. Set the required secrets (see `.devcontainer/` — Dynatrace tenant + tokens, workshop room password).
3. Wait for bootstrap to finish (kind cluster, observability, Dynatrace, GitOps).
4. Verify the environment: `make verify`.
5. Open the guide and start at **M0 — Environment Setup**:
   https://henrikrexed.github.io/Otel-Training/

## Guide modules

One arc, M0–M10, with two 15-minute breaks. URLs are derived from the docs file path
(see the `mkdocs.yml` nav on `main`), not from the nav M-number:

| Module | URL |
| --- | --- |
| [M0 — Environment setup](https://henrikrexed.github.io/Otel-Training/setup/) | `/Otel-Training/setup/` |
| [M1 — Tour the broken casino](https://henrikrexed.github.io/Otel-Training/module-1/) | `/Otel-Training/module-1/` |
| [M2 — Instrument the casino](https://henrikrexed.github.io/Otel-Training/module-2/) | `/Otel-Training/module-2/` |
| [M3 — Business metrics](https://henrikrexed.github.io/Otel-Training/advanced/step-2-business-metrics/) | `/Otel-Training/advanced/step-2-business-metrics/` |
| ☕ Break (15 min) | — |
| [M4 — Semantic conventions with Weaver](https://henrikrexed.github.io/Otel-Training/advanced/step-3-weaver-pipeline/) | `/Otel-Training/advanced/step-3-weaver-pipeline/` |
| [M5 — The collector as control point](https://henrikrexed.github.io/Otel-Training/module-3/) | `/Otel-Training/module-3/` |
| [M6 — Taming high-cardinality metrics](https://henrikrexed.github.io/Otel-Training/advanced/step-5-high-cardinality/) | `/Otel-Training/advanced/step-5-high-cardinality/` |
| [M7 — Scrubbing PII from logs](https://henrikrexed.github.io/Otel-Training/advanced/step-6-pii-logs/) | `/Otel-Training/advanced/step-6-pii-logs/` |
| ☕ Break (15 min) | — |
| [M8 — The cost of observability](https://henrikrexed.github.io/Otel-Training/advanced/step-4-cost-of-observability/) | `/Otel-Training/advanced/step-4-cost-of-observability/` |
| [M9 — Sampling strategy](https://henrikrexed.github.io/Otel-Training/module-4/) | `/Otel-Training/module-4/` |
| [M10 — Operating at scale](https://henrikrexed.github.io/Otel-Training/module-5/) | `/Otel-Training/module-5/` |
| [Extra exercises & appendices (optional)](https://henrikrexed.github.io/Otel-Training/advanced/catalog/) | `/Otel-Training/advanced/catalog/` |
| [Troubleshooting](https://henrikrexed.github.io/Otel-Training/troubleshooting/) | `/Otel-Training/troubleshooting/` |

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
