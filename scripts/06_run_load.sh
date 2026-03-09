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
RPS="50"
DURATION="300"
TARGET_URL=""
JOB_NAME="loadgen"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
REPORT_JSON="${RESULTS_DIR}/load_report.json"
REPORT_TXT="${RESULTS_DIR}/load_report.txt"
PROM_BEFORE="NA"
PROM_AFTER="NA"
JAEGER_TRACES="NA"

usage() {
  cat <<'EOF'
Usage: scripts/06_run_load.sh [--app bookinfo|onlineboutique] [--rps 50|200|500] [--duration 300] [--target_url http://...] [--namespace mesh-app]
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
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ "${APP}" =~ ^(bookinfo|onlineboutique)$ ]] || err "--app must be bookinfo|onlineboutique"
[[ "${RPS}" =~ ^(50|200|500)$ ]] || err "--rps must be 50|200|500"
[[ "${DURATION}" =~ ^[0-9]+$ ]] || err "--duration must be seconds (integer)"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
mkdir -p "${RESULTS_DIR}" || err "Failed to create results directory"

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

if [[ -z "${TARGET_URL}" ]]; then
  TARGET_URL="$(detect_target_url || true)"
fi
[[ -n "${TARGET_URL}" ]] || err "Cannot auto-detect --target_url; please provide it explicitly."

log "Load test config: app=${APP}, rps=${RPS}, duration=${DURATION}s, target=${TARGET_URL}"

prom_query() {
  local query="$1"
  curl -fsS --get "http://127.0.0.1:9090/api/v1/query" --data-urlencode "query=${query}" || return 1
}

log "Querying baseline request counter from Prometheus (if reachable)..."
kubectl -n "${OBS_NAMESPACE}" port-forward svc/"${PROM_SVC}" 9090:9090 >/tmp/load-prom-pf.log 2>&1 &
PROM_PF_PID=$!
trap 'kill ${PROM_PF_PID:-} ${JAEGER_PF_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3
if BEFORE_JSON="$(prom_query "sum(istio_requests_total)" 2>/dev/null || true)"; then
  PROM_BEFORE="$(python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "0")' <<< "${BEFORE_JSON}" 2>/dev/null || echo "NA")"
fi

log "Creating/replacing Fortio job ${JOB_NAME} for ${APP}..."
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  template:
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
        - -json
        - "-"
        - "${TARGET_URL}"
EOF

log "Validation: waiting job completion..."
kubectl wait --for=condition=complete job/"${JOB_NAME}" -n "${NAMESPACE}" --timeout="$((DURATION + 240))s" || err "Load job did not complete in time"

JOB_LOGS="$(kubectl logs job/"${JOB_NAME}" -n "${NAMESPACE}" || true)"
[[ -n "${JOB_LOGS}" ]] || err "Failed to get load job logs"
printf "%s\n" "${JOB_LOGS}" > "${REPORT_TXT}"

printf "%s\n" "${JOB_LOGS}" > "${REPORT_JSON}"

log "Checking Prometheus counter growth..."
sleep 15
if AFTER_JSON="$(prom_query "sum(istio_requests_total)" 2>/dev/null || true)"; then
  PROM_AFTER="$(python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "0")' <<< "${AFTER_JSON}" 2>/dev/null || echo "NA")"
fi

log "Checking Jaeger traces presence..."
kubectl -n "${OBS_NAMESPACE}" port-forward svc/"${JAEGER_SVC}" 16686:16686 >/tmp/load-jaeger-pf.log 2>&1 &
JAEGER_PF_PID=$!
sleep 3
JAEGER_SERVICE_PRIMARY="productpage.mesh-app"
JAEGER_SERVICE_FALLBACK="productpage"
if [[ "${APP}" == "onlineboutique" ]]; then
  JAEGER_SERVICE_PRIMARY="frontend.mesh-app"
  JAEGER_SERVICE_FALLBACK="frontend"
fi
JAEGER_SERVICE="${JAEGER_SERVICE_PRIMARY}"
JAEGER_RESP="$(curl -fsS "http://127.0.0.1:16686/api/traces?service=${JAEGER_SERVICE_PRIMARY}&limit=20&lookback=1h" || true)"
if [[ -n "${JAEGER_RESP}" ]]; then
  JAEGER_TRACES="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data",[])))' <<< "${JAEGER_RESP}" 2>/dev/null || echo "NA")"
fi
if [[ "${JAEGER_TRACES}" == "0" || "${JAEGER_TRACES}" == "NA" ]]; then
  JAEGER_SERVICE="${JAEGER_SERVICE_FALLBACK}"
  JAEGER_RESP="$(curl -fsS "http://127.0.0.1:16686/api/traces?service=${JAEGER_SERVICE_FALLBACK}&limit=20&lookback=1h" || true)"
  if [[ -n "${JAEGER_RESP}" ]]; then
    JAEGER_TRACES="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data",[])))' <<< "${JAEGER_RESP}" 2>/dev/null || echo "NA")"
  fi
fi

{
  echo
  echo "==== QUICK VERIFICATION ===="
  echo "Prometheus sum(istio_requests_total) before: ${PROM_BEFORE}"
  echo "Prometheus sum(istio_requests_total) after : ${PROM_AFTER}"
  echo "Jaeger traces for service=${JAEGER_SERVICE}: ${JAEGER_TRACES}"
  echo
  echo "Prometheus query command:"
  echo "curl -G \"http://127.0.0.1:9090/api/v1/query\" --data-urlencode 'query=sum(istio_requests_total)'"
  echo "Jaeger query command:"
  echo "curl \"http://127.0.0.1:16686/api/traces?service=${JAEGER_SERVICE}&limit=20&lookback=1h\""
} >> "${REPORT_TXT}"

kill "${PROM_PF_PID}" "${JAEGER_PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

log "Load generation completed."
log "Reports:"
log "  - ${REPORT_JSON}"
log "  - ${REPORT_TXT}"
