# MVP Utility-Cost Experiment Design

> Online Boutique + Istio mesh tracing: comparing four sampling strategies under
> homepage-only traffic with fault injection, collecting cost and utility metrics
> for Pareto frontier analysis.

---

## 1. Experiment Objective

Compare **reference**, **head**, **tail**, and **my_policy** sampling strategies
across three budget levels (low/mid/high) and three fault scenarios (none/delay/abort),
measuring:

- **Cost**: end-to-end latency overhead, trace volume, sidecar CPU
- **Utility**: RCA Top-k hit rate, Critical Path Fidelity (Jaccard/Precision/Recall)

Key hypothesis: **my_policy** (volatility-driven adaptive tail sampling) achieves
higher utility than static **tail** at equivalent cost, especially at low budget
under fault conditions, because the controller escalates the sampling profile when
anomalies are detected.

---

## 2. Run Steps (complete experiment)

```bash
# ── Step 0: Prerequisites ──────────────────────────────────────
# Verify tools: kubectl, istioctl, helm, minikube, python3
bash scripts/00_prereq_check.sh

# ── Step 1: Infrastructure (idempotent, only runs if missing) ──
bash scripts/01_install_istio.sh --profile demo
bash scripts/02_deploy_app.sh --app onlineboutique --namespace mesh-app
bash scripts/03_install_observability.sh --namespace observability --app-namespace mesh-app

# ── Step 2: (Optional) Open UIs for monitoring ─────────────────
bash scripts/port-forward-ui.sh
#   Jaeger:     http://localhost:16686
#   Prometheus: http://localhost:9090
#   Grafana:    http://localhost:3000

# ── Step 3: Run matrix experiment ──────────────────────────────
# This is the main command. It expands mvp_matrix.json into 36 runs
# and executes them sequentially (reference first, then head/tail/my_policy).
# Estimated time: ~4-5 hours (36 runs x ~7 min each).
bash scripts/09_run_matrix.sh --spec experiments/mvp_matrix.json

# ── Step 4: Verify results ─────────────────────────────────────
# Check matrix summary
cat results/matrix_runs/matrix_*/matrix_summary.json | python3 -m json.tool

# Check individual run summaries
ls results/runs/

# Count successful vs failed runs
python3 -c "
import json
from pathlib import Path
for f in sorted(Path('results/matrix_runs').rglob('runs.jsonl')):
    lines = [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    ok = sum(1 for r in lines if r.get('status') == 'success')
    fail = sum(1 for r in lines if r.get('status') == 'failed')
    print(f'{f.parent.name}: success={ok}, failed={fail}, total={len(lines)}')
"

# ── Step 5: Cleanup (optional) ─────────────────────────────────
bash scripts/99_cleanup.sh
```

### What happens inside each run (08_run_experiment.sh)

```
 T=0s      Fortio load starts (40 RPS, 360s total)
           Volatility controller starts (if my_policy)
 T=0-60s   Warmup: controller observes baseline
 T=60-120s Pre-fault: controller confirms stable state (level=low)
 T=120s    Fault injected (delay 400ms or abort 20%)
 T=~150s   Controller detects anomaly, escalates profile (my_policy only)
 T=120-300s Fault active (~180s window, ~6 controller polls)
 T=300s    Fault cleared
 T=300-360s Recovery phase
 T=360s    Load ends
           Collect Prometheus metrics + export Jaeger traces
           Run compute_rca.py + compute_critical_path.py
           Write summary.json, append to index.jsonl
```

---

## 3. Matrix Parameters

| Parameter       | Value                          | File to modify                           |
|-----------------|--------------------------------|------------------------------------------|
| app             | `onlineboutique`               | `experiments/mvp_matrix.json` → `"app"`  |
| policies        | reference, head, tail, my_policy | `experiments/mvp_matrix.json` → `"policies"` |
| budgets         | low, medium, high              | `experiments/mvp_matrix.json` → `"budgets"` |
| load RPS        | 40 (single level "mid")        | `experiments/mvp_matrix.json` → `"load_levels"` |
| duration        | 300s                           | `experiments/mvp_matrix.json` → `"duration_seconds"` |
| repeats         | 1                              | `experiments/mvp_matrix.json` → `"repeats"` |
| namespaces      | mesh-app / observability / istio-system | `experiments/mvp_matrix.json` → `"namespaces"` |

