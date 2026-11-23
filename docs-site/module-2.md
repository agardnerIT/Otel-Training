# M2 — SDK configuration by file: declarative config

**Goal:** take the Java Scoring Service from code-first SDK configuration to a
declarative `otel-config.yaml`, injected with zero code changes. 30 minutes.

## Concepts (5 min)

There are three ways to configure an SDK, in increasing order of scale:

1. **Env vars** — `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_PROPAGATORS`, … Fine
   for a handful of settings; becomes env-var soup at fleet scale.
2. **Code** — an `OpenTelemetryConfig` class building the SDK by hand. Maximum
   control, but every configuration change is a rebuild and redeploy of the
   application.
3. **Declarative file** — one `otel-config.yaml`, version-controlled,
   reviewed, and mounted into the workload. The
   [schema](https://opentelemetry.io/docs/languages/sdk-configuration/declarative-configuration/)
   is shared across languages; today the **Java zero-code agent** implements
   it via `OTEL_CONFIG_FILE`.

!!! warning "The one rule everyone gets bitten by"
    When the SDK reads a config **file**, environment variables are **ignored
    unless the file references them** with `${ENV_VAR}`. This is the single
    most common "why is my config ignored?" question in the lab.

## The problem: config welded into code

The Scoring Service (Java, Spring Boot) configures OTel **in code** —
`services/scoring/.../config/OpenTelemetryConfig.java` builds its own tracer
provider with a hard-coded OTLP exporter. Consequences you can observe right
now in Dynatrace:

- **Traces** from `vegas-scoring-service` flow (the code exports them).
- **No JVM metrics** — the code never wires a meter provider.
- **No logs** — the code never wires a logger provider. Java logs go to
   stdout, unstructured, invisible to OTLP.

Want to change the sampler? Rebuild the jar. Want logs? Write Java. This is
the anti-pattern the declarative file replaces.

## The lab: zero-code instrumentation via the operator

Your cluster runs the OpenTelemetry Operator (namespace `observability`). It
can inject the Java agent into any workload — no Dockerfile change, no code.

You make this change the same way as M1: drive **opencode**, review its diff,
and ship it as a **Gitea PR** that Argo CD syncs. If you have not cloned the
casino repo for opencode yet, run the [one-time setup from M1](module-1.md#the-fix-drive-it-with-opencode-ship-it-through-gitea)
(`gitea-token.sh` → `clone-casino.sh` → `cd ~/casino && opencode`) first.

### ② Opencode — create the config and wire the deployment

Drive the agent with one prompt that names the **goal**, the two **target files**,
and the **skill**:

```bash
opencode run "Using the otel-instrumentation skill: give the Java \
vegas-scoring-service declarative, zero-code OTel via the operator. (1) Create \
k8s/21-scoring-otel.yaml holding a ConfigMap 'scoring-otel-config' whose \
otel-config.yaml (file_format 1.1) wires resource identity + host/process/ \
container detectors, tracecontext+baggage propagators, and tracer/meter/logger \
providers all exporting OTLP to \
http://otel-gateway-collector.observability.svc.cluster.local:4317 (tls \
insecure), plus an Instrumentation CR 'casino-java' setting OTEL_CONFIG_FILE=/ \
etc/otel/otel-config.yaml. (2) Edit k8s/20-scoring.yaml: add the pod annotation \
instrumentation.opentelemetry.io/inject-java: casino-java, the OTEL_CONFIG_FILE \
env var, and mount the ConfigMap at /etc/otel. Keep the existing container spec \
otherwise unchanged."
```

### ③ Review — read the diff

Read both files opencode writes before you ship them. The new
**`k8s/21-scoring-otel.yaml`** should converge on:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: scoring-otel-config
data:
  otel-config.yaml: |
    file_format: "1.1"

    resource:
      attributes:
        - name: service.name
          value: vegas-scoring-service
        - name: service.namespace
          value: vegas-casino
      detectors:            # fill in host/process/container identity
        - host:
        - process:
        - container:

    propagator:
      composite:
        - tracecontext:
        - baggage:

    tracer_provider:
      sampler:
        parent_based:
          root:
            always_on: {}          # M4 revisits this
      processors:
        - batch:
            exporter:
              otlp:
                endpoint: http://otel-gateway-collector.observability.svc.cluster.local:4317
                tls:
                  insecure: true

    meter_provider:
      readers:
        - periodic:
            exporter:
              otlp:
                endpoint: http://otel-gateway-collector.observability.svc.cluster.local:4317
                tls:
                  insecure: true

    logger_provider:
      processors:
        - batch:
            exporter:
              otlp:
                endpoint: http://otel-gateway-collector.observability.svc.cluster.local:4317
                tls:
                  insecure: true
---
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: casino-java
spec:
  java:
    env:
      - name: OTEL_CONFIG_FILE
        value: /etc/otel/otel-config.yaml
```

!!! note "SDK `batch` ≠ Collector `batch`"
    The `batch` span/log processors in this file are part of the **SDK** and are not
    deprecated. It is the *Collector's* `batch` processor that is deprecated — you will
    see its replacement (exporter-level `sending_queue.batch`) in Module 3.

Every block maps to a concept from M1: resource identity, propagation,
per-signal pipelines (tracer / meter / logger providers), each with its own
batch processor and OTLP exporter.

Note what the file does **not** contain: any of the `OTEL_*` env vars from the
deployment. If we needed one, it would have to appear as `${VAR}` inside the
file to be honored at all.

And the three edits opencode makes to **`k8s/20-scoring.yaml`**:

1. Add the injection annotation to the **pod template** metadata (the
   `template.metadata.annotations` block — create it if missing):

    ```yaml
    instrumentation.opentelemetry.io/inject-java: "casino-java"
    ```

2. Add the env var pointing at the mounted file, in the container env block:

    ```yaml
    - name: OTEL_CONFIG_FILE
      value: /etc/otel/otel-config.yaml
    ```

3. Mount the ConfigMap — add to the container `volumeMounts` and the pod
   `volumes`:

    ```yaml
    # container:
    volumeMounts:
      - name: scoring-otel-config
        mountPath: /etc/otel
        readOnly: true
    # pod spec:
    volumes:
      - name: scoring-otel-config
        configMap:
          name: scoring-otel-config
    ```

!!! warning "If the agent gets it wrong — steer it back, don't hand-fix"
    Common misses and the one-line correction to reply with:

    - **`meter_provider` or `logger_provider` dropped** (only traces wired):
      *"the file must wire all three — tracer_provider, meter_provider, and
      logger_provider — each exporting OTLP to the gateway, or JVM metrics and
      logs will still be missing."*
    - **ConfigMap not mounted** / annotation on the wrong metadata block: *"the
      inject-java annotation goes on the pod template metadata, and the ConfigMap
      must mount at /etc/otel in the container."*
    - **Edited the wrong deployment**: *"the only deployment to touch is
      k8s/20-scoring.yaml (vegas-casino-scoring)."*

    Re-run opencode with the correction — the verify checkpoint tells you when
    it is done.

### ④ Apply — opencode → PR → merge → Argo CD sync

Ship both files through **Gitea** (the casino namespace is GitOps-owned). Let
opencode run the git loop, or do it by hand from inside `~/casino`:

```bash
gitea-pr.sh "feat(scoring): declarative zero-code OTel via operator"
```

**Review and merge the PR in the Gitea UI**
(`http://localhost:30001/casino/casino/pulls`). Argo CD syncs the merged `main`
(hit **Refresh** at `http://localhost:30002` to force it); watch the rollout:

```bash
kubectl -n casino rollout status deploy/vegas-casino-scoring
kubectl -n casino get pods -l app.kubernetes.io/name=vegas-casino -o name | grep scoring
```

!!! tip "Not rolling?"
     Argo CD only syncs files it can render. YAML-indentation errors in the
     ConfigMap (the `|` block) are the usual suspect — check the Argo CD app
     status at http://localhost:30002 before you debug anything else.

### Step 3 — verify in Dynatrace

Give it a minute, then with your cluster filter:

1. **Metrics** — search metric names for `jvm_` or open the scoring service's
   infrastructure view: **JVM runtime metrics appear for
   `vegas-scoring-service`** — they were absent before, because the meter
   provider only exists now, in the file.
2. **Logs** — open **Logs**, filter `service.name = vegas-scoring-service`:
   structured logback lines now arrive, each correlated with a trace.
3. **Traces** — still flowing frontend → game → scoring, as in M1.

??? note "Known wrinkle — you may see double export"
    The application still contains its legacy programmatic config
    (`OpenTelemetryConfig.java`), which keeps exporting its own manual spans.
    If a trace shows near-duplicate scoring spans, that is the old code path,
    not your file config. In production you would delete the programmatic
    config and let the file be the single source of truth; for the lab it is
    harmless — the *new* signals (JVM metrics, logs) come only from the file.

## Definition of done — M2

- [ ] You can explain the three config surfaces and when each wins
- [ ] You can state the env-var rule for file mode without looking it up
- [ ] You drove the change with opencode and shipped it as a **merged Gitea
      PR** — `k8s/21-scoring-otel.yaml` (ConfigMap + Instrumentation CR) plus the
      `k8s/20-scoring.yaml` wiring
- [ ] JVM metrics and logs from `vegas-scoring-service` visible in Dynatrace
- [ ] Traces still connected end-to-end

Next: [M3 — The collector as control point](module-3.md).
