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
JAEGER_PORT_LOCAL="16688"
CANONICAL_POLICY=""
CANONICAL_BUDGET=""

usage() {
  cat <<'EOF'
Usage: scripts/04_apply_sampling_policy.sh --policy head|tail|my_policy|reference|no_tracing [--budget low|mid|high|medium] [--namespace observability]
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

normalize_policy() {
  case "$1" in
    baseline_head|head) echo "baseline_head" ;;
    baseline_tail|tail) echo "baseline_tail" ;;
    ours|my_policy) echo "my_policy" ;;
    reference) echo "reference" ;;
    no_tracing) echo "no_tracing" ;;
    *) return 1 ;;
  esac
}

normalize_budget() {
  case "$1" in
    low) echo "low" ;;
    mid|medium) echo "mid" ;;
    high) echo "high" ;;
    *) return 1 ;;
  esac
}

CANONICAL_POLICY="$(normalize_policy "${POLICY}" || true)"
CANONICAL_BUDGET="$(normalize_budget "${BUDGET}" || true)"
[[ -n "${CANONICAL_POLICY}" ]] || err "--policy must be baseline_head|baseline_tail|head|tail|my_policy|reference|no_tracing"
[[ -n "${CANONICAL_BUDGET}" ]] || err "--budget must be low|mid|medium|high"

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
command -v python3 >/dev/null 2>&1 || err "python3 not found"

mkdir -p "${RESULTS_DIR}" || err "Failed to create results dir"
echo "==== $(date '+%Y-%m-%d %H:%M:%S') sampling switch ====" >> "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1
set -x

apply_generated_policy() {
  local generated_policy="$1"
  local generated_budget="$2"
  local percentage="100"
  if [[ "${generated_policy}" != "reference" ]]; then
    case "${generated_budget}" in
      low) percentage="50" ;;
      mid) percentage="75" ;;
      high) percentage="100" ;;
    esac
  fi

  if [[ "${generated_policy}" == "reference" ]]; then
    kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CM_NAME}
  labels:
    sampling.policy: reference
    sampling.budget: ${generated_budget}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    processors:
      probabilistic_sampler:
        sampling_percentage: ${percentage}
      batch:
        timeout: 1s
    exporters:
      otlp/jaeger:
        endpoint: jaeger-collector.${NAMESPACE}.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: 0.0.0.0:8889
    service:
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [probabilistic_sampler, batch]
          exporters: [otlp/jaeger]
EOF
  else
    kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CM_NAME}
  labels:
    sampling.policy: no_tracing
    sampling.budget: ${generated_budget}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    processors:
      batch:
        timeout: 1s
    exporters:
      otlp/jaeger:
        endpoint: jaeger-collector.${NAMESPACE}.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: 0.0.0.0:8889
    service:
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/jaeger]
EOF
  fi
}

apply_my_policy() {
  local generated_budget="$1"
  local initial_profile="balanced"
  local latency_threshold="300"
  local fallback_percentage="10"
  local num_traces="30000"
  local expected_new_traces_per_sec="150"

  case "${generated_budget}" in
    low)
      initial_profile="conservative"
      latency_threshold="500"
      fallback_percentage="1"
      num_traces="10000"
      expected_new_traces_per_sec="50"
      ;;
    mid)
      initial_profile="balanced"
      latency_threshold="300"
      fallback_percentage="10"
      num_traces="30000"
      expected_new_traces_per_sec="150"
      ;;
    high)
      initial_profile="aggressive"
      latency_threshold="200"
      fallback_percentage="30"
      num_traces="80000"
      expected_new_traces_per_sec="300"
      ;;
  esac

  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CM_NAME}
  labels:
    sampling.policy: my_policy
    sampling.budget: ${generated_budget}
    sampling.mode: volatility_controller
    sampling.profile: ${initial_profile}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    processors:
      tail_sampling:
        decision_wait: 10s
        num_traces: ${num_traces}
        expected_new_traces_per_sec: ${expected_new_traces_per_sec}
        policies:
          - name: error-traces
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: high-latency
            type: latency
            latency:
              threshold_ms: ${latency_threshold}
          - name: fallback-probability
            type: probabilistic
            probabilistic:
              sampling_percentage: ${fallback_percentage}
      batch:
        timeout: 1s
    exporters:
      otlp/jaeger:
        endpoint: jaeger-collector.${NAMESPACE}.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: 0.0.0.0:8889
    service:
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [tail_sampling, batch]
          exporters: [otlp/jaeger]
EOF
}

if [[ "${CANONICAL_POLICY}" =~ ^(baseline_head|baseline_tail)$ ]]; then
  POLICY_FILE="${ROOT_DIR}/manifests/sampling/${CANONICAL_POLICY}_${CANONICAL_BUDGET}.yaml"
  [[ -f "${POLICY_FILE}" ]] || err "Policy file not found: ${POLICY_FILE}"
