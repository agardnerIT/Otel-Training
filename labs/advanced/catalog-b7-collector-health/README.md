# Catalog B7 — Collector pipeline health

**Theme B (metrics / collector) · [25m][med] · Skills: `otel-collector` + `dtctl`**

Reference assets for the catalog exercise
[B7 — Collector pipeline health](../../docs-site/advanced/catalog-b7-collector-health.md).
The attendee drives `opencode` (the `otel-collector` skill, then the `dtctl`
skill) to make the OTel **gateway observe itself** — ship its `otelcol_*`
metrics, its own logs, and its loopback-tail-sampled internal traces to
Dynatrace — then build a health dashboard as code.

Builds on [Step 7 — Tail sampling](../../docs-site/advanced/step-7-tail-sampling.md)
(the loopback internal-traces pipeline reuses the same tail-sampling pattern and
the same `replicas: 1` single-instance constraint) and
[Catalog C1](../catalog-c1-dtctl-dashboard/README.md) (the `dtctl` dashboard-as-code flow).

| File | Role |
|---|---|
| `telemetry-selfobs.yaml` | Reference answer for P2–P4 — the `service::telemetry` block (self-metrics + self-logs + self-traces), the `otlp/internal` loopback receiver, the `tail_sampling/internal` processor, and the dedicated `traces/internal` pipeline. A drop-in overlay for `observability/collectors/gateway.yaml`. |
| `collector-health-dashboard.json` | The dashboard document — 24-column grid, tiles over `otelcol_*` (throughput accepted vs refused, processor drops, exporter send-failures + queue depth, process memory/CPU), plus the collector ERROR-log count and the retained error-span count. |
| `dtctl-apply.sh` | Validate (`dtctl apply -f … --dry-run`) then deploy (`dtctl apply -f …`) — the manual equivalent of what opencode generates. |
| `verify.sh` | Offline structural check of the overlay (all three signals exported, loopback receiver present, internal pipeline order + tail-sampling policies correct). No cluster or live tenant needed. |

## Why self-telemetry

A collector that silently drops spans is worse than no collector: you trust a
signal that is quietly incomplete. The gateway already produces its own
telemetry — `otelcol_*` metrics, internal logs, internal traces — but by default
the training gateway only sets `telemetry.logs.level: info` and ships **none** of
it. This exercise wires all three signals out to Dynatrace so the pipeline
watches itself: exporter send-failures, queue saturation, receiver refusals, and
processor drops become first-class, alertable signals.

## Why loopback tail sampling for self-traces

The collector's own internal traces are high-volume and mostly boring. Rather
than ship 100% (or drop them blindly head-style), the self-traces are exported
by **loopback** to a second OTLP receiver (`otlp/internal`, :4319) on the **same**
collector, feeding a dedicated `traces/internal` pipeline whose `tail_sampling`
processor keeps **every ERROR** (export failures, queue overflows surface here)
and samples the boring rest to **5%** — the same tail-sampling discipline as
Step 7, scoped to the collector itself.

> **Single-instance requirement** (same as Step 7): tail sampling must see all
> spans of a trace on one instance. The gateway runs `replicas: 1`, so this
> holds. If you scale it out, front the loopback with a `loadbalancing` exporter
> tier keyed on traceID.

## Deploy

```bash
# opencode drives the dtctl skill in the exercise; this is the manual apply:
bash labs/advanced/catalog-b7-collector-health/dtctl-apply.sh
```

`dtctl` authenticates with the platform token already in the codespace
environment (ISI-7175) — no extra secret. The dashboard is named after your
`PARTICIPANT_ID` so every attendee gets their own.

## Live validation (follow-up)

The offline `verify.sh` proves the overlay is structurally correct. Confirming
the `otelcol_*` metrics actually land and the dashboard renders requires an up
Dynatrace tenant — historically gated on the live environment, so it is a
follow-up check rather than a merge blocker. DT may normalize `otelcol_*` metric
and field names on ingest; confirm the final names live and adjust the dashboard
DQL if needed.
