# mesh-tracing-scripts

Reproducible experiment testbed for **distributed-tracing sampling strategies** in a Kubernetes / Istio service mesh. Compares four sampling policies (reference, head, tail, my_policy) across three budget levels and three fault scenarios on Online Boutique, and reports a cost–utility trade-off (effective sampling ratio vs RCA Top-k localisation and Critical-Path Jaccard).

The headline matrix `matrix_20260418_054000` (4 policies × 3 budgets × 3 faults = 36 sequential runs, ~4 hours) and its analysis figures live under [`results/`](results/). Experiment design and the matrix specification are in [`experiments/`](experiments/).

---

## Quick Start

```bash
# 1) local single-node cluster
minikube start --driver=docker --cpus=4 --memory=12288

# 2) mesh + app + observability
bash scripts/01_install_istio.sh --profile demo
bash scripts/02_deploy_app.sh --app onlineboutique --namespace mesh-app
bash scripts/03_install_observability.sh --namespace observability --app-namespace mesh-app

# 3) full 36-run matrix (~4 h)
bash scripts/09_run_matrix.sh --spec experiments/mvp_matrix.json

# 4) figures
python3 scripts/plot_pareto.py \
  --matrix-dir results/matrix_runs/<matrix_id> \
  --output-dir results/figures

# 5) cleanup
bash scripts/99_cleanup.sh
```

---

## 1) Prerequisites

> **Platform**: validated on **Linux 6.17.0 (Ubuntu 24.04)** with Docker.

You need these tools in your PATH:

- `kubectl`
- `istioctl`
- `helm`
- `minikube`
- `python3` (>= 3.10) plus `pip install -r requirements.txt`

Start a local cluster in single-node mode:

```bash
minikube start --driver=docker --cpus=4 --memory=12288
```

If your existing minikube profile already has extra worker nodes, reset it first:

```bash
minikube delete
minikube start --driver=docker --cpus=4 --memory=12288
```

Run prerequisite checks:

```bash
bash scripts/00_prereq_check.sh
```

Validation:

- exit code 0
- `kubectl get nodes` returns exactly one Ready node

> **Memory note**: 12 GiB is required for stable matrix runs. A 6 GiB minikube produced load-avg 200+ and Jaeger OOM during reference (100%) runs.

---

## 2) Install Istio

```bash
bash scripts/01_install_istio.sh --profile demo
```

Validation:

- `kubectl -n istio-system get pods` shows `istiod` Running
- `kubectl get ns mesh-app --show-labels` includes `istio-injection=enabled`
- mesh extension provider `otel-tracing` points to `otel-collector.observability.svc.cluster.local:4317`

---

## 3) Deploy Application

Choose one:

```bash
bash scripts/02_deploy_app.sh --app bookinfo
# or
bash scripts/02_deploy_app.sh --app onlineboutique
```

Validation:

- app pods are Running in `mesh-app`
- service `productpage` (bookinfo) or `frontend` (onlineboutique) exists

For **onlineboutique** the bundled `loadgenerator` deployment is scaled to 0 so that only Fortio-injected traffic affects experiments. The single-run driver also re-asserts loadgenerator=0 at run time.

---

## 4) Install Observability Stack

```bash
bash scripts/03_install_observability.sh --namespace observability --app-namespace mesh-app
```

Validation:

- `otel-collector` pod Running
- Jaeger UI reachable at `:16686`
- Prometheus serves Istio/Envoy metrics (`istio_request_duration*`)

### Accessing Jaeger / Prometheus / Grafana from your laptop (cluster on a remote VM)

If the cluster runs on a remote VM, use SSH local port forwarding so your browser can reach the UIs.

**Step 1 — On your laptop:**

```bash
ssh -L 16686:localhost:16686 -L 9090:localhost:9090 -L 3000:localhost:3000 your_user@<VM_IP>
```

**Step 2 — On the VM:**

```bash
cd /path/to/mesh-tracing-scripts
bash scripts/port-forward-ui.sh
```

**Step 3 — On your laptop browser:**

- Jaeger: <http://localhost:16686>
- Prometheus: <http://localhost:9090>
- Grafana: <http://localhost:3000>

To stop the port-forwards on the VM: `bash scripts/port-forward-ui.sh --stop`.

Manual single-port alternatives:

```bash
kubectl -n observability port-forward svc/jaeger-query 16686:16686
kubectl -n observability port-forward svc/obs-kube-prometheus-stack-prometheus 9090:9090
kubectl -n observability port-forward svc/obs-grafana 3000:80
```

---

## 5) Apply Sampling Policy

```bash
bash scripts/04_apply_sampling_policy.sh --policy head      --budget medium
bash scripts/04_apply_sampling_policy.sh --policy tail      --budget low
bash scripts/04_apply_sampling_policy.sh --policy my_policy --budget high
bash scripts/04_apply_sampling_policy.sh --policy reference --budget high
bash scripts/04_apply_sampling_policy.sh --policy no_tracing --budget low
```

Accepted `--policy` values: `head | tail | my_policy | reference | no_tracing` (canonical aliases `baseline_head` / `baseline_tail` are also accepted).