**Matrix size**: 4 policies x 3 budgets x 1 load x 3 faults x 1 repeat = **36 runs**

---

## 4. Fault Scenarios

| #  | type    | target service           | delay_ms | http_status | percentage | File to modify |
|----|---------|--------------------------|----------|-------------|------------|----------------|
| 1  | `none`  | —                        | —        | —           | —          | `experiments/mvp_matrix.json` → `"faults[0]"` |
| 2  | `delay` | `productcatalogservice`  | **400**  | 500         | **50**     | `experiments/mvp_matrix.json` → `"faults[1]"` |
| 3  | `abort` | `productcatalogservice`  | 200      | **500**     | **20**     | `experiments/mvp_matrix.json` → `"faults[2]"` |

### Why these values

- **delay=400ms**: Falls below `tail_low` latency threshold (500ms) but above
  `my_policy` aggressive threshold (200ms). This means `tail_low` **misses** these
  delayed traces while `my_policy` **captures** them after controller escalation.
  This is the key differentiator on the Pareto curve.

- **abort=20%**: Produces ~6.7% mesh-wide error rate (2 calls to productcatalogservice
  per homepage request / ~6 total inter-service calls x 20%), exceeding the controller's
  high threshold (5%). Both tail and my_policy capture error traces, but my_policy's
  escalated 30% fallback sampling provides richer context for RCA comparison.

- **target=productcatalogservice**: Called twice per homepage request (directly by
  frontend + indirectly via recommendationservice), creating multiple anomalous edges
  for RCA to disambiguate.

---

## 5. Sampling Strategy Configurations

### 5.1 reference (ground truth)

Always 100% probabilistic sampling regardless of budget.

| Parameter                  | Value | File to modify |
|----------------------------|-------|----------------|
| OTel processor             | `probabilistic_sampler` at 100% | `scripts/04_apply_sampling_policy.sh` → `apply_generated_policy()` |
| Istio Telemetry sampling   | 100%  | `scripts/04_apply_sampling_policy.sh` → line 265-268 |

### 5.2 head (baseline head sampling)

Fixed probabilistic sampling in OTel Collector.

| Budget | sampling_percentage | Manifest file |
|--------|---------------------|---------------|
| low    | 1%                  | `manifests/sampling/baseline_head_low.yaml` |
| mid    | 10%                 | `manifests/sampling/baseline_head_mid.yaml` |
| high   | 30%                 | `manifests/sampling/baseline_head_high.yaml` |

### 5.3 tail (baseline tail sampling, static)

OTel tail_sampling processor with fixed parameters per budget.

| Budget | latency_threshold | fallback_% | num_traces | Manifest file |
|--------|-------------------|------------|------------|---------------|
| low    | 500ms             | 1%         | 10,000     | `manifests/sampling/baseline_tail_low.yaml` |
| mid    | 300ms             | 10%        | 30,000     | `manifests/sampling/baseline_tail_mid.yaml` |
| high   | 200ms             | 30%        | 80,000     | `manifests/sampling/baseline_tail_high.yaml` |

### 5.4 my_policy (volatility-driven adaptive tail)

Starts with same config as tail at corresponding budget, then
`volatility_tail_controller.py` dynamically switches profile based on Prometheus metrics.

| Budget | Initial profile | Can escalate to | File to modify |
|--------|-----------------|-----------------|----------------|
| low    | conservative    | balanced → aggressive | `scripts/04_apply_sampling_policy.sh` → `apply_my_policy()` |
| mid    | balanced        | aggressive      | (same) |
| high   | aggressive      | (already max)   | (same) |

**Controller profiles** (defined in `scripts/volatility_tail_controller.py` → `PROFILES`):

| Profile       | latency_threshold | fallback_% | num_traces | expected_traces/sec |
|---------------|-------------------|------------|------------|---------------------|
| conservative  | 500ms             | 1%         | 10,000     | 50                  |
| balanced      | 300ms             | 10%        | 30,000     | 150                 |
| aggressive    | 200ms             | 30%        | 80,000     | 300                 |

**Controller classification thresholds** (`scripts/volatility_tail_controller.py` → `THRESHOLDS`):

