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
PROM_PORT_LOCAL="19092"
FIXED_DELAY_MS="200"
HTTP_STATUS="500"
PERCENTAGE="10"
APPLY=false
CLEAR=false
TARGET_URL=""
OUTPUT_DIR=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
LOG_FILE="${RESULTS_DIR}/fault.log"
FAULT_NAME=""
FAULT_DIR=""
ACTION=""

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
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
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
command -v python3 >/dev/null 2>&1 || err "python3 not found"
mkdir -p "${RESULTS_DIR}" || err "Failed to create results directory"

FAULT_NAME="fault-${FAULT}-$(sanitize_name "${SOURCE_SERVICE:-any}")-to-$(sanitize_name "${TARGET_SERVICE}")"
ACTION="$([[ "${APPLY}" == true ]] && echo apply || echo clear)"
echo "==== $(date '+%Y-%m-%d %H:%M:%S') fault operation ====" >> "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1
set -x

if [[ -n "${OUTPUT_DIR}" ]]; then
  case "${OUTPUT_DIR}" in
    /*) FAULT_DIR="${OUTPUT_DIR}/fault" ;;
    *) FAULT_DIR="${ROOT_DIR}/${OUTPUT_DIR}/fault" ;;
  esac
  mkdir -p "${FAULT_DIR}" || err "Failed to create fault output dir"
fi

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

kubectl -n "${OBS_NAMESPACE}" port-forward svc/"${PROM_SERVICE}" "${PROM_PORT_LOCAL}:9090" >/tmp/fault-prom-pf.log 2>&1 &
PROM_PF_PID=$!
trap 'kill ${PROM_PF_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3

query_prom() {
  local query="$1"
  curl -fsS --get "http://127.0.0.1:${PROM_PORT_LOCAL}/api/v1/query" --data-urlencode "query=${query}" || return 1
}

extract_prom_value() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "NA")'
}

P95_QUERY="histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_service_name=\"${TARGET_SERVICE}\"}[2m])) by (le))"
ERR_QUERY="sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\",response_code=~\"5..\"}[2m])) / clamp_min(sum(rate(istio_requests_total{destination_service_name=\"${TARGET_SERVICE}\"}[2m])), 0.0001)"

BEFORE_P95_FILE=""
BEFORE_ERR_FILE=""
AFTER_P95_FILE=""
AFTER_ERR_FILE=""
RENDERED_FILE=""
if [[ -n "${FAULT_DIR}" ]]; then
  BEFORE_P95_FILE="${FAULT_DIR}/${ACTION}_before_p95.json"
  BEFORE_ERR_FILE="${FAULT_DIR}/${ACTION}_before_error_rate.json"
  AFTER_P95_FILE="${FAULT_DIR}/${ACTION}_after_p95.json"
  AFTER_ERR_FILE="${FAULT_DIR}/${ACTION}_after_error_rate.json"
  RENDERED_FILE="${FAULT_DIR}/${ACTION}_${FAULT_NAME}.yaml"
fi

if p95_json="$(query_prom "${P95_QUERY}" 2>/dev/null || true)"; then
  before_p95="$(printf "%s" "${p95_json}" | extract_prom_value 2>/dev/null || echo "NA")"
  [[ -n "${BEFORE_P95_FILE}" ]] && printf "%s\n" "${p95_json}" > "${BEFORE_P95_FILE}"
elif [[ -n "${BEFORE_P95_FILE}" ]]; then
  write_error_json "${BEFORE_P95_FILE}" "query_failed"
fi
if err_json="$(query_prom "${ERR_QUERY}" 2>/dev/null || true)"; then
  before_err="$(printf "%s" "${err_json}" | extract_prom_value 2>/dev/null || echo "NA")"
  [[ -n "${BEFORE_ERR_FILE}" ]] && printf "%s\n" "${err_json}" > "${BEFORE_ERR_FILE}"
elif [[ -n "${BEFORE_ERR_FILE}" ]]; then
  write_error_json "${BEFORE_ERR_FILE}" "query_failed"
fi

if [[ "${APPLY}" == true ]]; then
  if [[ -z "${SOURCE_SERVICE}" ]]; then
    if [[ "${FAULT}" == "delay" ]]; then
      if [[ -n "${RENDERED_FILE}" ]]; then
        cat > "${RENDERED_FILE}" <<EOF
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
        kubectl apply -n "${NAMESPACE}" -f "${RENDERED_FILE}"
      else
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
      fi
    else
      if [[ -n "${RENDERED_FILE}" ]]; then
        cat > "${RENDERED_FILE}" <<EOF
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
        kubectl apply -n "${NAMESPACE}" -f "${RENDERED_FILE}"
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
    if [[ -n "${RENDERED_FILE}" ]]; then
      cp "${tmp_render}" "${RENDERED_FILE}"
      kubectl apply -n "${NAMESPACE}" -f "${RENDERED_FILE}" || err "Failed to apply fault manifest"
    else
      kubectl apply -n "${NAMESPACE}" -f "${tmp_render}" || err "Failed to apply fault manifest"
    fi
    rm -f "${tmp_render}"
  fi
  kubectl get virtualservice "${FAULT_NAME}" -n "${NAMESPACE}" || err "Fault VirtualService not found after apply"
else
  kubectl delete virtualservice "${FAULT_NAME}" -n "${NAMESPACE}" --ignore-not-found
fi

sleep 20

after_p95="NA"
after_err="NA"
if p95_json2="$(query_prom "${P95_QUERY}" 2>/dev/null || true)"; then
  after_p95="$(printf "%s" "${p95_json2}" | extract_prom_value 2>/dev/null || echo "NA")"
  [[ -n "${AFTER_P95_FILE}" ]] && printf "%s\n" "${p95_json2}" > "${AFTER_P95_FILE}"
elif [[ -n "${AFTER_P95_FILE}" ]]; then
  write_error_json "${AFTER_P95_FILE}" "query_failed"
fi
if err_json2="$(query_prom "${ERR_QUERY}" 2>/dev/null || true)"; then
  after_err="$(printf "%s" "${err_json2}" | extract_prom_value 2>/dev/null || echo "NA")"
  [[ -n "${AFTER_ERR_FILE}" ]] && printf "%s\n" "${err_json2}" > "${AFTER_ERR_FILE}"
elif [[ -n "${AFTER_ERR_FILE}" ]]; then
  write_error_json "${AFTER_ERR_FILE}" "query_failed"
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
echo "Prometheus query (P95): ${P95_QUERY}"
echo "Prometheus query (error rate): ${ERR_QUERY}"

if [[ -n "${FAULT_DIR}" ]]; then
  python3 - <<'PY' \
    "${FAULT_DIR}/${ACTION}_summary.json" \
    "${FAULT_NAME}" \
    "${ACTION}" \
    "${FAULT}" \
    "${NAMESPACE}" \
    "${SOURCE_SERVICE}" \
    "${TARGET_SERVICE}" \
    "${FIXED_DELAY_MS}" \
    "${HTTP_STATUS}" \
    "${PERCENTAGE}" \
    "${TARGET_URL}" \
    "${before_p95}" \
    "${after_p95}" \
    "${before_err}" \
    "${after_err}" \
    "${ok}" \
    "${fail}" \
    "${P95_QUERY}" \
    "${ERR_QUERY}" \
    "${BEFORE_P95_FILE}" \
    "${AFTER_P95_FILE}" \
    "${BEFORE_ERR_FILE}" \
    "${AFTER_ERR_FILE}" \
    "${RENDERED_FILE}"
import json
import sys
from pathlib import Path

(
    output_path,
    fault_name,
    action,
    fault_type,
    namespace,
    source_service,
    target_service,
    fixed_delay_ms,
    http_status,
    percentage,
    target_url,
    before_p95,
    after_p95,
    before_err,
    after_err,
    ok,
    fail,
    p95_query,
    err_query,
    before_p95_file,
    after_p95_file,
    before_err_file,
    after_err_file,
    rendered_file,
) = sys.argv[1:25]

def maybe_float(value):
    try:
        return float(value)
    except ValueError:
        return None

doc = {
    "fault_name": fault_name,
    "action": action,
    "fault_type": fault_type,
    "namespace": namespace,
    "source_service": source_service or None,
    "target_service": target_service,
    "target_url": target_url,
    "parameters": {
        "fixed_delay_ms": int(fixed_delay_ms),
        "http_status": int(http_status),
        "percentage": int(percentage),
    },
    "prometheus": {
        "p95_query": p95_query,
        "error_rate_query": err_query,
        "p95_before": maybe_float(before_p95),
        "p95_after": maybe_float(after_p95),
        "error_rate_before": maybe_float(before_err),
        "error_rate_after": maybe_float(after_err),
        "p95_before_raw": before_p95_file or None,
        "p95_after_raw": after_p95_file or None,
        "error_rate_before_raw": before_err_file or None,
        "error_rate_after_raw": after_err_file or None,
    },
    "curl_check": {
        "success_count": int(ok),
        "failure_count": int(fail),
    },
    "rendered_manifest": rendered_file or None,
}
Path(output_path).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
fi

kill "${PROM_PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

log "Fault operation completed. Log file: ${LOG_FILE}"