| Alias | Resolves to | Notes |
|---|---|---|
| `head` | `baseline_head` | OTel `probabilistic_sampler` at 1 / 10 / 30 % per budget |
| `tail` | `baseline_tail` | OTel `tail_sampling` with error + latency + fallback rules |
| `my_policy` | volatility-driven tail controller | Same processor as tail, but profile is switched at runtime by `scripts/volatility_tail_controller.py` |
| `reference` | inline 100 % `probabilistic_sampler` | Ground-truth corpus; sampling rate ignores `--budget` |
| `no_tracing` | `probabilistic_sampler 0%` + Istio Telemetry `0.0` | Cost floor |

Validation:

- script exits 0
- `kubectl -n observability get configmap otel-collector-config`
- `kubectl -n mesh-app get telemetry tracing-default`

---

## 6) Inject Fault

Delay:

```bash
bash scripts/05_inject_fault.sh \
  --apply --fault delay --target_service productcatalogservice \
  --fixed_delay_ms 250 --percentage 50 \
  --namespace mesh-app --obs-namespace observability \
  --target_url "http://frontend.mesh-app.svc.cluster.local:80/"
```

Abort:

```bash
bash scripts/05_inject_fault.sh \
  --apply --fault abort --target_service productcatalogservice \
  --http_status 500 --percentage 20 \
  --namespace mesh-app --obs-namespace observability \
  --target_url "http://frontend.mesh-app.svc.cluster.local:80/"
```

Clear:

```bash
bash scripts/05_inject_fault.sh --clear --fault delay --target_service productcatalogservice \
  --namespace mesh-app
```

Validation:

- `kubectl -n mesh-app get virtualservice` shows the rendered fault VS
- before-and-after Prometheus probes recorded under `<run_dir>/fault/{apply,clear}_summary.json`

---

## 7) Run Load (standalone)

```bash
bash scripts/06_run_load.sh \
  --app onlineboutique \
  --rps 20 \
  --duration 300 \
  --target_url "http://frontend.mesh-app.svc.cluster.local:80/"
```

Validation:

- Job `loadgen` Completes
- `kubectl -n mesh-app logs job/loadgen` shows HTTP status codes

The standalone load script is mostly used for smoke testing. The matrix and single-run drivers below launch their own Fortio Job inline.

---

## 8) Collect Metrics and Snapshots

```bash
bash scripts/07_collect_metrics.sh \
  --obs-namespace observability \
  --app-namespace mesh-app \
  --output-dir results/runs/manual_run_001
```

Output:

- `cost_metrics.json`
- `metrics_raw/*.json`
- `snapshots/cluster/*`
- `snapshots/config/*`

---

## 9) Cleanup

```bash
bash scripts/99_cleanup.sh --app onlineboutique --app-namespace mesh-app
```

---

## 10) One-Click Single-Run Experiment Driver

Runs the full per-cell timeline (warmup → controller start → fault apply/clear → trace export → RCA + critical-path analysis):

```bash
bash scripts/08_run_experiment.sh \
  --app onlineboutique \
  --policy my_policy \
  --budget mid \
  --fault-type delay \
  --fault-target service=productcatalogservice \
  --load-level mid \
  --rps 20 \
  --duration 300 \
  --repeat-id 1
```

Per-run timeline (300 s duration):

```
T = 0s     Fortio Job starts (20 RPS, 420 s = 120 s warmup + 300 s test)
           Volatility controller starts (if my_policy)
T = 0..120 controller warm-up (4 polls, median baseline)
T = 180s   fault injected (after warmup + 60 s pre-fault settle)
T = 360s   fault cleared
T = 420s   load ends; export traces, run compute_rca.py + compute_critical_path.py
           write run_context.json, summary.json, append index.jsonl
```

Main artifacts:

- driver log: `results/exp_driver.log`
- latest run pointer: `results/last_experiment_dir.txt`
- structured matrix-wide ledger: `results/index.jsonl`

Per-run directory layout:

```
results/runs/<run_id>/
  run_context.json
  summary.json
  cost_metrics.json
  metrics.json, promql.txt
  load/load_summary.json
  fault/{apply,clear}_summary.json
  controller/                     ← only for my_policy runs
    controller_summary.json
    controller_events.jsonl
    collector_config_history/<ts>_<profile>.yaml
    metrics_raw/<iter>_<metric>.json
  utility/
    raw_traces/{current,reference}.json
    rca_features.json
    rca_ranking.json
    critical_path.json
  snapshots/{cluster,config}/*
  metrics_raw/<metric>.json
```

---

## 11) Matrix Experiment Driver

Spec:

```bash
cat experiments/mvp_matrix.json
```

Run:

```bash
bash scripts/09_run_matrix.sh --spec experiments/mvp_matrix.json
```

The matrix expands to **4 policies × 3 budgets × 1 load × 3 faults = 36 runs** executed sequentially (reference first so other policies have a corpus to compare against). Estimated wall time: ~4 h.

Outputs:

