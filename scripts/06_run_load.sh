#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

APP="bookinfo"
NAMESPACE="mesh-app"
ISTIO_NAMESPACE="istio-system"
OBS_NAMESPACE="observability"
PROM_SVC="obs-kube-prometheus-stack-prometheus"
JAEGER_SVC="jaeger-query"
PROM_PORT_LOCAL="19091"
JAEGER_PORT_LOCAL="16687"
RPS="50"
DURATION="300"
TARGET_URL=""
JOB_NAME="loadgen"
OUTPUT_DIR=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
OUT_DIR=""
LOAD_DIR=""
PROM_BEFORE_FILE=""
PROM_AFTER_FILE=""
JAEGER_TRACE_FILE=""
FORTIO_LOG=""
LOAD_SUMMARY=""

usage() {
  cat <<'EOF'
Usage:
  scripts/06_run_load.sh [--app bookinfo|onlineboutique] [--rps 50] [--duration 300] \
    [--target_url http://...] [--namespace mesh-app] [--output-dir results/runs/<run_id>] [--job-name loadgen]

Default load generator: fortio (K8s Job mode)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --rps) RPS="${2:-}"; shift 2 ;;
    --duration) DURATION="${2:-}"; shift 2 ;;
    --target_url|--target-url) TARGET_URL="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --istio-namespace) ISTIO_NAMESPACE="${2:-}"; shift 2 ;;
    --obs-namespace) OBS_NAMESPACE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --job-name) JOB_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ "${APP}" =~ ^(bookinfo|onlineboutique)$ ]] || err "--app must be bookinfo|onlineboutique"
[[ "${RPS}" =~ ^[0-9]+$ ]] || err "--rps must be integer"
[[ "${DURATION}" =~ ^[0-9]+$ ]] || err "--duration must be seconds (integer)"
[[ -n "${JOB_NAME}" ]] || err "--job-name cannot be empty"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
command -v python3 >/dev/null 2>&1 || err "python3 not found"
mkdir -p "${RESULTS_DIR}" || err "Failed to create results directory"

