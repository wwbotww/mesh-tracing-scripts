#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

FAULT=""
TARGET_SERVICE=""
SOURCE_SERVICE=""
NAMESPACE="mesh-app"
OBS_NAMESPACE="observability"
PROM_SERVICE="obs-kube-prometheus-stack-prometheus"
FIXED_DELAY_MS="200"
HTTP_STATUS="500"
PERCENTAGE="10"
APPLY=false
CLEAR=false
TARGET_URL=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
LOG_FILE="${RESULTS_DIR}/fault.log"
FAULT_NAME=""

usage() {
  cat <<'EOF'
Usage:
  Apply delay fault:
    scripts/05_inject_fault.sh --apply --fault delay --target_service reviews [--source_service productpage] [--fixed_delay_ms 200] [--percentage 100] [--namespace mesh-app]

  Apply abort fault:
    scripts/05_inject_fault.sh --apply --fault abort --target_service reviews [--source_service productpage] [--http_status 500] [--percentage 10] [--namespace mesh-app]

  Clear fault:
    scripts/05_inject_fault.sh --clear --fault delay|abort --target_service reviews [--source_service productpage] [--namespace mesh-app]
EOF
}

sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}

render_template() {
  local template="$1"
  local out="$2"
  sed \
    -e "s#__FAULT_NAME__#${FAULT_NAME}#g" \
    -e "s#__TARGET_SERVICE__#${TARGET_SERVICE}#g" \
    -e "s#__SOURCE_SERVICE__#${SOURCE_SERVICE}#g" \
    -e "s#__FIXED_DELAY_MS__#${FIXED_DELAY_MS}#g" \
    -e "s#__HTTP_STATUS__#${HTTP_STATUS}#g" \
    -e "s#__PERCENTAGE__#${PERCENTAGE}#g" \
    "${template}" > "${out}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fault) FAULT="${2:-}"; shift 2 ;;
    --target_service) TARGET_SERVICE="${2:-}"; shift 2 ;;
    --source_service) SOURCE_SERVICE="${2:-}"; shift 2 ;;
    --fixed_delay_ms) FIXED_DELAY_MS="${2:-}"; shift 2 ;;
    --http_status) HTTP_STATUS="${2:-}"; shift 2 ;;
    --percentage) PERCENTAGE="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --obs-namespace) OBS_NAMESPACE="${2:-}"; shift 2 ;;
    --prom-service) PROM_SERVICE="${2:-}"; shift 2 ;;
    --target_url|--url) TARGET_URL="${2:-}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --clear) CLEAR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ "${FAULT}" =~ ^(delay|abort)$ ]] || err "--fault must be delay|abort"
[[ -n "${TARGET_SERVICE}" ]] || err "--target_service is required"
[[ "${APPLY}" == true || "${CLEAR}" == true ]] || err "One action is required: --apply or --clear"
[[ ! ("${APPLY}" == true && "${CLEAR}" == true) ]] || err "--apply and --clear cannot be used together"
[[ "${FIXED_DELAY_MS}" =~ ^[0-9]+$ ]] || err "--fixed_delay_ms must be integer ms"
[[ "${HTTP_STATUS}" =~ ^[1-5][0-9][0-9]$ ]] || err "--http_status must be a valid HTTP code"
[[ "${PERCENTAGE}" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || err "--percentage must be 0..100"

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
mkdir -p "${RESULTS_DIR}" || err "Failed to create results directory"

FAULT_NAME="fault-${FAULT}-$(sanitize_name "${SOURCE_SERVICE:-any}")-to-$(sanitize_name "${TARGET_SERVICE}")"
echo "==== $(date '+%Y-%m-%d %H:%M:%S') fault operation ====" >> "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1
set -x

kubectl get svc "${TARGET_SERVICE}" -n "${NAMESPACE}" >/dev/null 2>&1 || err "Target service not found: ${TARGET_SERVICE} in ns=${NAMESPACE}"

if [[ -n "${SOURCE_SERVICE}" ]]; then
  kubectl get deploy "${SOURCE_SERVICE}" -n "${NAMESPACE}" >/dev/null 2>&1 || warn "Source deploy ${SOURCE_SERVICE} not found; fault will still apply by sourceLabels matching app=${SOURCE_SERVICE}"
fi

if [[ -z "${TARGET_URL}" ]]; then
  if [[ "${SOURCE_SERVICE}" == "productpage" || "${TARGET_SERVICE}" == "reviews" ]]; then
    TARGET_URL="http://productpage.${NAMESPACE}.svc.cluster.local:9080/productpage"
  else
    TARGET_URL="http://${TARGET_SERVICE}.${NAMESPACE}.svc.cluster.local/"
  fi
fi

before_p95="NA"
before_err="NA"

kubectl -n "${OBS_NAMESPACE}" port-forward svc/"${PROM_SERVICE}" 9090:9090 >/tmp/fault-prom-pf.log 2>&1 &
PROM_PF_PID=$!
trap 'kill ${PROM_PF_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3

query_prom() {
  local query="$1"
  curl -fsS --get "http://127.0.0.1:9090/api/v1/query" --data-urlencode "query=${query}" || return 1
}

extract_prom_value() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "NA")'
}

