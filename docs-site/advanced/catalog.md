# Catalog — extra exercises (choose your path)

Optional appendix to the one guide: beyond the linear module arc **M0–M10**,
the **catalog** holds self-contained exercises — grouped by theme — that a
facilitator can drop in for depth or variety, cross-linked from the modules
above. Each follows the same teaching shape as the main arc: **① Problem →
② Understand the change → ③ opencode prompt ladder → ④ Review & apply →
⑤ Verify (DQL)**, with a planted `labs/advanced/…` reference answer.

Themes: **A** = traces/instrumentation · **B** = metrics/collector ·
**C** = Dynatrace automation · **D** = observability-of-observability (capstone).
Pick by the time you have and the muscle you want
to build:

| Exercise | Theme | Time | Difficulty | opencode skill | You will… |
|---|---|---|---|---|---|
| [A1 — Fix a broken distributed trace](catalog-a1-broken-trace.md) | traces | **25m** | **med** | `otel-instrumentation` | Restore context propagation across a dropped async hop so the slots → scoring trace reconnects end-to-end. |
| [A2 — Log ↔ trace correlation](catalog-a2-log-trace-correlation.md) | traces / logs | **20m** | **med** | `otel-instrumentation` | Inject `trace_id` / `span_id` into slots logs so Dynatrace links each log line to its span — and pivots between them. |
| [A3 — Multi-language instrumentation](catalog-a3-multi-language.md) | traces | **25m** | **med** | `otel-instrumentation` | Port the Step-1 span pattern to a 2nd SDK (Python roulette), proving the `casino.*` contract crosses languages. |
| [A4 — Exceptions / span-events](catalog-a4-exceptions-span-events.md) | traces | **20m** | **med** | `otel-instrumentation` | Record exceptions as span events (`exception.type` / `.message` / `.stacktrace`) + ERROR status instead of swallowing them — a failing money-path stops looking green. |
| [A5 — Baggage propagation (`player.tier`)](catalog-a5-baggage-propagation.md) | traces | **25m** | **med** | `otel-instrumentation` | Set `player.tier` into baggage upstream in slots and read it downstream in scoring, so one DQL slices by a tier scoring never looked up. |
| [B1 — RED metrics from spans](catalog-b1-spanmetrics.md) | metrics / collector | **20m** | **med** | `otel-collector` | Add the `spanmetrics` connector to the gateway and chart Rate / Errors / Duration — no app-code change. |
| [B2 — Cost-center tagging](catalog-b2-cost-center.md) | metrics / collector | **20m** | **med** | `otel-collector` + `otel-ottl` | Derive `dt.cost.costcenter` from each signal's own namespace / service with a `transform` processor — attribute **all** ingest (traces, metrics, logs) to the right team. Pairs with **C4**. |
| [B3 — Drop noise (filter processor)](catalog-b3-filter-drop-noise.md) | metrics / collector | **15m** | **easy** | `otel-collector` | Drop health-check / `/metrics` spans at the gateway — verify the ingest drop with no signal loss. |
| [B4 — OTTL enrichment (`casino.bet.tier`)](catalog-b4-ottl-enrichment.md) | metrics / collector | **20m** | **med** | `otel-collector` + `otel-ottl` | Derive a bounded bet-tier bucket from the raw bet amount with a `transform` processor — bucket a high-cardinality number so you can slice by it. |
| [B5 — Structure unstructured logs (OTTL)](catalog-b5-ottl-log-structuring.md) | metrics / collector | **25m** | **med** | `otel-collector` + `otel-ottl` | Parse opaque casino log lines into typed `casino.*` attributes + severity with OTTL `ExtractPatterns` — make text queryable. |
| [B6 — Metric temporality (`cumulative_to_delta`)](catalog-b6-cumulativetodelta.md) | metrics / collector | **20m** | **med** | `otel-collector` | Make the gateway's `cumulative_to_delta` explicit + targeted; learn cumulative vs delta and why Dynatrace prefers delta for rate / SLO math. |
| [B7 — Collector pipeline health](catalog-b7-collector-health.md) | metrics / collector | **25m** | **med** | `otel-collector` + `dtctl` | Make the gateway observe itself — ship `otelcol_*` metrics, internal logs, and loopback-tail-sampled internal traces to Dynatrace, then build a pipeline-health dashboard as code. Builds on **M9** + **C1**. |
| [C1 — Build a dashboard via dtctl](catalog-c1-dtctl-dashboard.md) | Dynatrace automation | **20m** | **med** | `dtctl` | Turn your Step-2 business metrics into a live, version-controlled Dynatrace dashboard — as code. |
| [C2 — Define a reliability SLO via dtctl](catalog-c2-slo.md) | Dynatrace automation | **20m** | **med** | `dtctl` | Turn a money-path metric into a commitment: a platform SLO with a 99% target, an error budget, and a burn rate — as code. |
| [C3 — Metric event / Davis alert via dtctl](catalog-c3-metric-davis-alert.md) | Dynatrace automation | **20m** | **med** | `dtctl` | Put a Davis alert on the money-path error rate, then prove it fires by breaking a dependency in a controlled scenario. |
| [C4 — Dynatrace cost centers](catalog-c4-dynatrace-cost-center.md) | Dynatrace automation | **20m** | **med** | `dtctl` + `dt-app-dashboards` | Allocate ingest back to the team / game — showback & chargeback DQL over the `dt.cost.costcenter` tag from **B2**, plus an optional cost dashboard. |
| [D1 — Instrumentation Score (capstone)](catalog-d1-instrumentation-score.md) | obs-of-obs | **40m** | **hard** | `dtctl` + DQL | Grade the casino's telemetry as one weighted **instrumentation score** (4 anchor rules, per service) deployed as code — the **runtime guard** that complements M4's build-time Weaver guard. Read the [concept](instrumentation-score-concept.md) first. |

