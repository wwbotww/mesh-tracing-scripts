#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${ROOT_DIR}/results/runs"
OBS_NS="observability"
APP_NS="mesh-app"
WINDOW="300"
OUTPUT_DIR=""
PROM_SVC="obs-kube-prometheus-stack-prometheus"
PROM_PORT_LOCAL="19090"
PROMQL_FILE=""
METRICS_FILE=""
RAW_DIR=""
SNAPSHOT_DIR=""
CLUSTER_DIR=""
CONFIG_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/07_collect_metrics.sh [--window 300] [--output_dir results/runs/<run_id>] \
    [--obs-namespace observability] [--app-namespace mesh-app]

Outputs:
  - promql.txt
  - cost_metrics.json
  - metrics.json
  - metrics_raw/*.json
  - snapshots/cluster/*
  - snapshots/config/*
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="${2:-}"; shift 2 ;;
    --output_dir|--output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
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

RAW_DIR="${OUT_DIR}/metrics_raw"
SNAPSHOT_DIR="${OUT_DIR}/snapshots"
CLUSTER_DIR="${SNAPSHOT_DIR}/cluster"
CONFIG_DIR="${SNAPSHOT_DIR}/config"
PROMQL_FILE="${OUT_DIR}/promql.txt"
METRICS_FILE="${OUT_DIR}/cost_metrics.json"

mkdir -p "${RAW_DIR}" "${CLUSTER_DIR}" "${CONFIG_DIR}" || err "Failed to create metrics output dirs"

capture_text_snapshot() {
  local file="$1"
  shift
  "$@" > "${file}" 2>/dev/null || warn "Snapshot command failed: $*"
}

write_error_json() {
  local file="$1"
  local reason="$2"
  python3 - <<'PY' "${file}" "${reason}"
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    json.dumps({"status": "error", "reason": sys.argv[2]}, ensure_ascii=True, indent=2) + "\n",
    encoding="utf-8",
)
PY
}

log "Collecting base cluster snapshots into ${SNAPSHOT_DIR}..."
capture_text_snapshot "${CLUSTER_DIR}/nodes.txt" kubectl get nodes -o wide
capture_text_snapshot "${CLUSTER_DIR}/pods_all.txt" kubectl get pods -A -o wide
capture_text_snapshot "${CLUSTER_DIR}/services_all.txt" kubectl get svc -A
capture_text_snapshot "${CLUSTER_DIR}/virtualservices.txt" kubectl get virtualservice -A
capture_text_snapshot "${CLUSTER_DIR}/telemetry.txt" kubectl get telemetry -A
capture_text_snapshot "${CLUSTER_DIR}/events.txt" kubectl get events -A --sort-by=.lastTimestamp
capture_text_snapshot "${CLUSTER_DIR}/observability_resources.txt" kubectl get pods,svc -n "${OBS_NS}"
capture_text_snapshot "${CLUSTER_DIR}/app_resources.txt" kubectl get deploy,svc,pods -n "${APP_NS}"

p50_query="histogram_quantile(0.50, sum(rate(istio_request_duration_milliseconds_bucket{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\"}[${WINDOW}s])) by (le))"
p95_query="histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\"}[${WINDOW}s])) by (le))"
p99_query="histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\"}[${WINDOW}s])) by (le))"
error_rate_query="((sum(rate(istio_requests_total{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\",response_code=~\"5..\"}[${WINDOW}s]))) or vector(0)) / clamp_min(sum(rate(istio_requests_total{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\"}[${WINDOW}s])), 0.0001)"
request_rate_query="sum(rate(istio_requests_total{reporter=\"destination\",destination_workload_namespace=\"${APP_NS}\"}[${WINDOW}s]))"
envoy_sum_query="sum(rate(container_cpu_usage_seconds_total{namespace=\"${APP_NS}\",container=\"istio-proxy\"}[${WINDOW}s]))"
envoy_pod_query="sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"${APP_NS}\",container=\"istio-proxy\"}[${WINDOW}s]))"
spans_query="sum(rate(otelcol_exporter_sent_spans{service_instance_id=~\".*\"}[${WINDOW}s]))"
bytes_query="sum(rate(otelcol_exporter_sent_bytes{service_instance_id=~\".*\"}[${WINDOW}s]))"
accepted_spans_query="sum(rate(otelcol_receiver_accepted_spans{service_instance_id=~\".*\"}[${WINDOW}s]))"

cat > "${PROMQL_FILE}" <<EOF
# Window used for rate calculations: ${WINDOW}s
p50_latency_ms = ${p50_query}
p95_latency_ms = ${p95_query}
p99_latency_ms = ${p99_query}
error_rate = ${error_rate_query}
request_rate = ${request_rate_query}
envoy_cpu_cores_sum = ${envoy_sum_query}
envoy_cpu_cores_per_pod = ${envoy_pod_query}
otel_spans_per_sec = ${spans_query}
otel_bytes_per_sec = ${bytes_query}
otel_accepted_spans_per_sec = ${accepted_spans_query}
EOF

run_query_to_file() {
  local name="$1"
  local query="$2"
  local file="${RAW_DIR}/${name}.json"
  if ! curl -fsS --get "http://127.0.0.1:${PROM_PORT_LOCAL}/api/v1/query" --data-urlencode "query=${query}" > "${file}"; then
    write_error_json "${file}" "query_failed"
  fi
}

log "Port-forward to Prometheus service ${PROM_SVC} in ns=${OBS_NS}..."
kubectl -n "${OBS_NS}" port-forward svc/"${PROM_SVC}" "${PROM_PORT_LOCAL}:9090" >/tmp/collect-prom-pf.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3

run_query_to_file "p50_latency_ms" "${p50_query}"
run_query_to_file "p95_latency_ms" "${p95_query}"
run_query_to_file "p99_latency_ms" "${p99_query}"
run_query_to_file "error_rate" "${error_rate_query}"
run_query_to_file "request_rate" "${request_rate_query}"
run_query_to_file "envoy_cpu_cores_sum" "${envoy_sum_query}"
run_query_to_file "envoy_cpu_cores_per_pod" "${envoy_pod_query}"
run_query_to_file "otel_spans_per_sec" "${spans_query}"
run_query_to_file "otel_bytes_per_sec" "${bytes_query}"
run_query_to_file "otel_accepted_spans_per_sec" "${accepted_spans_query}"

python3 - <<'PY' \
  "${METRICS_FILE}" \
  "${OUT_DIR}/metrics.json" \
  "${PROMQL_FILE}" \
  "${RAW_DIR}" \
  "${STAMP}" \
  "${WINDOW}" \
  "${OBS_NS}" \
  "${APP_NS}" \
  "${p50_query}" \
  "${p95_query}" \
  "${p99_query}" \
  "${error_rate_query}" \
  "${request_rate_query}" \
  "${envoy_sum_query}" \
  "${envoy_pod_query}" \
  "${spans_query}" \
  "${bytes_query}" \
  "${accepted_spans_query}"
import json
import sys
from pathlib import Path

(
    metrics_path,
    compat_metrics_path,
    promql_path,
    raw_dir,
    stamp,
    window,
    obs_ns,
    app_ns,
    p50_query,
    p95_query,
    p99_query,
    error_rate_query,
    request_rate_query,
    envoy_sum_query,
    envoy_pod_query,
    spans_query,
    bytes_query,
    accepted_spans_query,
) = sys.argv[1:19]

raw_dir_path = Path(raw_dir)

def build_metric(name, query, expect_series=False):
    path = raw_dir_path / f"{name}.json"
    metric = {
        "query": query,
        "raw_file": str(path),
        "status": "missing",
        "reason": "query_failed",
        "value": None,
    }
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return metric

    if doc.get("status") == "error":
        metric["reason"] = doc.get("reason", "query_failed")
        return metric

    result = doc.get("data", {}).get("result", [])
    if not result:
        metric["reason"] = "query_empty"
        return metric

    metric["status"] = "ok"
    metric["reason"] = None
    if expect_series:
        values = []
        for item in result:
            raw_value = item.get("value", ["", None])[1]
            try:
                parsed_value = float(raw_value)
            except (TypeError, ValueError):
                parsed_value = None
            values.append({"labels": item.get("metric", {}), "value": parsed_value})
        metric["value"] = values
    else:
        raw_value = result[0].get("value", ["", None])[1]
        try:
            metric["value"] = float(raw_value)
        except (TypeError, ValueError):
            metric["status"] = "missing"
            metric["reason"] = "parse_failed"
            metric["value"] = None
    return metric

metrics = {
    "p50_latency_ms": build_metric("p50_latency_ms", p50_query),
    "p95_latency_ms": build_metric("p95_latency_ms", p95_query),
    "p99_latency_ms": build_metric("p99_latency_ms", p99_query),
    "error_rate": build_metric("error_rate", error_rate_query),
    "request_rate": build_metric("request_rate", request_rate_query),
    "envoy_cpu_cores_sum": build_metric("envoy_cpu_cores_sum", envoy_sum_query),
    "envoy_cpu_cores_per_pod": build_metric("envoy_cpu_cores_per_pod", envoy_pod_query, expect_series=True),
    "otel_spans_per_sec": build_metric("otel_spans_per_sec", spans_query),
    "otel_bytes_per_sec": build_metric("otel_bytes_per_sec", bytes_query),
    "otel_accepted_spans_per_sec": build_metric("otel_accepted_spans_per_sec", accepted_spans_query),
}

if (
    metrics["otel_spans_per_sec"]["status"] == "ok"
    and metrics["otel_accepted_spans_per_sec"]["status"] == "ok"
    and metrics["otel_accepted_spans_per_sec"]["value"] not in (None, 0)
):
    ratio_value = metrics["otel_spans_per_sec"]["value"] / metrics["otel_accepted_spans_per_sec"]["value"]
    metrics["effective_sampling_ratio"] = {
        "query": "otel_spans_per_sec / otel_accepted_spans_per_sec",
        "raw_file": None,
        "status": "ok",
        "reason": None,
        "value": ratio_value,
    }
else:
    metrics["effective_sampling_ratio"] = {
        "query": "otel_spans_per_sec / otel_accepted_spans_per_sec",
        "raw_file": None,
        "status": "missing",
        "reason": "derived_metric_missing",
        "value": None,
    }

doc = {
    "collected_at": stamp,
    "window_seconds": int(window),
    "promql_file": promql_path,
    "namespaces": {
        "observability": obs_ns,
        "app": app_ns,
    },
    "metrics": metrics,
}

serialized = json.dumps(doc, ensure_ascii=True, indent=2) + "\n"
Path(metrics_path).write_text(serialized, encoding="utf-8")
Path(compat_metrics_path).write_text(serialized, encoding="utf-8")
PY

log "Dumping sampling/fault config snapshots..."
capture_text_snapshot "${CONFIG_DIR}/otel-collector-config.yaml" kubectl get configmap otel-collector-config -n "${OBS_NS}" -o yaml
capture_text_snapshot "${CONFIG_DIR}/tracing-default.yaml" kubectl get telemetry -n "${APP_NS}" tracing-default -o yaml
capture_text_snapshot "${CONFIG_DIR}/fault-virtualservices.yaml" kubectl get virtualservice -n "${APP_NS}" -l app.kubernetes.io/managed-by=trace-exp -o yaml
capture_text_snapshot "${CONFIG_DIR}/all-virtualservices.yaml" kubectl get virtualservice -n "${APP_NS}" -o yaml

kill "${PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

log "Metrics collection completed: ${OUT_DIR}"
log "Artifacts:"
log "  - ${METRICS_FILE}"
log "  - ${RAW_DIR}"