resolve_output_dir() {
  if [[ -n "${OUTPUT_DIR}" ]]; then
    case "${OUTPUT_DIR}" in
      /*) OUT_DIR="${OUTPUT_DIR}" ;;
      *) OUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}" ;;
    esac
  else
    OUT_DIR="${RESULTS_DIR}/runs/load_$(date +%Y%m%d_%H%M%S)"
  fi
  LOAD_DIR="${OUT_DIR}/load"
  mkdir -p "${LOAD_DIR}" || err "Failed to create load output dir"
  PROM_BEFORE_FILE="${LOAD_DIR}/prometheus_request_count_before.json"
  PROM_AFTER_FILE="${LOAD_DIR}/prometheus_request_count_after.json"
  JAEGER_TRACE_FILE="${LOAD_DIR}/jaeger_trace_query.json"
  FORTIO_LOG="${LOAD_DIR}/fortio_stdout.log"
  LOAD_SUMMARY="${LOAD_DIR}/load_summary.json"
}

detect_target_url() {
  local path="/"
  [[ "${APP}" == "bookinfo" ]] && path="/productpage"

  if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
    local ip nodeport
    ip="$(minikube ip || true)"
    nodeport="$(kubectl -n "${ISTIO_NAMESPACE}" get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' || true)"
    if [[ -n "${ip}" && -n "${nodeport}" ]]; then
      echo "http://${ip}:${nodeport}${path}"
      return 0
    fi
  fi

  local lbip port
  lbip="$(kubectl -n "${ISTIO_NAMESPACE}" get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || true)"
  port="$(kubectl -n "${ISTIO_NAMESPACE}" get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}' || true)"
  if [[ -n "${lbip}" && -n "${port}" ]]; then
    echo "http://${lbip}:${port}${path}"
    return 0
  fi

  return 1
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

prom_query_to_file() {
  local query="$1"
  local file="$2"
  if ! curl -fsS --get "http://127.0.0.1:${PROM_PORT_LOCAL}/api/v1/query" --data-urlencode "query=${query}" > "${file}"; then
    write_error_json "${file}" "query_failed"
  fi
}

extract_scalar_from_file() {
  local file="$1"
  python3 - <<'PY' "${file}"
import json
import sys

try:
    doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
    print("NA")
    sys.exit(0)

if doc.get("status") != "success":
    print("NA")
    sys.exit(0)

result = doc.get("data", {}).get("result", [])
if not result:
    print("NA")
else:
    print(result[0].get("value", ["", "NA"])[1])
PY
}

resolve_output_dir

if [[ -z "${TARGET_URL}" ]]; then
  TARGET_URL="$(detect_target_url || true)"
fi
[[ -n "${TARGET_URL}" ]] || err "Cannot auto-detect --target_url; please provide it explicitly."

log "Load test config: app=${APP}, rps=${RPS}, duration=${DURATION}s, target=${TARGET_URL}, output=${LOAD_DIR}"

log "Querying baseline request counter from Prometheus (if reachable)..."
kubectl -n "${OBS_NAMESPACE}" port-forward svc/"${PROM_SVC}" "${PROM_PORT_LOCAL}:9090" >/tmp/load-prom-pf.log 2>&1 &
PROM_PF_PID=$!
trap 'kill ${PROM_PF_PID:-} ${JAEGER_PF_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3
prom_query_to_file "sum(istio_requests_total)" "${PROM_BEFORE_FILE}"

log "Creating/replacing Fortio job ${JOB_NAME} for ${APP}..."
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      containers:
      - name: fortio
        image: fortio/fortio:1.63.0
        command: ["fortio"]
        args:
        - load
        - -qps
        - "${RPS}"
        - -t
        - "${DURATION}s"
        - -H
        - "x-b3-sampled: 1"
        - -H
        - "x-envoy-force-trace: true"
        - "${TARGET_URL}"
EOF

log "Validation: waiting job completion..."
kubectl wait --for=condition=complete job/"${JOB_NAME}" -n "${NAMESPACE}" --timeout="$((DURATION + 240))s" || err "Load job did not complete in time"
kubectl logs job/"${JOB_NAME}" -n "${NAMESPACE}" > "${FORTIO_LOG}" || err "Failed to capture load job logs"

log "Checking Prometheus counter growth..."
sleep 15
prom_query_to_file "sum(istio_requests_total)" "${PROM_AFTER_FILE}"

log "Checking Jaeger traces presence..."
kubectl -n "${OBS_NAMESPACE}" port-forward svc/"${JAEGER_SVC}" "${JAEGER_PORT_LOCAL}:16686" >/tmp/load-jaeger-pf.log 2>&1 &
JAEGER_PF_PID=$!
sleep 3
JAEGER_SERVICE_PRIMARY="productpage.${NAMESPACE}"
JAEGER_SERVICE_FALLBACK="productpage"
if [[ "${APP}" == "onlineboutique" ]]; then
  JAEGER_SERVICE_PRIMARY="frontend.${NAMESPACE}"
  JAEGER_SERVICE_FALLBACK="frontend"
fi

JAEGER_SERVICE="${JAEGER_SERVICE_PRIMARY}"
if ! curl -fsS "http://127.0.0.1:${JAEGER_PORT_LOCAL}/api/traces?service=${JAEGER_SERVICE_PRIMARY}&limit=20&lookback=1h" > "${JAEGER_TRACE_FILE}"; then
  write_error_json "${JAEGER_TRACE_FILE}" "query_failed"
fi

JAEGER_TRACES="$(python3 - <<'PY' "${JAEGER_TRACE_FILE}"
import json
import sys
try:
    doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
    print("NA")
    sys.exit(0)
if doc.get("status") == "error":
    print("NA")
    sys.exit(0)
print(len(doc.get("data", [])))
PY
)"
if [[ "${JAEGER_TRACES}" == "0" || "${JAEGER_TRACES}" == "NA" ]]; then
  JAEGER_SERVICE="${JAEGER_SERVICE_FALLBACK}"
  if ! curl -fsS "http://127.0.0.1:${JAEGER_PORT_LOCAL}/api/traces?service=${JAEGER_SERVICE_FALLBACK}&limit=20&lookback=1h" > "${JAEGER_TRACE_FILE}"; then
    write_error_json "${JAEGER_TRACE_FILE}" "query_failed"
  fi
  JAEGER_TRACES="$(python3 - <<'PY' "${JAEGER_TRACE_FILE}"
import json
import sys
try:
    doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
    print("NA")
    sys.exit(0)
if doc.get("status") == "error":
    print("NA")
    sys.exit(0)
print(len(doc.get("data", [])))
PY
)"
fi

python3 "${ROOT_DIR}/scripts/parse_fortio_output.py" "${FORTIO_LOG}" > "${LOAD_SUMMARY}"

python3 - <<'PY' \
  "${LOAD_SUMMARY}" \
  "${PROM_BEFORE_FILE}" \
  "${PROM_AFTER_FILE}" \
  "${JAEGER_TRACE_FILE}" \
  "${JOB_NAME}" \
  "${APP}" \
  "${NAMESPACE}" \
  "${RPS}" \
  "${DURATION}" \
  "${TARGET_URL}" \
  "${JAEGER_SERVICE}"
import json
import sys
from pathlib import Path

summary_path, prom_before_path, prom_after_path, jaeger_path, job_name, app, namespace, rps, duration, target_url, jaeger_service = sys.argv[1:12]

summary = json.loads(Path(summary_path).read_text(encoding="utf-8"))

def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return {"status": "error", "reason": "read_failed"}

def extract_scalar(doc):
    if doc.get("status") != "success":
        return None
    result = doc.get("data", {}).get("result", [])
    if not result:
        return None
    try:
        return float(result[0].get("value", ["", None])[1])
    except (TypeError, ValueError):
        return None

prom_before = load_json(prom_before_path)
prom_after = load_json(prom_after_path)
jaeger_doc = load_json(jaeger_path)
jaeger_count = None
if "data" in jaeger_doc and isinstance(jaeger_doc.get("data"), list):
    jaeger_count = len(jaeger_doc["data"])

summary.update(
    {
        "job_name": job_name,
        "app": app,
        "namespace": namespace,
        "requested_rps": int(rps),
        "requested_duration_seconds": int(duration),
        "target_url": target_url,
        "verification": {
            "prometheus_request_count_before": extract_scalar(prom_before),
            "prometheus_request_count_after": extract_scalar(prom_after),
            "jaeger_service": jaeger_service,
            "jaeger_trace_count_last_hour": jaeger_count,
            "prometheus_request_count_before_raw": prom_before_path,
            "prometheus_request_count_after_raw": prom_after_path,
            "jaeger_trace_query_raw": jaeger_path,
        },
    }
)

Path(summary_path).write_text(json.dumps(summary, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY

kill "${PROM_PF_PID}" "${JAEGER_PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

log "Load generation completed."
log "Artifacts:"
log "  - ${FORTIO_LOG}"
log "  - ${LOAD_SUMMARY}"
