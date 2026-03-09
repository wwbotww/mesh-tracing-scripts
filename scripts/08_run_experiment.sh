#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
DRIVER_LOG="${RESULTS_DIR}/exp_driver.log"

APP=""
POLICY=""
BUDGET=""
FAULT="none"
TARGET=""
RPS=""
DURATION=""

APP_NS="mesh-app"
OBS_NS="observability"
ISTIO_NS="istio-system"

TARGET_URL=""
FIXED_DELAY_MS="200"
HTTP_STATUS="500"
PERCENTAGE="10"

FAULT_APPLIED=false
SOURCE_SERVICE=""
TARGET_SERVICE=""
OUTPUT_DIR=""
LOAD_JOB_NAME=""

usage() {
  cat <<'EOF'
Usage:
  scripts/08_run_experiment.sh \
    --app bookinfo|onlineboutique \
    --policy baseline_head|baseline_tail|ours \
    --budget low|mid|high \
    --fault none|delay|abort \
    --target <service|source->service|/route> \
    --rps <int> \
    --duration <sec>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --policy) POLICY="${2:-}"; shift 2 ;;
    --budget) BUDGET="${2:-}"; shift 2 ;;
    --fault) FAULT="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --rps) RPS="${2:-}"; shift 2 ;;
    --duration) DURATION="${2:-}"; shift 2 ;;
    --target_url|--target-url) TARGET_URL="${2:-}"; shift 2 ;;
    --fixed_delay_ms) FIXED_DELAY_MS="${2:-}"; shift 2 ;;
    --http_status) HTTP_STATUS="${2:-}"; shift 2 ;;
    --percentage) PERCENTAGE="${2:-}"; shift 2 ;;
    --app-namespace) APP_NS="${2:-}"; shift 2 ;;
    --obs-namespace) OBS_NS="${2:-}"; shift 2 ;;
    --istio-namespace) ISTIO_NS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ "${APP}" =~ ^(bookinfo|onlineboutique)$ ]] || err "--app must be bookinfo|onlineboutique"
