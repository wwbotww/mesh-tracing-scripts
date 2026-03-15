# Reproducible Experiment Setup

This document provides a single-path runbook for:

- Kubernetes / Minikube
- Istio service mesh
- Demo app (`bookinfo` or `onlineboutique`)
- OpenTelemetry Collector
- Jaeger
- Prometheus
- Grafana
- Fault injection and sampling policy switching

## 1) Prerequisites

You need these tools in your PATH:

- `kubectl`
- `istioctl`
- `helm`
- `minikube`

Start a local cluster in single-node mode (Docker driver unified path):

```bash
minikube start --driver=docker --cpus=4 --memory=6144
```

If your existing Minikube profile already has extra worker nodes, reset it first:

```bash
minikube delete
minikube start --driver=docker --cpus=4 --memory=6144
```

Run prerequisite checks:

```bash
bash scripts/00_prereq_check.sh
```

Validation points:

- command exits with code 0
- `kubectl get nodes` returns exactly one Ready node

## 2) Install Istio

```bash
bash scripts/01_install_istio.sh --profile demo
```

Validation points:

- `kubectl -n istio-system get pods` shows `istiod` running
- `kubectl get ns mesh-app --show-labels` includes `istio-injection=enabled`

## 3) Deploy Application

Choose one:

```bash
bash scripts/02_deploy_app.sh --app bookinfo
# or
bash scripts/02_deploy_app.sh --app onlineboutique
```

Validation points:

- app pods are running in `mesh-app`
- service `productpage` (bookinfo) or `frontend` (onlineboutique) exists

For **onlineboutique**, the built-in `loadgenerator` deployment is scaled to 0 so that only fortio-injected traffic affects experiments. The experiment driver (`08_run_experiment.sh`) also ensures loadgenerator is scaled to 0 at run time.

## 4) Install Observability Stack

```bash
bash scripts/03_install_observability.sh --namespace observability --app-namespace mesh-app
```

Validation points:

- `otel-collector` pod is Running
- Jaeger UI is reachable
- Prometheus can query Istio/Envoy metrics (`istio_request_duration*` or `envoy_cluster_*`)

### Accessing Jaeger, Prometheus, Grafana from your laptop (cluster on a VM)

If the cluster runs on a **remote VM**, use SSH local port forwarding so your browser can reach the UIs. The "Connection refused" message appears when you open `localhost:16686` (or 9090/3000) **before** anything on the VM is listening on those ports — you must start the port-forwards **on the VM** first.

**Step 1 — On your laptop:** open an SSH session with local port forwarding (keep this session open):

```bash
ssh -L 16686:localhost:16686 -L 9090:localhost:9090 -L 3000:localhost:3000 your_user@<VM_IP>
```

**Step 2 — On the VM (in that SSH session or a second SSH):** start the port-forwards so VM's localhost:16686/9090/3000 are bound:

```bash
cd /path/to/mesh-tracing-scripts
bash scripts/port-forward-ui.sh
```

**Step 3 — On your laptop:** in the browser open:

- Jaeger: http://localhost:16686  
- Prometheus: http://localhost:9090  
- Grafana: http://localhost:3000  

To stop the port-forwards on the VM: `bash scripts/port-forward-ui.sh --stop`.

Manual port-forward (if you prefer one per terminal):

```bash
# Jaeger
kubectl -n observability port-forward svc/jaeger-query 16686:16686
# Prometheus (another terminal)
kubectl -n observability port-forward svc/obs-kube-prometheus-stack-prometheus 9090:9090
# Grafana (another terminal)
kubectl -n observability port-forward svc/obs-grafana 3000:80
```

## 5) Apply Sampling Policy

Examples:

```bash
bash scripts/04_apply_sampling_policy.sh --policy head --budget medium
bash scripts/04_apply_sampling_policy.sh --policy tail --budget low
bash scripts/04_apply_sampling_policy.sh --policy my_policy --budget high
bash scripts/04_apply_sampling_policy.sh --policy reference --budget high
bash scripts/04_apply_sampling_policy.sh --policy no_tracing --budget low
```

Canonical policy aliases:

- `head` -> `baseline_head`
- `tail` -> `baseline_tail`
- `my_policy` -> volatility-driven tail controller
- `reference` -> high-sampling reference config
- `no_tracing` -> Telemetry sampling `0.0`

Validation points:

- script exits successfully
- `kubectl -n observability get configmap otel-collector-config`
- `kubectl -n mesh-app get telemetry tracing-default`

