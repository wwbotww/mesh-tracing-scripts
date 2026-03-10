#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${ROOT_DIR}/results"
OBS_NS="observability"
APP_NS="mesh-app"
WINDOW="300"
OUTPUT_DIR=""
PROM_SVC="obs-kube-prometheus-stack-prometheus"
PROM_PORT_LOCAL="19090"
PROMQL_FILE=""
METRICS_FILE=""
SNAPSHOT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/07_collect_metrics.sh [--window 300] [--output_dir results/run_<timestamp>/] [--obs-namespace observability] [--app-namespace mesh-app]

Collects (Cost MVP):
  1) P95/P99 end-to-end latency (histogram_quantile from Istio metrics)
  2) Envoy sidecar CPU (container_cpu_usage_seconds_total filtered by istio-proxy)
  3) spans/sec or bytes/sec (from OTel collector exported telemetry metrics)

Outputs:
  - promql.txt
  - metrics.json
  - config_snapshot/ (sampling policy + fault config snapshots)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="${2:-}"; shift 2 ;;
    --output_dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --obs-namespace) OBS_NS="${2:-}"; shift 2 ;;
    --app-namespace) APP_NS="${2:-}"; shift 2 ;;
    --prom-service) PROM_SVC="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
command -v python3 >/dev/null 2>&1 || err "python3 not found"
[[ "${WINDOW}" =~ ^[0-9]+$ ]] || err "--window must be integer seconds"

STAMP="$(date +%Y%m%d_%H%M%S)"
if [[ -z "${OUTPUT_DIR}" ]]; then
  OUT_DIR="${OUT_ROOT}/run_${STAMP}"