!!! tip "Prerequisites"
    All assume the base environment is up and
    [M0](../setup.md) / the [M1 orientation](../module-1.md) have wired
    `opencode` and its skills
    (`opencode debug skill` lists `otel-*` and `dtctl`). **A2**, **A3**, **A4**
    and **A5** build on the span pattern from
    [M2](../module-2.md) (**A5** also spans the slots →
    scoring hop from [A1](catalog-a1-broken-trace.md)); **C1**, **C2** and **C3**
    build on the metrics from [M3](step-2-business-metrics.md) and the RED
    metrics from [B1](catalog-b1-spanmetrics.md) (**C2** → **C3** form a
    reliability pair: the SLO budget, then the Davis alert that pages on a spike).
    **B2 → C4** are a **pair** — B2 stamps the `dt.cost.costcenter` tag at the
    gateway, C4 allocates/reports on it in Dynatrace; do **B2 first**. Both build
    on the cost-allocation intro in [M8](step-4-cost-of-observability.md).
    **B7** builds on both [M9](../module-4.md) (the loopback
    internal-traces pipeline reuses the tail-sampling pattern and the
    `replicas: 1` constraint) and [C1](catalog-c1-dtctl-dashboard.md) (the
    `dtctl` dashboard-as-code flow).
    **D1** is the **capstone** — it reuses `service.name`
    ([M2](../module-2.md)), span status
    ([A4](catalog-a4-exceptions-span-events.md)), log↔trace
    ([A2](catalog-a2-log-trace-correlation.md)) and a bounded dimension
    ([B4](catalog-b4-ottl-enrichment.md)) into one score, so do those first for a
    score that lands **Good → Excellent**.
    Extra trace-hunting fuel: [M0 §5 — In-game cheats](../setup.md#in-game-cheats)
    plant `game.cheat_*` span attributes you can hunt in the **A-series**.

## Theme D — the capstone (observability of observability)

Themes A–C each sharpen one muscle; **theme D closes the loop** by grading the
telemetry itself. [D1 — Instrumentation Score](catalog-d1-instrumentation-score.md)
is the workshop's **capstone**: it synthesises the instrumentation work from
theme A and the "as-code" automation reflexes from theme C into a single,
deployed-as-code **scorecard** for the casino's telemetry.

- **Builds on theme A (the signals being graded):** `service.name` from
  [M2](../module-2.md), ERROR span status from
  [A4](catalog-a4-exceptions-span-events.md), log↔trace correlation from
  [A2](catalog-a2-log-trace-correlation.md), and a bounded dimension from
  [B4](catalog-b4-ottl-enrichment.md) — the four anchor rules each land because
  of work you did earlier.
- **Extends theme C (the "as-code" reflex):** where
  [C1](catalog-c1-dtctl-dashboard.md) ships a dashboard,
  [C2](catalog-c2-slo.md) an SLO and [C3](catalog-c3-metric-davis-alert.md) a
  Davis alert — all via `dtctl` — D1 ships the **instrumentation score** the
  same way, as a version-controlled Dynatrace artifact.
- **Complements M4:** [Weaver](step-3-weaver-pipeline.md) is the
  **build-time** guard that blocks drift before merge; D1 is the **runtime**
  guard that scores what the apps actually emit. Read the
  [concept](instrumentation-score-concept.md) first.