if p95_json="$(query_prom "histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_service_name=\"${TARGET_SERVICE}\"}[2m])) by (le))" 2>/dev/null || true)"; then
  before_p95="$(printf "%s" "${p95_json}" | extract_prom_value 2>/dev/null || echo "NA")"
fi
if err_json="$(query_prom "sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\",response_code=~\"5..\"}[2m])) / clamp_min(sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\"}[2m])), 0.0001)" 2>/dev/null || true)"; then
  before_err="$(printf "%s" "${err_json}" | extract_prom_value 2>/dev/null || echo "NA")"
fi

if [[ "${APPLY}" == true ]]; then
  if [[ -z "${SOURCE_SERVICE}" ]]; then
    if [[ "${FAULT}" == "delay" ]]; then
      kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${FAULT_NAME}
  labels:
    app.kubernetes.io/managed-by: trace-exp
    fault.type: delay
spec:
  hosts:
  - ${TARGET_SERVICE}
  http:
  - fault:
      delay:
        fixedDelay: "${FIXED_DELAY_MS}ms"
        percentage:
          value: ${PERCENTAGE}
    route:
    - destination:
        host: ${TARGET_SERVICE}
EOF
    else
      kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${FAULT_NAME}
  labels:
    app.kubernetes.io/managed-by: trace-exp
    fault.type: abort
spec:
  hosts:
  - ${TARGET_SERVICE}
  http:
  - fault:
      abort:
        httpStatus: ${HTTP_STATUS}
        percentage:
          value: ${PERCENTAGE}
    route:
    - destination:
        host: ${TARGET_SERVICE}
EOF
    fi
  else
    template_file=""
    if [[ "${FAULT}" == "delay" ]]; then
      template_file="${ROOT_DIR}/manifests/faults/delay-template.yaml"
    else
      template_file="${ROOT_DIR}/manifests/faults/abort-template.yaml"
    fi
    [[ -f "${template_file}" ]] || err "Template not found: ${template_file}"
    tmp_render="$(mktemp)"
    render_template "${template_file}" "${tmp_render}"
    kubectl apply -n "${NAMESPACE}" -f "${tmp_render}" || err "Failed to apply fault manifest"
    rm -f "${tmp_render}"
  fi
  kubectl get virtualservice "${FAULT_NAME}" -n "${NAMESPACE}" || err "Fault VirtualService not found after apply"
else
  kubectl delete virtualservice "${FAULT_NAME}" -n "${NAMESPACE}" --ignore-not-found
fi

sleep 20

after_p95="NA"
after_err="NA"
if p95_json2="$(query_prom "histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_service_name=\"${TARGET_SERVICE}\"}[2m])) by (le))" 2>/dev/null || true)"; then
  after_p95="$(printf "%s" "${p95_json2}" | extract_prom_value 2>/dev/null || echo "NA")"
fi
if err_json2="$(query_prom "sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\",response_code=~\"5..\"}[2m])) / clamp_min(sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\"}[2m])), 0.0001)" 2>/dev/null || true)"; then
  after_err="$(printf "%s" "${err_json2}" | extract_prom_value 2>/dev/null || echo "NA")"
fi

log "Simple runtime check via curl (inside cluster DNS): ${TARGET_URL}"
ok=0
fail=0
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${TARGET_URL}" || true)"
  if [[ "${code}" =~ ^2|3|4 ]]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done

echo "Fault action: $([[ "${APPLY}" == true ]] && echo apply || echo clear)"
echo "Fault name: ${FAULT_NAME}"
echo "Fault type: ${FAULT}"
echo "Namespace: ${NAMESPACE}"
echo "Source service: ${SOURCE_SERVICE:-any}"
echo "Target service: ${TARGET_SERVICE}"
echo "Prometheus P95 before/after: ${before_p95} -> ${after_p95}"
echo "Prometheus error_rate before/after: ${before_err} -> ${after_err}"
echo "Curl success/fail (20 req): ${ok}/${fail}"
echo "Prometheus query (P95): histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_service_name=\"${TARGET_SERVICE}\"}[2m])) by (le))"
echo "Prometheus query (error rate): sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\",response_code=~\"5..\"}[2m])) / clamp_min(sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\"}[2m])), 0.0001)"

kill "${PROM_PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

log "Fault operation completed. Log file: ${LOG_FILE}"