| Metric             | medium threshold | high threshold |
|--------------------|------------------|----------------|
| error_rate         | 0.01 (1%)        | 0.05 (5%)      |
| p95_ratio          | 1.30 (30% above baseline) | 1.80 (80% above baseline) |
| request_surge_ratio| 1.20             | 1.50           |

**Level → Profile mapping** (`volatility_tail_controller.py` → `PROFILE_BY_LEVEL`):
- low → conservative
- medium → balanced
- high → aggressive

---

## 6. Timing Parameters

| Parameter                   | Value | Derivation           | File to modify |
|-----------------------------|-------|----------------------|----------------|
| WARMUP_SEC                  | 60s   | Fixed                | `scripts/08_run_experiment.sh` → line 655 |
| FAULT_START_AFTER_WARMUP    | 60s   | duration x 20%       | (computed) |
| FAULT_PHASE_SEC             | 180s  | duration x 60%       | (computed) |
| TOTAL_LOAD_SEC              | 360s  | WARMUP + duration    | (computed) |
| Controller poll interval    | 30s   | Default              | `scripts/08_run_experiment.sh` → `CONTROLLER_POLL_INTERVAL_SECONDS` |
| Controller Prometheus window| 120s  | Default              | `scripts/08_run_experiment.sh` → `CONTROLLER_WINDOW_SECONDS` |
| Controller warmup           | 60s   | = WARMUP_SEC         | `scripts/08_run_experiment.sh` → `CONTROLLER_WARMUP_SECONDS` |

---

## 7. Cost Metrics Collected

| Metric                     | Source          | Prometheus query / file |
|----------------------------|-----------------|-------------------------|
| p50/p95/p99 latency (ms)  | Fortio          | `results/runs/<id>/load/load_summary.json` |
| p50/p95/p99 latency (ms)  | Prometheus      | `istio_request_duration_milliseconds_bucket` via `scripts/07_collect_metrics.sh` |
| error_rate                 | Fortio          | `load_summary.json` → `http_error_rate` |
| error_rate                 | Prometheus      | `istio_requests_total{response_code=~"5.."}` |
| request_rate (req/sec)     | Prometheus      | `istio_requests_total` |
| sidecar CPU (cores)        | Prometheus      | `container_cpu_usage_seconds_total` (envoy containers) |
| spans exported/sec         | Prometheus      | `otelcol_exporter_sent_spans` |
| bytes exported/sec         | Prometheus      | (if available) |
| effective sampling ratio   | Computed        | exported / received spans |

Output: `results/runs/<id>/cost_metrics.json` and `results/runs/<id>/summary.json` → `cost_metrics`

---

## 8. Utility Metrics Collected

### 8.1 RCA Top-k

Script: `scripts/compute_rca.py`

| Metric           | Description |
|------------------|-------------|
| service_top1_hit | Ranked #1 service == productcatalogservice |
| service_top3_hit | productcatalogservice in top 3 |
| edge_top1_hit    | Ranked #1 edge involves productcatalogservice |
| edge_top3_hit    | Target edge in top 3 |

**Scoring formula** (`scripts/compute_rca.py` → line 243):
```
S_edge = 0.5 * S_latency + 0.3 * S_error + 0.2 * S_missing
```

| Weight component | Weight | Computation |
|------------------|--------|-------------|
| S_latency        | 0.5    | min(1, (current_p95 - ref_p95) / (ref_p95 + eps)) |
| S_error          | 0.3    | max(0, current_error_rate - ref_error_rate) |
| S_missing        | 0.2    | max(0, (ref_count - cur_count) / (ref_count + eps)) |

Constants: `EPSILON=1e-6`, `N_MIN=20`

Output: `results/runs/<id>/utility/rca_ranking.json`, `rca_features.json`

### 8.2 Critical Path Fidelity

Script: `scripts/compute_critical_path.py`

| Metric    | Description |
|-----------|-------------|
| jaccard   | \|intersection\| / \|union\| of critical edge sets |
| precision | \|intersection\| / \|current_edges\| |
| recall    | \|intersection\| / \|reference_edges\| |

Constants: `SUPPORT_THRESHOLD=0.2`, `MIN_TRACE_COUNT=10`

Output: `results/runs/<id>/utility/critical_path.json`

---

## 9. File Reference Map

### Configuration files (what to change)

