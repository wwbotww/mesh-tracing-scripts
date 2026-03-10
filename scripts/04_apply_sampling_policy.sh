#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

POLICY=""
BUDGET="mid"
NAMESPACE="observability"
APP=""
APP_NAMESPACE="mesh-app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
LOG_FILE="${RESULTS_DIR}/sampling.log"
CM_NAME="otel-collector-config"
COLLECTOR_DEPLOY="otel-collector"
JAEGER_SERVICE="jaeger-query"

usage() {
  cat <<'EOF'
Usage: scripts/04_apply_sampling_policy.sh --policy baseline_head|baseline_tail|ours [--budget low|mid|high] [--namespace observability]
       [--app bookinfo|onlineboutique] [--app-namespace mesh-app]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy) POLICY="${2:-}"; shift 2 ;;
    --budget) BUDGET="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --app) APP="${2:-}"; shift 2 ;;
    --app-namespace) APP_NAMESPACE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ "${POLICY}" =~ ^(baseline_head|baseline_tail|ours)$ ]] || err "--policy must be baseline_head|baseline_tail|ours"
[[ "${BUDGET}" =~ ^(low|mid|high)$ ]] || err "--budget must be low|mid|high"

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
command -v python3 >/dev/null 2>&1 || err "python3 not found"

mkdir -p "${RESULTS_DIR}" || err "Failed to create results dir"
echo "==== $(date '+%Y-%m-%d %H:%M:%S') sampling switch ====" >> "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1
set -x

POLICY_FILE="${ROOT_DIR}/manifests/sampling/${POLICY}_${BUDGET}.yaml"
[[ -f "${POLICY_FILE}" ]] || err "Policy file not found: ${POLICY_FILE}"

log "Applying sampling policy ConfigMap for policy=${POLICY}, budget=${BUDGET}"
kubectl apply -n "${NAMESPACE}" -f "${POLICY_FILE}" || err "Failed to apply ${POLICY_FILE}"

log "Rolling restart collector deployment..."
kubectl -n "${NAMESPACE}" rollout restart deployment/"${COLLECTOR_DEPLOY}" || err "Failed to restart ${COLLECTOR_DEPLOY}"
kubectl -n "${NAMESPACE}" rollout status deployment/"${COLLECTOR_DEPLOY}" --timeout=240s || err "Collector rollout not ready"

log "Current effective config summary (${CM_NAME}.data.config.yaml):"
kubectl get configmap "${CM_NAME}" -n "${NAMESPACE}" -o go-template='{{index .data "config.yaml"}}' \
  | awk '
      /processors:/ {inproc=1}
      inproc==1 && /exporters:/ {inproc=0}
      inproc==1 {print}
    ' || err "Failed to print config summary"

log "Simple verification by Jaeger trace count (same traffic, switch budget low/mid/high and compare):"
kubectl -n "${NAMESPACE}" port-forward svc/"${JAEGER_SERVICE}" 16686:16686 >/tmp/sampling-jaeger-pf.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3

if [[ -z "${APP}" ]]; then
  if kubectl -n "${APP_NAMESPACE}" get deploy frontend >/dev/null 2>&1; then
    APP="onlineboutique"
  else
    APP="bookinfo"
  fi
fi

if [[ "${APP}" == "onlineboutique" ]]; then
  JAEGER_CANDIDATES=("frontend.${APP_NAMESPACE}" "frontend")
else
  JAEGER_CANDIDATES=("productpage.${APP_NAMESPACE}" "productpage")
fi

JAEGER_SERVICE_NAME="${JAEGER_CANDIDATES[0]}"
TRACE_CNT="NA"
for svc in "${JAEGER_CANDIDATES[@]}"; do
  cnt="$(curl -fsS "http://127.0.0.1:16686/api/traces?service=${svc}&lookback=15m&limit=200" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data", [])))' 2>/dev/null || echo "NA")"
  JAEGER_SERVICE_NAME="${svc}"
  TRACE_CNT="${cnt}"
  if [[ "${cnt}" != "NA" && "${cnt}" != "0" ]]; then
    break
  fi
done

echo "trace_count_last_15m(service=${JAEGER_SERVICE_NAME}, limit=200): ${TRACE_CNT}"
echo "check_command:"
echo "curl -fsS \"http://127.0.0.1:16686/api/traces?service=${JAEGER_SERVICE_NAME}&lookback=15m&limit=200\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get(\"data\", [])))'"
echo "expected: with same load pattern, low < mid < high (trace count or exported spans/sec)."

kill "${PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

log "Sampling policy applied successfully: policy=${POLICY}, budget=${BUDGET}, namespace=${NAMESPACE}"
log "Log file: ${LOG_FILE}"