- `results/matrix_runs/<matrix_id>/expanded_runs.jsonl`
- `results/matrix_runs/<matrix_id>/runs.jsonl`
- `results/matrix_runs/<matrix_id>/matrix_summary.json`
- each successful run also writes into `results/runs/<run_id>/`

Verify:

```bash
cat results/matrix_runs/matrix_*/matrix_summary.json | python3 -m json.tool
ls results/runs/

python3 -c "
import json, sys
from pathlib import Path
for f in sorted(Path('results/matrix_runs').rglob('runs.jsonl')):
    lines = [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    ok = sum(1 for r in lines if r.get('status') == 'success')
    fail = sum(1 for r in lines if r.get('status') == 'failed')
    print(f'{f.parent.name}: success={ok}, failed={fail}, total={len(lines)}')
"
```

---

## Sampling Strategies — Parameter Reference

All policies share the **same** ConfigMap `otel-collector-config`; only the processor block differs.

### head (fixed probabilistic)

| Budget | Sampling % | Manifest |
|---|---|---|
| low | 1 | `manifests/sampling/baseline_head_low.yaml` |
| mid | 10 | `manifests/sampling/baseline_head_mid.yaml` |
| high | 30 | `manifests/sampling/baseline_head_high.yaml` |

### tail (static OTel tail_sampling)

OR-rule structure: `error-traces` + `high-latency` + `fallback-probability`.

| Budget | Latency threshold | Fallback % | num_traces | expected_new_traces_per_sec |
|---|---|---|---|---|
| low | 500 ms | 1 | 10 000 | 50 |
| mid | 300 ms | 10 | 30 000 | 150 |
| high | 200 ms | 30 | 80 000 | 300 |

### my_policy (volatility-driven adaptive tail)

Starts with the tail profile matching the budget, then `scripts/volatility_tail_controller.py` switches between three named profiles based on Prometheus metrics every 30 s.

Profiles (defined in [`scripts/volatility_tail_controller.py`](scripts/volatility_tail_controller.py)):

| Profile | latency threshold | fallback % | num_traces | expected_new_traces_per_sec |
|---|---|---|---|---|
| conservative | 500 ms | 1 | 10 000 | 50 |
| balanced | 300 ms | 10 | 30 000 | 150 |
| aggressive | 200 ms | 30 | 80 000 | 300 |

State classification (OR-of-thresholds):

| Signal | medium | high |
|---|---|---|
| `error_rate` | 0.01 | 0.03 |
| `p95_ratio` | 1.50 | 2.50 |
| `request_surge_ratio` | 2.00 | 3.00 |

State → profile map: `low → conservative`, `medium → balanced`, `high → aggressive`. After every profile change classification is skipped for one poll (cooldown).

Initial profile by `--budget`: `low → conservative`, `mid → balanced`, `high → aggressive`.

### reference

Inline `probabilistic_sampler.sampling_percentage: 100` (regardless of `--budget`). Provides the ground-truth corpus that all RCA and critical-path analyses compare against.

### no_tracing

OTel processor stripped + Istio Telemetry `randomSamplingPercentage: 0.0`. Cost floor.

---

## Output Directory

```
results/
├── runs/<run_id>/                  ← per-cell artifacts (see §10)
├── matrix_runs/<matrix_id>/
│   ├── expanded_runs.jsonl
│   ├── runs.jsonl
│   └── matrix_summary.json
├── figures/
│   ├── rca_tradeoff_delay.{png,pdf}
│   ├── rca_tradeoff_abort.{png,pdf}
│   ├── top3_hit_heatmap.{png,pdf}
│   ├── top5_hit_heatmap.{png,pdf}
│   └── critical_path_nofault.{png,pdf}
├── exp_driver.log, sampling.log, fault.log, observability.log
└── index.jsonl                     ← matrix-wide ledger of all runs
```

---

## Repository Layout

| Path | Purpose |
|---|---|
| `scripts/0[1-9]_*.sh`, `99_cleanup.sh` | numbered orchestration steps |
| `scripts/08_run_experiment.sh` | single-run driver — owns the per-run timeline |
| `scripts/09_run_matrix.sh` | matrix orchestrator |
| `scripts/volatility_tail_controller.py` | feedback controller (Python, 30 s poll) |
| `scripts/compute_rca.py` | edge-weighted RCA scoring with `S_missing` trace-rate normalisation |
| `scripts/compute_critical_path.py` | longest-weighted-path → Jaccard against reference |
| `scripts/plot_pareto.py` | Pareto / heatmap / no-fault figures from `matrix_summary.json` |
| `scripts/export_traces.py`, `parse_fortio_output.py` | utilities |
| `manifests/sampling/baseline_*.yaml` | static sampling ConfigMaps (head & tail) |
| `manifests/faults/{delay,abort}-template.yaml` | Istio VirtualService fault templates |
| `manifests/{otel,jaeger,prom,grafana}/*.yaml` | observability-stack manifests |
| `experiments/mvp_matrix.json` | matrix specification (36 cells) |
| `experiments/EXPERIMENT_DESIGN.md` | per-experiment design rationale |