| What                          | File                                          |
|-------------------------------|-----------------------------------------------|
| Matrix experiment parameters  | `experiments/mvp_matrix.json`                 |
| Head sampling configs         | `manifests/sampling/baseline_head_{low,mid,high}.yaml` |
| Tail sampling configs         | `manifests/sampling/baseline_tail_{low,mid,high}.yaml` |
| Fault injection templates     | `manifests/faults/delay-template.yaml`, `abort-template.yaml` |
| OTel Collector base config    | `manifests/otel/otel-collector.yaml`          |
| Jaeger deployment             | `manifests/jaeger/jaeger.yaml`                |
| Prometheus config             | `manifests/prom/prometheus.yaml`              |
| Grafana config                | `manifests/grafana/grafana.yaml`              |

### Script files (logic to modify)

| What                          | File                                          |
|-------------------------------|-----------------------------------------------|
| Sampling policy application   | `scripts/04_apply_sampling_policy.sh`         |
| Fault injection logic         | `scripts/05_inject_fault.sh`                  |
| Load generation               | `scripts/06_run_load.sh`                      |
| Metrics collection            | `scripts/07_collect_metrics.sh`               |
| Single-run orchestrator       | `scripts/08_run_experiment.sh`                |
| Matrix orchestrator           | `scripts/09_run_matrix.sh`                    |
| Volatility controller         | `scripts/volatility_tail_controller.py`       |
| RCA computation               | `scripts/compute_rca.py`                      |
| Critical path computation     | `scripts/compute_critical_path.py`            |
| Trace export                  | `scripts/export_traces.py`                    |
| Fortio log parser             | `scripts/parse_fortio_output.py`              |

### Output files (where results land)

| What                          | Path                                          |
|-------------------------------|-----------------------------------------------|
| Per-run results               | `results/runs/<run_id>/`                      |
| Run context (parameters)      | `results/runs/<run_id>/run_context.json`      |
| Run summary (all metrics)     | `results/runs/<run_id>/summary.json`          |
| Load test output              | `results/runs/<run_id>/load/load_summary.json`|
| Cost metrics                  | `results/runs/<run_id>/cost_metrics.json`     |
| RCA ranking                   | `results/runs/<run_id>/utility/rca_ranking.json` |
| Critical path                 | `results/runs/<run_id>/utility/critical_path.json` |
| Raw traces                    | `results/runs/<run_id>/utility/raw_traces/`   |
| Controller logs               | `results/runs/<run_id>/controller/`           |
| Fault metrics                 | `results/runs/<run_id>/fault/`                |
| Matrix summary                | `results/matrix_runs/<matrix_id>/matrix_summary.json` |
| Matrix run log                | `results/matrix_runs/<matrix_id>/runs.jsonl`  |
| Global run index              | `results/index.jsonl`                         |

---

## 10. Important Notes

### Jaeger memory retention

36 runs over ~4-5 hours. Default Jaeger in-memory storage may evict early reference
traces before later runs export them. Mitigations:

1. **Recommended**: Configure Jaeger with persistent storage (Badger/Elasticsearch)
2. Run in batches per fault scenario (12 runs/batch, ~1.4h each)
3. Increase Jaeger memory: add `--memory.max-traces=200000` in `manifests/jaeger/jaeger.yaml`

### Reference policy

Reference always uses 100% sampling regardless of budget level
(`scripts/04_apply_sampling_policy.sh` → `apply_generated_policy()`).
Reference at all 3 budgets produces identical trace data. For utility comparison,
non-reference runs automatically match against the latest reference run with the
same fault parameters (via `resolve_reference_run_summary()` in `08_run_experiment.sh`).

### Fortio trace headers

The Fortio job sends `x-b3-sampled: 1` and `x-envoy-force-trace: true` headers
(`scripts/08_run_experiment.sh` → line 686-689). This forces all Envoy sidecars to
generate trace spans for every request. Actual sampling happens at the OTel Collector
level, which is the variable under test.

### Scaling for publication

| Dimension | MVP (current) | Publication |
|-----------|---------------|-------------|
| repeats   | 1             | 3-5         |
| faults    | 3             | 5+ (vary target, percentage) |
| RPS       | 40            | multi-level (20, 40, 80) |
| duration  | 300s          | 300-600s    |
| app       | onlineboutique | + bookinfo  |