fi

log "Applying sampling policy ConfigMap for policy=${CANONICAL_POLICY}, budget=${CANONICAL_BUDGET}"
if [[ "${CANONICAL_POLICY}" =~ ^(baseline_head|baseline_tail)$ ]]; then
  kubectl apply -n "${NAMESPACE}" -f "${POLICY_FILE}" || err "Failed to apply ${POLICY_FILE}"
elif [[ "${CANONICAL_POLICY}" == "my_policy" ]]; then
  apply_my_policy "${CANONICAL_BUDGET}" || err "Failed to apply generated policy ${CANONICAL_POLICY}"
else
  apply_generated_policy "${CANONICAL_POLICY}" "${CANONICAL_BUDGET}" || err "Failed to apply generated policy ${CANONICAL_POLICY}"
fi

TELEMETRY_SAMPLING="100.0"
if [[ "${CANONICAL_POLICY}" == "no_tracing" ]]; then
  TELEMETRY_SAMPLING="0.0"
fi

kubectl apply -n "${APP_NAMESPACE}" -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: tracing-default
spec:
  tracing:
  - providers:
    - name: otel-tracing
    randomSamplingPercentage: ${TELEMETRY_SAMPLING}
EOF

log "Rolling restart collector deployment..."
# Retry rollout restart up to 4 times to handle transient API-server blips.
_rollout_ok=false
for _attempt in 1 2 3 4; do
  if kubectl -n "${NAMESPACE}" rollout restart deployment/"${COLLECTOR_DEPLOY}" 2>/dev/null; then
    _rollout_ok=true
    break
  fi
  warn "rollout restart failed (attempt ${_attempt}/4), retrying in 10s..."
  sleep 10
done
${_rollout_ok} || err "Failed to restart ${COLLECTOR_DEPLOY} after retries"
# Wait for rollout with retry (API server may blip during rollout status polling).
_status_ok=false
for _attempt in 1 2 3; do
  if kubectl -n "${NAMESPACE}" rollout status deployment/"${COLLECTOR_DEPLOY}" --timeout=120s 2>/dev/null; then
    _status_ok=true
    break
  fi
  warn "rollout status check failed (attempt ${_attempt}/3), retrying in 10s..."
  sleep 10
done
${_status_ok} || err "Collector rollout not ready after retries"

log "Current effective config summary (${CM_NAME}.data.config.yaml):"
kubectl get configmap "${CM_NAME}" -n "${NAMESPACE}" -o go-template='{{index .data "config.yaml"}}' \
  | awk '
      /processors:/ {inproc=1}
      inproc==1 && /exporters:/ {inproc=0}
      inproc==1 {print}
    ' || err "Failed to print config summary"

echo "telemetry_sampling_percentage: ${TELEMETRY_SAMPLING}"

log "Simple verification by Jaeger trace count (same traffic, switch budget low/mid/high and compare):"
kubectl -n "${NAMESPACE}" port-forward svc/"${JAEGER_SERVICE}" "${JAEGER_PORT_LOCAL}:16686" >/tmp/sampling-jaeger-pf.log 2>&1 &
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
  cnt="$(curl -fsS "http://127.0.0.1:${JAEGER_PORT_LOCAL}/api/traces?service=${svc}&lookback=15m&limit=200" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data", [])))' 2>/dev/null || echo "NA")"
  JAEGER_SERVICE_NAME="${svc}"
  TRACE_CNT="${cnt}"
  if [[ "${cnt}" != "NA" && "${cnt}" != "0" ]]; then
    break
  fi
done

echo "trace_count_last_15m(service=${JAEGER_SERVICE_NAME}, limit=200): ${TRACE_CNT}"
echo "check_command:"
echo "curl -fsS \"http://127.0.0.1:${JAEGER_PORT_LOCAL}/api/traces?service=${JAEGER_SERVICE_NAME}&lookback=15m&limit=200\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get(\"data\", [])))'"
if [[ "${CANONICAL_POLICY}" == "no_tracing" ]]; then
  echo "expected: trace count should stay close to zero because Telemetry sampling is set to 0.0."
elif [[ "${CANONICAL_POLICY}" == "my_policy" ]]; then
  echo "expected: initial profile follows budget, then the external controller may adjust tail-sampling parameters during the run."
else
  echo "expected: with same load pattern, low < mid < high (trace count or exported spans/sec)."
fi

kill "${PF_PID}" >/dev/null 2>&1 || true
trap - EXIT

log "Sampling policy applied successfully: policy=${CANONICAL_POLICY}, budget=${CANONICAL_BUDGET}, namespace=${NAMESPACE}"
log "Log file: ${LOG_FILE}"