## 6) Inject Fault

Delay fault example:

```bash
bash scripts/05_inject_fault.sh \
  --apply --fault delay --target_service productpage \
  --fixed_delay_ms 500 --percentage 50 \
  --namespace mesh-app --obs-namespace observability \
  --target_url "http://productpage.mesh-app.svc.cluster.local:9080/productpage"
```

Abort fault example:

```bash
bash scripts/05_inject_fault.sh \
  --apply --fault abort --target_service productpage \
  --http_status 500 --percentage 20 \
  --namespace mesh-app --obs-namespace observability \
  --target_url "http://productpage.mesh-app.svc.cluster.local:9080/productpage"
```

Validation points:

- `kubectl -n mesh-app get virtualservice`
- downstream request latency/error rate changes under load

## 7) Run Load

```bash
bash scripts/06_run_load.sh \
  --app bookinfo \
  --rps 50 \
  --duration 60 \
  --target_url "http://productpage.mesh-app.svc.cluster.local:9080/productpage"
```

Validation points:

- Job `loadgen` completes
- `kubectl -n mesh-app logs job/loadgen` shows HTTP status codes

## 8) Collect Metrics and Snapshots

```bash
bash scripts/07_collect_metrics.sh \
  --obs-namespace observability \
  --app-namespace mesh-app \
  --output-dir results/runs/manual_run_001
```

Validation points:

- new folder created under `results/runs/<run_id>/`
- files include `cost_metrics.json`, `metrics_raw/*.json`, `snapshots/cluster/*`, `snapshots/config/*`

## 9) Cleanup

```bash
bash scripts/99_cleanup.sh --app bookinfo
```

If your app namespace is the default path in this repo:

```bash
bash scripts/99_cleanup.sh --app bookinfo --app-namespace mesh-app
```

Validation points:

- observability deployments removed or scaled down per your choice
- fault/load resources removed

## 10) One-Click Experiment Driver

Example command:

```bash
bash scripts/08_run_experiment.sh \
  --app bookinfo \
  --policy tail \
  --budget medium \
  --fault-type delay \
  --fault-target edge=productpage->reviews \
  --load-level medium \
  --rps 200 \
  --duration 300 \
  --repeat-id 1
```

What it does:

- checks and installs prerequisites/components when needed
- applies sampling policy
- starts load and warms up 60s
- injects fault during middle 60% of experiment duration
- clears fault and collects metrics
- writes `run_context.json`, `summary.json`, `utility/*.json`, `metrics_raw/*.json`
- appends one row to `results/index.jsonl`
- prints final result directory path

Main logs:

- driver log: `results/exp_driver.log`
- latest result dir pointer: `results/last_experiment_dir.txt`
- structured index: `results/index.jsonl`

Result directory layout:

```text
results/runs/<run_id>/
  run_context.json
  summary.json
  cost_metrics.json
  metrics.json
  metrics_raw/
  load/
  fault/
  utility/
  snapshots/
```

## 11) Matrix Experiment Driver

Example spec:

```bash
cat experiments/mvp_matrix.json
```

Run the matrix:

```bash
bash scripts/09_run_matrix.sh --spec experiments/mvp_matrix.json
```

Outputs:

- `results/matrix_runs/<matrix_id>/expanded_runs.jsonl`
- `results/matrix_runs/<matrix_id>/runs.jsonl`
- `results/matrix_runs/<matrix_id>/matrix_summary.json`
- each successful run still writes into `results/runs/<run_id>/`

## Recommended Experiment Matrix

For your thesis focus ("tracing overhead control and reduction"), run:

1. app: `bookinfo` and `onlineboutique`
2. policy: `no_tracing`, `head`, `tail`, `my_policy`, `reference`
3. budget: `low`, `medium`, `high`
4. fault: none / `delay` / `abort`

Collect per-run outputs in `results/` and compare:

- request latency percentiles
- error rate
- trace volume (spans/sec)
- control-plane and data-plane overhead (CPU/memory)
- utility placeholders: `utility/rca_ranking.json`, `utility/critical_path.json`

## TODO Gaps to Complete

- Keep app deployment remote-only (official upstream URLs) and avoid local app manifest forks.
- Wire OTel Collector exporter to Jaeger and/or Tempo.
- Add Prometheus scrape jobs for Istio proxies and control plane.
- Add Grafana dashboards for overhead and tail latency decomposition.
- Tune and document the volatility-driven `my_policy` controller thresholds and profile mapping.