[[ "${POLICY}" =~ ^(baseline_head|baseline_tail|ours)$ ]] || err "--policy must be baseline_head|baseline_tail|ours"
[[ "${BUDGET}" =~ ^(low|mid|high)$ ]] || err "--budget must be low|mid|high"
[[ "${FAULT}" =~ ^(none|delay|abort)$ ]] || err "--fault must be none|delay|abort"
[[ -n "${TARGET}" ]] || err "--target is required"
[[ "${RPS}" =~ ^[0-9]+$ ]] || err "--rps must be int"
[[ "${DURATION}" =~ ^[0-9]+$ ]] || err "--duration must be int seconds"
[[ "${FIXED_DELAY_MS}" =~ ^[0-9]+$ ]] || err "--fixed_delay_ms must be int"
[[ "${HTTP_STATUS}" =~ ^[1-5][0-9][0-9]$ ]] || err "--http_status must be http code"
[[ "${PERCENTAGE}" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || err "--percentage must be 0..100"

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
command -v minikube >/dev/null 2>&1 || warn "minikube not found, will try ingress LB for URL detection"

mkdir -p "${RESULTS_DIR}" || err "Failed to create results dir"
echo "==== $(date '+%Y-%m-%d %H:%M:%S') experiment run ====" >> "${DRIVER_LOG}"
exec > >(tee -a "${DRIVER_LOG}") 2>&1
set -x

detect_target_url() {
  local path="/"
  [[ "${APP}" == "bookinfo" ]] && path="/productpage"

  if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
    local ip nodeport
    ip="$(minikube ip || true)"
    nodeport="$(kubectl -n "${ISTIO_NS}" get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' || true)"
    if [[ -n "${ip}" && -n "${nodeport}" ]]; then
      echo "http://${ip}:${nodeport}${path}"
      return 0
    fi
  fi

  local lbip port
  lbip="$(kubectl -n "${ISTIO_NS}" get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || true)"
  port="$(kubectl -n "${ISTIO_NS}" get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}' || true)"
  if [[ -n "${lbip}" && -n "${port}" ]]; then
    echo "http://${lbip}:${port}${path}"
    return 0
  fi
  return 1
}

ensure_prereq() {
  bash "${ROOT_DIR}/scripts/00_prereq_check.sh"
}

ensure_istio() {
  if ! kubectl -n "${ISTIO_NS}" get deploy istiod >/dev/null 2>&1; then
    log "Istio not detected, installing..."
    bash "${ROOT_DIR}/scripts/01_install_istio.sh" --profile demo --namespace "${ISTIO_NS}"
  fi
}

ensure_app() {
  local key_deploy="productpage"
  [[ "${APP}" == "onlineboutique" ]] && key_deploy="frontend"
  if ! kubectl -n "${APP_NS}" get deploy "${key_deploy}" >/dev/null 2>&1; then
    log "App ${APP} not detected, deploying..."
    bash "${ROOT_DIR}/scripts/02_deploy_app.sh" --app "${APP}" --namespace "${APP_NS}"
  fi
}

ensure_observability() {
  if ! kubectl -n "${OBS_NS}" get deploy otel-collector >/dev/null 2>&1; then
    log "Observability stack not detected, installing..."
    bash "${ROOT_DIR}/scripts/03_install_observability.sh" --namespace "${OBS_NS}" --app-namespace "${APP_NS}"
  fi
}

parse_target() {
  if [[ "${TARGET}" == *"->"* ]]; then
    SOURCE_SERVICE="${TARGET%%->*}"
    TARGET_SERVICE="${TARGET##*->}"
  elif [[ "${TARGET}" == /* ]]; then
    SOURCE_SERVICE=""
    if [[ "${APP}" == "bookinfo" ]]; then
      TARGET_SERVICE="reviews"
    else
      TARGET_SERVICE="frontend"
    fi
    warn "--target looked like route (${TARGET}); using target service=${TARGET_SERVICE} for fault injection."
  else
    SOURCE_SERVICE=""
    TARGET_SERVICE="${TARGET}"
  fi
}

cleanup_fault() {
  if [[ "${FAULT_APPLIED}" == true ]]; then
    bash "${ROOT_DIR}/scripts/05_inject_fault.sh" --clear --fault "${FAULT}" --target_service "${TARGET_SERVICE}" \
      ${SOURCE_SERVICE:+--source_service "${SOURCE_SERVICE}"} \
      --namespace "${APP_NS}" --obs-namespace "${OBS_NS}" || true
  fi
}

trap cleanup_fault EXIT

ensure_prereq
ensure_istio
ensure_app
ensure_observability

parse_target

# 2) Apply sampling policy
bash "${ROOT_DIR}/scripts/04_apply_sampling_policy.sh" --policy "${POLICY}" --budget "${BUDGET}" --namespace "${OBS_NS}"

# 3) Start load + warmup
if [[ -z "${TARGET_URL}" ]]; then
  TARGET_URL="$(detect_target_url || true)"
fi
[[ -n "${TARGET_URL}" ]] || err "Unable to resolve load target URL, please pass --target_url"

WARMUP_SEC=60
FAULT_PHASE_SEC=$(( DURATION * 60 / 100 ))
FAULT_START_AFTER_WARMUP=$(( DURATION * 20 / 100 ))
TOTAL_LOAD_SEC=$(( WARMUP_SEC + DURATION ))
LOAD_JOB_NAME="loadgen-exp-$(date +%H%M%S)"

kubectl delete job "${LOAD_JOB_NAME}" -n "${APP_NS}" --ignore-not-found
kubectl apply -n "${APP_NS}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${LOAD_JOB_NAME}
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
        - "${TOTAL_LOAD_SEC}s"
        - -H
        - "x-b3-sampled: 1"
        - -H
        - "x-envoy-force-trace: true"
        - "${TARGET_URL}"
EOF

sleep "${WARMUP_SEC}"
sleep "${FAULT_START_AFTER_WARMUP}"

# 4) Inject fault for middle 60% of duration
if [[ "${FAULT}" != "none" ]]; then
  bash "${ROOT_DIR}/scripts/05_inject_fault.sh" --apply --fault "${FAULT}" --target_service "${TARGET_SERVICE}" \
    ${SOURCE_SERVICE:+--source_service "${SOURCE_SERVICE}"} \
    --fixed_delay_ms "${FIXED_DELAY_MS}" --http_status "${HTTP_STATUS}" --percentage "${PERCENTAGE}" \
    --namespace "${APP_NS}" --obs-namespace "${OBS_NS}" --target_url "${TARGET_URL}"
  FAULT_APPLIED=true
  sleep "${FAULT_PHASE_SEC}"
  bash "${ROOT_DIR}/scripts/05_inject_fault.sh" --clear --fault "${FAULT}" --target_service "${TARGET_SERVICE}" \
    ${SOURCE_SERVICE:+--source_service "${SOURCE_SERVICE}"} \
    --namespace "${APP_NS}" --obs-namespace "${OBS_NS}" --target_url "${TARGET_URL}"
  FAULT_APPLIED=false
fi

# 5) End load (wait complete) and clear fault already handled
kubectl wait --for=condition=complete job/"${LOAD_JOB_NAME}" -n "${APP_NS}" --timeout="$((TOTAL_LOAD_SEC + 300))s" \
  || err "Load job did not complete"
kubectl logs job/"${LOAD_JOB_NAME}" -n "${APP_NS}" > "${RESULTS_DIR}/load_${LOAD_JOB_NAME}.log" || true

# 6) Collect metrics
RUN_TS="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/run_${RUN_TS}_${APP}_${POLICY}_${BUDGET}_${FAULT}"
bash "${ROOT_DIR}/scripts/07_collect_metrics.sh" --window "${DURATION}" --output_dir "${OUTPUT_DIR}" \
  --obs-namespace "${OBS_NS}" --app-namespace "${APP_NS}"

# 7) Output result path
echo "${OUTPUT_DIR}" > "${RESULTS_DIR}/last_experiment_dir.txt"
log "Experiment completed. Result directory: ${OUTPUT_DIR}"
echo "RESULT_DIR=${OUTPUT_DIR}"