else
  case "${OUTPUT_DIR}" in
    /*) OUT_DIR="${OUTPUT_DIR}" ;;
    *) OUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}" ;;
  esac
fi
mkdir -p "${OUT_DIR}" || err "Failed to create output dir: ${OUT_DIR}"
SNAPSHOT_DIR="${OUT_DIR}/config_snapshot"
mkdir -p "${SNAPSHOT_DIR}" || err "Failed to create config snapshot dir: ${SNAPSHOT_DIR}"
PROMQL_FILE="${OUT_DIR}/promql.txt"
METRICS_FILE="${OUT_DIR}/metrics.json"

log "Collecting base cluster snapshots into ${OUT_DIR}..."
kubectl get nodes -o wide > "${OUT_DIR}/nodes.txt" || err "Failed to capture nodes"
kubectl get pods -A -o wide > "${OUT_DIR}/pods_all.txt" || err "Failed to capture pods"
kubectl get svc -A > "${OUT_DIR}/services_all.txt" || err "Failed to capture services"
kubectl get virtualservice -A > "${OUT_DIR}/virtualservices.txt" 2>/dev/null || warn "No VirtualService CRD/resources yet"
kubectl get telemetry -A > "${OUT_DIR}/telemetry.txt" 2>/dev/null || warn "No Telemetry CRD/resources yet"
kubectl get events -A --sort-by=.lastTimestamp > "${OUT_DIR}/events.txt" || warn "Failed to capture events"

log "Capturing observability endpoint snapshots..."
kubectl get pods,svc -n "${OBS_NS}" > "${OUT_DIR}/observability_resources.txt" || warn "Cannot list observability namespace"
kubectl get deploy,svc,pods -n "${APP_NS}" > "${OUT_DIR}/app_resources.txt" || warn "Cannot list app namespace"

cat > "${PROMQL_FILE}" <<EOF
# Window used for rate calculations: ${WINDOW}s

# 1) End-to-end latency (Istio)
p95_latency_ms = histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_workload_namespace="${APP_NS}"}[${WINDOW}s])) by (le))
p99_latency_ms = histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_workload_namespace="${APP_NS}"}[${WINDOW}s])) by (le))

# 2) Envoy sidecar CPU
envoy_cpu_cores_sum = sum(rate(container_cpu_usage_seconds_total{namespace="${APP_NS}",container="istio-proxy"}[${WINDOW}s]))
envoy_cpu_cores_per_pod = sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="${APP_NS}",container="istio-proxy"}[${WINDOW}s]))

# 3) Trace throughput / overhead proxy
otel_spans_per_sec = sum(rate(otelcol_exporter_sent_spans{service_instance_id=~".*"}[${WINDOW}s]))
otel_bytes_per_sec = sum(rate(otelcol_exporter_sent_bytes{service_instance_id=~".*"}[${WINDOW}s]))
otel_accepted_spans_per_sec = sum(rate(otelcol_receiver_accepted_spans{service_instance_id=~".*"}[${WINDOW}s]))
EOF

run_query() {
  local query="$1"
  curl -fsS --get "http://127.0.0.1:${PROM_PORT_LOCAL}/api/v1/query" --data-urlencode "query=${query}" || return 1
}

extract_scalar() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "NA")'
}

extract_series() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); out=[]; 
for x in r:
  metric=x.get("metric",{})
  pod=metric.get("pod","")
  val=x.get("value",["","NA"])[1]
  out.append(f"{pod}:{val}" if pod else str(val))
print(",".join(out) if out else "NA")'
}

log "Port-forward to Prometheus service ${PROM_SVC} in ns=${OBS_NS}..."
kubectl -n "${OBS_NS}" port-forward svc/"${PROM_SVC}" "${PROM_PORT_LOCAL}:9090" >/tmp/collect-prom-pf.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3

# Query metrics
p95_query="histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\"}[${WINDOW}s])) by (le))"
p99_query="histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\"}[${WINDOW}s])) by (le))"
envoy_sum_query="sum(rate(container_cpu_usage_seconds_total{namespace=\"${APP_NS}\",container=\"istio-proxy\"}[${WINDOW}s]))"
envoy_pod_query="sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"${APP_NS}\",container=\"istio-proxy\"}[${WINDOW}s]))"
spans_query="sum(rate(otelcol_exporter_sent_spans{service_instance_id=~\".*\"}[${WINDOW}s]))"
bytes_query="sum(rate(otelcol_exporter_sent_bytes{service_instance_id=~\".*\"}[${WINDOW}s]))"
accepted_spans_query="sum(rate(otelcol_receiver_accepted_spans{service_instance_id=~\".*\"}[${WINDOW}s]))"

p95_val="$(run_query "${p95_query}" | extract_scalar 2>/dev/null || echo NA)"
p99_val="$(run_query "${p99_query}" | extract_scalar 2>/dev/null || echo NA)"
envoy_sum_val="$(run_query "${envoy_sum_query}" | extract_scalar 2>/dev/null || echo NA)"
envoy_pod_val="$(run_query "${envoy_pod_query}" | extract_series 2>/dev/null || echo NA)"
spans_val="$(run_query "${spans_query}" | extract_scalar 2>/dev/null || echo NA)"
bytes_val="$(run_query "${bytes_query}" | extract_scalar 2>/dev/null || echo NA)"
accepted_spans_val="$(run_query "${accepted_spans_query}" | extract_scalar 2>/dev/null || echo NA)"

export STAMP WINDOW OBS_NS APP_NS \
  p95_query p99_query envoy_sum_query envoy_pod_query spans_query bytes_query accepted_spans_query \
  p95_val p99_val envoy_sum_val envoy_pod_val spans_val bytes_val accepted_spans_val
python3 - <<'PY' > "${METRICS_FILE}"
import json
import os

doc = {
    "collected_at": os.environ["STAMP"],
    "window_seconds": int(os.environ["WINDOW"]),
    "namespaces": {
        "observability": os.environ["OBS_NS"],
        "app": os.environ["APP_NS"],
    },
    "queries": {
        "p95_latency_ms": os.environ["p95_query"],
        "p99_latency_ms": os.environ["p99_query"],
        "envoy_cpu_cores_sum": os.environ["envoy_sum_query"],
        "envoy_cpu_cores_per_pod": os.environ["envoy_pod_query"],
        "otel_spans_per_sec": os.environ["spans_query"],
        "otel_bytes_per_sec": os.environ["bytes_query"],
        "otel_accepted_spans_per_sec": os.environ["accepted_spans_query"],
    },
    "results": {
        "p95_latency_ms": os.environ["p95_val"],
        "p99_latency_ms": os.environ["p99_val"],
        "envoy_cpu_cores_sum": os.environ["envoy_sum_val"],
        "envoy_cpu_cores_per_pod": os.environ["envoy_pod_val"],
        "otel_spans_per_sec": os.environ["spans_val"],
        "otel_bytes_per_sec": os.environ["bytes_val"],
        "otel_accepted_spans_per_sec": os.environ["accepted_spans_val"],
    },
}
print(json.dumps(doc, ensure_ascii=True, indent=2))
PY

# Config snapshots for policy/fault state
log "Dumping sampling/fault config snapshots..."
kubectl get configmap otel-collector-config -n "${OBS_NS}" -o yaml > "${SNAPSHOT_DIR}/otel-collector-config.yaml" 2>/dev/null || warn "otel-collector-config not found"
kubectl get configmap tracing-sampling-policy -n istio-system -o yaml > "${SNAPSHOT_DIR}/tracing-sampling-policy.yaml" 2>/dev/null || warn "tracing-sampling-policy not found"
kubectl get virtualservice -n "${APP_NS}" -l app.kubernetes.io/managed-by=trace-exp -o yaml > "${SNAPSHOT_DIR}/fault-virtualservices.yaml" 2>/dev/null || warn "No managed fault VirtualService found"
kubectl get virtualservice -n "${APP_NS}" -o yaml > "${SNAPSHOT_DIR}/all-virtualservices.yaml" 2>/dev/null || warn "No VirtualService resources in app namespace"

kill "${PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

cat > "${OUT_DIR}/README.txt" <<EOF
Collected at: ${STAMP}
Observability namespace: ${OBS_NS}
App namespace: ${APP_NS}
Window (seconds): ${WINDOW}

Key files:
- ${PROMQL_FILE}
- ${METRICS_FILE}
- ${SNAPSHOT_DIR}/
EOF

log "Validation: output files count"
ls -1 "${OUT_DIR}" | wc -l | awk '{print "files:", $1}'

log "Metrics collection completed: ${OUT_DIR}"
