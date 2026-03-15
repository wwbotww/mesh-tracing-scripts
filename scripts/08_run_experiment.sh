#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
RUNS_DIR="${RESULTS_DIR}/runs"
INDEX_FILE="${RESULTS_DIR}/index.jsonl"
DRIVER_LOG="${RESULTS_DIR}/exp_driver.log"

APP=""
POLICY=""
BUDGET=""
FAULT_TYPE="none"
FAULT_TARGET=""
FAULT_TARGET_TYPE=""
TARGET=""
RPS=""
LOAD_LEVEL=""
DURATION=""
RUN_ID=""
REPEAT_ID="1"
NOTES=""

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
OUT_DIR=""
LOAD_JOB_NAME=""
CANONICAL_POLICY=""
CANONICAL_BUDGET=""
POLICY_IMPL_STATUS="implemented"
JAEGER_LOCAL_PORT="16689"
JAEGER_PF_PID=""
RUN_START_EPOCH_MS=""
LOAD_START_EPOCH_MS=""
FAULT_APPLY_EPOCH_MS=""
FAULT_CLEAR_EPOCH_MS=""
RUN_END_EPOCH_MS=""
PROM_SVC="obs-kube-prometheus-stack-prometheus"
CONTROLLER_ENABLED="false"
CONTROLLER_PID=""
CONTROLLER_PROM_PF_PID=""
CONTROLLER_PROM_PORT_LOCAL="19093"
CONTROLLER_POLL_INTERVAL_SECONDS="30"
CONTROLLER_WINDOW_SECONDS="120"
CONTROLLER_WARMUP_SECONDS="0"
CONTROLLER_INITIAL_PROFILE=""
CONTROLLER_DIR=""
CONTROLLER_SUMMARY_FILE=""
CONTROLLER_EVENTS_FILE=""

usage() {
  cat <<'EOF'
Usage:
  scripts/08_run_experiment.sh \
    --app bookinfo|onlineboutique \
    --policy head|tail|my_policy|reference|no_tracing \
    --budget low|mid|medium|high \
    --fault-type none|delay|abort \
    --fault-target <service|source->service> \
    --rps <int> \
    --duration <sec> \
    [--run-id <custom_id>] [--load-level low|medium|high] [--repeat-id 1] [--output-dir results/runs/<run_id>]

Compatibility aliases:
  --fault      -> --fault-type
  --target     -> --fault-target
EOF
}

normalize_policy() {
  case "$1" in
    baseline_head|head) echo "head" ;;
    baseline_tail|tail) echo "tail" ;;
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

sanitize_component() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

now_epoch_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --policy) POLICY="${2:-}"; shift 2 ;;
    --budget) BUDGET="${2:-}"; shift 2 ;;
    --fault|--fault-type) FAULT_TYPE="${2:-}"; shift 2 ;;
    --target|--fault-target) FAULT_TARGET="${2:-}"; TARGET="${2:-}"; shift 2 ;;
    --fault-target-type) FAULT_TARGET_TYPE="${2:-}"; shift 2 ;;
    --rps) RPS="${2:-}"; shift 2 ;;
    --load-level) LOAD_LEVEL="${2:-}"; shift 2 ;;
    --duration) DURATION="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --repeat-id) REPEAT_ID="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --output_dir|--output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
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
CANONICAL_POLICY="$(normalize_policy "${POLICY}" || true)"
CANONICAL_BUDGET="$(normalize_budget "${BUDGET}" || true)"
[[ -n "${CANONICAL_POLICY}" ]] || err "--policy must be head|tail|my_policy|reference|no_tracing (or backward-compatible aliases)"
[[ -n "${CANONICAL_BUDGET}" ]] || err "--budget must be low|mid|medium|high"
[[ "${FAULT_TYPE}" =~ ^(none|delay|abort)$ ]] || err "--fault-type must be none|delay|abort"
[[ -n "${RPS}" && "${RPS}" =~ ^[0-9]+$ ]] || err "--rps must be int"
[[ "${DURATION}" =~ ^[0-9]+$ ]] || err "--duration must be int seconds"
[[ "${FIXED_DELAY_MS}" =~ ^[0-9]+$ ]] || err "--fixed_delay_ms must be int"
[[ "${HTTP_STATUS}" =~ ^[1-5][0-9][0-9]$ ]] || err "--http_status must be http code"
[[ "${PERCENTAGE}" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || err "--percentage must be 0..100"

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
command -v python3 >/dev/null 2>&1 || err "python3 not found"
command -v minikube >/dev/null 2>&1 || warn "minikube not found, will try ingress LB for URL detection"

mkdir -p "${RESULTS_DIR}" "${RUNS_DIR}" || err "Failed to create results dir"
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

# Ensure only fortio-injected traffic affects experiments (no loadgenerator background traffic).
disable_loadgenerator_if_present() {
  [[ "${APP}" != "onlineboutique" ]] && return 0
  if kubectl -n "${APP_NS}" get deploy loadgenerator >/dev/null 2>&1; then
    log "Scaling loadgenerator to 0 replicas so only fortio traffic is used."
    kubectl scale deployment loadgenerator -n "${APP_NS}" --replicas=0 || warn "Failed to scale loadgenerator (continuing)"
  fi
}

ensure_observability() {
  if ! kubectl -n "${OBS_NS}" get deploy otel-collector >/dev/null 2>&1; then
    log "Observability stack not detected, installing..."
    bash "${ROOT_DIR}/scripts/03_install_observability.sh" --namespace "${OBS_NS}" --app-namespace "${APP_NS}"
  fi
}

parse_target() {
  local raw_target="${FAULT_TARGET:-${TARGET:-}}"
  if [[ -z "${raw_target}" && "${FAULT_TYPE}" != "none" ]]; then
    err "--fault-target is required when --fault-type is delay|abort"
  fi

  if [[ -z "${raw_target}" ]]; then
    FAULT_TARGET_TYPE="none"
    SOURCE_SERVICE=""
    TARGET_SERVICE=""
    FAULT_TARGET=""
    return 0
  fi

  if [[ "${raw_target}" == *"->"* ]]; then
    FAULT_TARGET_TYPE="${FAULT_TARGET_TYPE:-edge}"
    SOURCE_SERVICE="${raw_target%%->*}"
    TARGET_SERVICE="${raw_target##*->}"
  elif [[ "${raw_target}" == service=* ]]; then
    FAULT_TARGET_TYPE="${FAULT_TARGET_TYPE:-service}"
    SOURCE_SERVICE=""
    TARGET_SERVICE="${raw_target#service=}"
  elif [[ "${raw_target}" == edge=* ]]; then
    FAULT_TARGET_TYPE="${FAULT_TARGET_TYPE:-edge}"
    local edge_target="${raw_target#edge=}"
    SOURCE_SERVICE="${edge_target%%->*}"
    TARGET_SERVICE="${edge_target##*->}"
    raw_target="${edge_target}"
  elif [[ "${raw_target}" == /* ]]; then
    FAULT_TARGET_TYPE="${FAULT_TARGET_TYPE:-route}"
    SOURCE_SERVICE=""
    if [[ "${APP}" == "bookinfo" ]]; then
      TARGET_SERVICE="reviews"
    else
      TARGET_SERVICE="frontend"
    fi
    warn "--fault-target looked like route (${raw_target}); using target service=${TARGET_SERVICE} for fault injection."
  else
    FAULT_TARGET_TYPE="${FAULT_TARGET_TYPE:-service}"
    SOURCE_SERVICE=""
    TARGET_SERVICE="${raw_target}"
  fi

  FAULT_TARGET="${raw_target}"
}

resolve_output_dir() {
  if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="$(date +%Y%m%d_%H%M%S)_$(sanitize_component "${APP}")_$(sanitize_component "${CANONICAL_POLICY}")_$(sanitize_component "${CANONICAL_BUDGET}")"
    RUN_ID+="_$(sanitize_component "${LOAD_LEVEL:-rps${RPS}}")_$(sanitize_component "${FAULT_TYPE}")"
    RUN_ID+="_$(sanitize_component "${FAULT_TARGET_TYPE:-none}")"
    if [[ -n "${FAULT_TARGET}" ]]; then
      RUN_ID+="_$(sanitize_component "${FAULT_TARGET}")"
    fi
    RUN_ID+="_r$(sanitize_component "${REPEAT_ID}")"
  fi

  if [[ -n "${OUTPUT_DIR}" ]]; then
    case "${OUTPUT_DIR}" in
      /*) OUT_DIR="${OUTPUT_DIR}" ;;
      *) OUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}" ;;
    esac
  else
    OUT_DIR="${RUNS_DIR}/${RUN_ID}"
  fi

  mkdir -p "${OUT_DIR}/load" "${OUT_DIR}/fault" "${OUT_DIR}/utility" || err "Failed to create run dir"
}

resolve_controller_initial_profile() {
  case "${CANONICAL_BUDGET}" in
    low) echo "conservative" ;;
    mid) echo "balanced" ;;
    high) echo "aggressive" ;;
    *) echo "balanced" ;;
  esac
}

start_controller() {
  [[ "${CANONICAL_POLICY}" == "my_policy" ]] || return 0

  CONTROLLER_ENABLED="true"
  CONTROLLER_WARMUP_SECONDS="${WARMUP_SEC}"
  CONTROLLER_INITIAL_PROFILE="$(resolve_controller_initial_profile)"
  CONTROLLER_DIR="${OUT_DIR}/controller"
  CONTROLLER_SUMMARY_FILE="${CONTROLLER_DIR}/controller_summary.json"
  CONTROLLER_EVENTS_FILE="${CONTROLLER_DIR}/controller_events.jsonl"
  mkdir -p "${CONTROLLER_DIR}" || err "Failed to create controller output dir"

  kubectl -n "${OBS_NS}" port-forward svc/"${PROM_SVC}" "${CONTROLLER_PROM_PORT_LOCAL}:9090" \
    >"${CONTROLLER_DIR}/prometheus_port_forward.log" 2>&1 &
  CONTROLLER_PROM_PF_PID=$!
  sleep 3

  python3 "${ROOT_DIR}/scripts/volatility_tail_controller.py" \
    --prometheus-url "http://127.0.0.1:${CONTROLLER_PROM_PORT_LOCAL}" \
    --app-namespace "${APP_NS}" \
    --obs-namespace "${OBS_NS}" \
    --output-dir "${CONTROLLER_DIR}" \
    --poll-interval-seconds "${CONTROLLER_POLL_INTERVAL_SECONDS}" \
    --window-seconds "${CONTROLLER_WINDOW_SECONDS}" \
    --warmup-seconds "${CONTROLLER_WARMUP_SECONDS}" \
    --collector-deployment otel-collector \
    --initial-profile "${CONTROLLER_INITIAL_PROFILE}" \
    --budget-label "${CANONICAL_BUDGET}" \
    --start-epoch-ms "${LOAD_START_EPOCH_MS}" \
    >"${CONTROLLER_DIR}/controller_stdout.log" 2>"${CONTROLLER_DIR}/controller_stderr.log" &
  CONTROLLER_PID=$!
}

stop_controller() {
  if [[ -n "${CONTROLLER_PID}" ]]; then
    kill "${CONTROLLER_PID}" >/dev/null 2>&1 || true
    wait "${CONTROLLER_PID}" >/dev/null 2>&1 || true
    CONTROLLER_PID=""
  fi
  if [[ -n "${CONTROLLER_PROM_PF_PID}" ]]; then
    kill "${CONTROLLER_PROM_PF_PID}" >/dev/null 2>&1 || true
    wait "${CONTROLLER_PROM_PF_PID}" >/dev/null 2>&1 || true
    CONTROLLER_PROM_PF_PID=""
  fi
}

write_run_context() {
  python3 - <<'PY' \
    "${OUT_DIR}/run_context.json" \
    "${RUN_ID}" \
    "${APP}" \
    "${POLICY}" \
    "${CANONICAL_POLICY}" \
    "${BUDGET}" \
    "${CANONICAL_BUDGET}" \
    "${POLICY_IMPL_STATUS}" \
    "${LOAD_LEVEL}" \
    "${RPS}" \
    "${DURATION}" \
    "${FAULT_TYPE}" \
    "${FAULT_TARGET_TYPE}" \
    "${FAULT_TARGET}" \
    "${SOURCE_SERVICE}" \
    "${TARGET_SERVICE}" \
    "${APP_NS}" \
    "${OBS_NS}" \
    "${ISTIO_NS}" \
    "${REPEAT_ID}" \
    "${NOTES}" \
    "${TARGET_URL}" \
    "${FIXED_DELAY_MS}" \
    "${HTTP_STATUS}" \
    "${PERCENTAGE}" \
    "${RUN_START_EPOCH_MS}" \
    "${LOAD_START_EPOCH_MS}" \
    "${FAULT_APPLY_EPOCH_MS}" \
    "${FAULT_CLEAR_EPOCH_MS}" \
    "${RUN_END_EPOCH_MS}" \
    "${CONTROLLER_ENABLED}" \
    "${CONTROLLER_POLL_INTERVAL_SECONDS}" \
    "${CONTROLLER_WINDOW_SECONDS}" \
    "${CONTROLLER_WARMUP_SECONDS}" \
    "${CONTROLLER_INITIAL_PROFILE}" \
    "${CONTROLLER_DIR}" \
    "${CONTROLLER_SUMMARY_FILE}" \
    "${CONTROLLER_EVENTS_FILE}" \
    "${CONTROLLER_PROM_PORT_LOCAL}"
import json
import sys
from pathlib import Path

(
    output_path,
    run_id,
    app,
    requested_policy,
    canonical_policy,
    requested_budget,
    canonical_budget,
    policy_impl_status,
    load_level,
    rps,
    duration,
    fault_type,
    fault_target_type,
    fault_target,
    source_service,
    target_service,
    app_ns,
    obs_ns,
    istio_ns,
    repeat_id,
    notes,
    target_url,
    fixed_delay_ms,
    http_status,
    percentage,
    run_start_epoch_ms,
    load_start_epoch_ms,
    fault_apply_epoch_ms,
    fault_clear_epoch_ms,
    run_end_epoch_ms,
    controller_enabled,
    controller_poll_interval_seconds,
    controller_window_seconds,
    controller_warmup_seconds,
    controller_initial_profile,
    controller_dir,
    controller_summary_file,
    controller_events_file,
    controller_prom_port_local,
) = sys.argv[1:40]

def maybe_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

doc = {
    "run_id": run_id,
    "app": app,
    "policy": {
        "requested": requested_policy,
        "canonical": canonical_policy,
        "budget_requested": requested_budget,
        "budget_canonical": canonical_budget,
        "policy_impl_status": policy_impl_status,
    },
    "load": {
        "level": load_level or None,
        "requested_rps": int(rps),
        "duration_seconds": int(duration),
        "target_url": target_url,
    },
    "fault": {
        "type": fault_type,
        "target_type": fault_target_type or None,
        "target": fault_target or None,
        "source_service": source_service or None,
        "target_service": target_service or None,
        "fixed_delay_ms": int(fixed_delay_ms),
        "http_status": int(http_status),
        "percentage": int(percentage),
    },
    "namespaces": {
        "app": app_ns,
        "observability": obs_ns,
        "istio": istio_ns,
    },
    "repeat_id": repeat_id,
    "notes": notes or None,
    "timestamps": {
        "run_start_epoch_ms": maybe_int(run_start_epoch_ms),
        "load_start_epoch_ms": maybe_int(load_start_epoch_ms),
        "fault_apply_epoch_ms": maybe_int(fault_apply_epoch_ms),
        "fault_clear_epoch_ms": maybe_int(fault_clear_epoch_ms),
        "run_end_epoch_ms": maybe_int(run_end_epoch_ms),
    },
    "controller": (
        {
            "enabled": True,
            "poll_interval_seconds": maybe_int(controller_poll_interval_seconds),
            "window_seconds": maybe_int(controller_window_seconds),
            "warmup_seconds": maybe_int(controller_warmup_seconds),
            "initial_profile": controller_initial_profile or None,
            "prometheus_port_local": maybe_int(controller_prom_port_local),
            "artifacts": {
                "dir": controller_dir or None,
                "summary_file": controller_summary_file or None,
                "events_file": controller_events_file or None,
            },
        }
        if controller_enabled == "true"
        else None
    ),
}
Path(output_path).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
}

write_utility_placeholders() {
  python3 - <<'PY' "${OUT_DIR}/utility/rca_ranking.json" "${FAULT_TARGET}" "${TARGET_SERVICE}"
import json
import sys
from pathlib import Path

doc = {
    "ground_truth_target": sys.argv[2] or None,
    "ground_truth_service": sys.argv[3] or None,
    "ranking": [],
    "top1_hit": None,
    "top3_hit": None,
    "status": "placeholder",
    "reason": "rca_algorithm_not_implemented",
}
Path(sys.argv[1]).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY

  python3 - <<'PY' "${OUT_DIR}/utility/critical_path.json"
import json
import sys
from pathlib import Path

doc = {
    "critical_path_edges": [],
    "reference_edges": [],
    "jaccard": None,
    "status": "placeholder",
    "reason": "critical_path_comparison_not_implemented",
}
Path(sys.argv[1]).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
}

resolve_entry_service() {
  if [[ "${APP}" == "onlineboutique" ]]; then
    echo "frontend.${APP_NS}"
  else
    echo "productpage.${APP_NS}"
  fi
}

resolve_reference_run_summary() {
  python3 - <<'PY' \
    "${INDEX_FILE}" \
    "${APP}" \
    "${LOAD_LEVEL}" \
    "${RPS}" \
    "${FAULT_TYPE}" \
    "${FAULT_TARGET_TYPE}" \
    "${FAULT_TARGET}" \
    "${REPEAT_ID}" \
    "${CANONICAL_POLICY}"
import json
import sys
from pathlib import Path

(
    index_path,
    app,
    load_level,
    requested_rps,
    fault_type,
    fault_target_type,
    fault_target,
    repeat_id,
    current_policy,
) = sys.argv[1:10]

if current_policy == "reference":
    print("")
    sys.exit(0)

path = Path(index_path)
if not path.exists():
    print("")
    sys.exit(0)

records = []
for raw_line in path.read_text(encoding="utf-8").splitlines():
    raw_line = raw_line.strip()
    if not raw_line:
        continue
    try:
        record = json.loads(raw_line)
    except json.JSONDecodeError:
        continue
    if record.get("status") != "completed":
        continue
    if record.get("app") != app:
        continue
    if str(record.get("load_level") or "") != str(load_level or ""):
        continue
    if str(record.get("requested_rps") or "") != str(requested_rps):
        continue
    if record.get("fault_type") != fault_type:
        continue
    if str(record.get("fault_target_type") or "") != str(fault_target_type or ""):
        continue
    if str(record.get("fault_target") or "") != str(fault_target or ""):
        continue
    if str(record.get("repeat_id") or "") != str(repeat_id):
        continue
    if record.get("policy") != "reference":
        continue
    records.append(record)

if not records:
    print("")
    sys.exit(0)

records.sort(key=lambda item: str(item.get("run_id", "")), reverse=True)
print(records[0].get("summary_file", ""))
PY
}

cleanup_fault() {
  kill "${JAEGER_PF_PID:-}" >/dev/null 2>&1 || true
  stop_controller
  if [[ "${FAULT_APPLIED}" == true && -n "${TARGET_SERVICE}" ]]; then
    local fault_args=()
    if [[ -n "${SOURCE_SERVICE}" ]]; then
      fault_args+=(--source_service "${SOURCE_SERVICE}")
    fi
    bash "${ROOT_DIR}/scripts/05_inject_fault.sh" --clear --fault "${FAULT_TYPE}" --target_service "${TARGET_SERVICE}" \
      "${fault_args[@]}" --namespace "${APP_NS}" --obs-namespace "${OBS_NS}" --output-dir "${OUT_DIR}" || true
  fi
}

trap cleanup_fault EXIT

RUN_START_EPOCH_MS="$(now_epoch_ms)"

ensure_prereq
ensure_istio
ensure_app
disable_loadgenerator_if_present
ensure_observability

parse_target

if [[ -z "${TARGET_URL}" ]]; then
  TARGET_URL="$(detect_target_url || true)"
fi
[[ -n "${TARGET_URL}" ]] || err "Unable to resolve load target URL, please pass --target_url"

resolve_output_dir
write_run_context
write_utility_placeholders

bash "${ROOT_DIR}/scripts/04_apply_sampling_policy.sh" --policy "${CANONICAL_POLICY}" --budget "${CANONICAL_BUDGET}" --namespace "${OBS_NS}" --app "${APP}" --app-namespace "${APP_NS}"

WARMUP_SEC=60
FAULT_PHASE_SEC=$(( DURATION * 60 / 100 ))
FAULT_START_AFTER_WARMUP=$(( DURATION * 20 / 100 ))
TOTAL_LOAD_SEC=$(( WARMUP_SEC + DURATION ))
LOAD_JOB_NAME="loadgen-exp-$(date +%H%M%S)"

kubectl delete job "${LOAD_JOB_NAME}" -n "${APP_NS}" --ignore-not-found
LOAD_START_EPOCH_MS="$(now_epoch_ms)"
write_run_context
kubectl apply -n "${APP_NS}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${LOAD_JOB_NAME}
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
        - "${TOTAL_LOAD_SEC}s"
        - -H
        - "x-b3-sampled: 1"
        - -H
        - "x-envoy-force-trace: true"
        - "${TARGET_URL}"
EOF

start_controller
write_run_context

sleep "${WARMUP_SEC}"
sleep "${FAULT_START_AFTER_WARMUP}"

if [[ "${FAULT_TYPE}" != "none" ]]; then
  fault_args=()
  if [[ -n "${SOURCE_SERVICE}" ]]; then
    fault_args+=(--source_service "${SOURCE_SERVICE}")
  fi
  FAULT_APPLY_EPOCH_MS="$(now_epoch_ms)"
  write_run_context
  bash "${ROOT_DIR}/scripts/05_inject_fault.sh" --apply --fault "${FAULT_TYPE}" --target_service "${TARGET_SERVICE}" \
    "${fault_args[@]}" --fixed_delay_ms "${FIXED_DELAY_MS}" --http_status "${HTTP_STATUS}" --percentage "${PERCENTAGE}" \
    --namespace "${APP_NS}" --obs-namespace "${OBS_NS}" --target_url "${TARGET_URL}" --output-dir "${OUT_DIR}"
  FAULT_APPLIED=true
  sleep "${FAULT_PHASE_SEC}"
  bash "${ROOT_DIR}/scripts/05_inject_fault.sh" --clear --fault "${FAULT_TYPE}" --target_service "${TARGET_SERVICE}" \
    "${fault_args[@]}" --namespace "${APP_NS}" --obs-namespace "${OBS_NS}" --target_url "${TARGET_URL}" --output-dir "${OUT_DIR}"
  FAULT_CLEAR_EPOCH_MS="$(now_epoch_ms)"
  FAULT_APPLIED=false
  write_run_context
fi

kubectl wait --for=condition=complete job/"${LOAD_JOB_NAME}" -n "${APP_NS}" --timeout="$((TOTAL_LOAD_SEC + 300))s" \
  || err "Load job did not complete"
kubectl logs job/"${LOAD_JOB_NAME}" -n "${APP_NS}" > "${OUT_DIR}/load/fortio_stdout.log" || err "Failed to capture load job log"
RUN_END_EPOCH_MS="$(now_epoch_ms)"
if [[ "${FAULT_TYPE}" == "none" ]]; then
  FAULT_APPLY_EPOCH_MS="${LOAD_START_EPOCH_MS}"
  FAULT_CLEAR_EPOCH_MS="${RUN_END_EPOCH_MS}"
fi
write_run_context
stop_controller
write_run_context
python3 "${ROOT_DIR}/scripts/parse_fortio_output.py" "${OUT_DIR}/load/fortio_stdout.log" > "${OUT_DIR}/load/load_summary.json"

python3 - <<'PY' \
  "${OUT_DIR}/load/load_summary.json" \
  "${LOAD_JOB_NAME}" \
  "${APP}" \
  "${APP_NS}" \
  "${RPS}" \
  "${TOTAL_LOAD_SEC}" \
  "${TARGET_URL}"
import json
import sys
from pathlib import Path

summary_path, job_name, app, namespace, rps, total_duration, target_url = sys.argv[1:8]
doc = json.loads(Path(summary_path).read_text(encoding="utf-8"))
doc.update(
    {
        "job_name": job_name,
        "app": app,
        "namespace": namespace,
        "requested_rps": int(rps),
        "requested_duration_seconds": int(total_duration),
        "target_url": target_url,
    }
)
Path(summary_path).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY

bash "${ROOT_DIR}/scripts/07_collect_metrics.sh" --window "${DURATION}" --output_dir "${OUT_DIR}" \
  --obs-namespace "${OBS_NS}" --app-namespace "${APP_NS}"

REFERENCE_SUMMARY_FILE="$(resolve_reference_run_summary || true)"
REFERENCE_RUN_ID=""
REFERENCE_RUN_DIR=""
ENTRY_SERVICE="$(resolve_entry_service)"
kubectl -n "${OBS_NS}" port-forward svc/jaeger-query "${JAEGER_LOCAL_PORT}:16686" >/tmp/jaeger-rca-export-pf.log 2>&1 &
JAEGER_PF_PID=$!
sleep 3

python3 "${ROOT_DIR}/scripts/export_traces.py" \
  --run-dir "${OUT_DIR}" \
  --jaeger-url "http://127.0.0.1:${JAEGER_LOCAL_PORT}" \
  --entry-service "${ENTRY_SERVICE}" \
  --start-us "$((FAULT_APPLY_EPOCH_MS * 1000))" \
  --end-us "$((FAULT_CLEAR_EPOCH_MS * 1000))" \
  --output-json "${OUT_DIR}/utility/raw_traces/current_traces.json" \
  --output-meta "${OUT_DIR}/utility/raw_traces/current_trace_meta.json" \
  --limit 5000

REFERENCE_TRACE_ARGS=()
if [[ -n "${REFERENCE_SUMMARY_FILE}" && -f "${REFERENCE_SUMMARY_FILE}" ]]; then
  REFERENCE_RUN_DIR="$(dirname "${REFERENCE_SUMMARY_FILE}")"
  REFERENCE_RUN_ID="$(python3 - <<'PY' "${REFERENCE_SUMMARY_FILE}"
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(doc.get("run_id", ""))
PY
)"
  python3 - <<'PY' "${REFERENCE_RUN_DIR}/run_context.json" > "${OUT_DIR}/utility/reference_window.txt"
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
timestamps = doc.get("timestamps", {})
print(f"{timestamps.get('fault_apply_epoch_ms','')},{timestamps.get('fault_clear_epoch_ms','')}")
PY
  REF_WINDOW="$(python3 - <<'PY' "${OUT_DIR}/utility/reference_window.txt"
from pathlib import Path
print(Path(__import__('sys').argv[1]).read_text(encoding='utf-8').strip())
PY
)"
  REF_START_MS="${REF_WINDOW%%,*}"
  REF_END_MS="${REF_WINDOW##*,}"
  if [[ -n "${REF_START_MS}" && -n "${REF_END_MS}" ]]; then
    python3 "${ROOT_DIR}/scripts/export_traces.py" \
      --run-dir "${REFERENCE_RUN_DIR}" \
      --jaeger-url "http://127.0.0.1:${JAEGER_LOCAL_PORT}" \
      --entry-service "${ENTRY_SERVICE}" \
      --start-us "$((REF_START_MS * 1000))" \
      --end-us "$((REF_END_MS * 1000))" \
      --output-json "${OUT_DIR}/utility/raw_traces/reference_traces.json" \
      --output-meta "${OUT_DIR}/utility/raw_traces/reference_trace_meta.json" \
      --limit 5000
    REFERENCE_TRACE_ARGS=(--reference-run-id "${REFERENCE_RUN_ID}" --reference-traces "${OUT_DIR}/utility/raw_traces/reference_traces.json")
  fi
fi

python3 "${ROOT_DIR}/scripts/compute_rca.py" \
  --run-dir "${OUT_DIR}" \
  --current-traces "${OUT_DIR}/utility/raw_traces/current_traces.json" \
  "${REFERENCE_TRACE_ARGS[@]}"

python3 "${ROOT_DIR}/scripts/compute_critical_path.py" \
  --run-dir "${OUT_DIR}" \
  --current-traces "${OUT_DIR}/utility/raw_traces/current_traces.json" \
  "${REFERENCE_TRACE_ARGS[@]}"

kill "${JAEGER_PF_PID}" >/dev/null 2>&1 || true
JAEGER_PF_PID=""

python3 - <<'PY' \
  "${OUT_DIR}/summary.json" \
  "${OUT_DIR}/run_context.json" \
  "${OUT_DIR}/load/load_summary.json" \
  "${OUT_DIR}/cost_metrics.json" \
  "${OUT_DIR}/utility/rca_ranking.json" \
  "${OUT_DIR}/utility/critical_path.json" \
  "${OUT_DIR}/fault/apply_summary.json" \
  "${OUT_DIR}/fault/clear_summary.json" \
  "${CONTROLLER_SUMMARY_FILE}" \
  "${CONTROLLER_EVENTS_FILE}"
import json
import sys
from pathlib import Path

summary_path, context_path, load_path, metrics_path, rca_path, critical_path, fault_apply_path, fault_clear_path, controller_summary_path, controller_events_path = sys.argv[1:11]

def load_doc(path):
    if not path:
        return None
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None
    return json.loads(p.read_text(encoding="utf-8"))

context = load_doc(context_path) or {}
load_summary = load_doc(load_path) or {}
metrics = load_doc(metrics_path) or {}
rca = load_doc(rca_path) or {}
critical = load_doc(critical_path) or {}
fault_apply = load_doc(fault_apply_path)
fault_clear = load_doc(fault_clear_path)
controller = load_doc(controller_summary_path)

metric_map = metrics.get("metrics", {})

doc = {
    "run_id": context.get("run_id"),
    "status": "completed",
    "app": context.get("app"),
    "policy": context.get("policy"),
    "namespaces": context.get("namespaces"),
    "repeat_id": context.get("repeat_id"),
    "notes": context.get("notes"),
    "load": {
        **(context.get("load") or {}),
        "job_name": load_summary.get("job_name"),
        "achieved_qps": load_summary.get("achieved_qps"),
        "total_calls": load_summary.get("total_calls"),
        "average_latency_ms": load_summary.get("average_latency_ms"),
        "latency_ms": load_summary.get("latency_ms"),
        "status_codes": load_summary.get("status_codes"),
        "http_success_rate": load_summary.get("http_success_rate"),
        "http_error_rate": load_summary.get("http_error_rate"),
    },
    "fault": {
        **(context.get("fault") or {}),
        "ground_truth": {
            "fault_target": (context.get("fault") or {}).get("target"),
            "fault_target_type": (context.get("fault") or {}).get("target_type"),
            "source_service": (context.get("fault") or {}).get("source_service"),
            "target_service": (context.get("fault") or {}).get("target_service"),
        },
        "apply": fault_apply,
        "clear": fault_clear,
    },
    "controller": controller,
    "cost_metrics": {
        "latency_ms": {
            "fortio": load_summary.get("latency_ms"),
            "prometheus": {
                "p50": metric_map.get("p50_latency_ms"),
                "p95": metric_map.get("p95_latency_ms"),
                "p99": metric_map.get("p99_latency_ms"),
            },
        },
        "error_rate": {
            "fortio": load_summary.get("http_error_rate"),
            "prometheus": metric_map.get("error_rate"),
        },
        "request_rate": metric_map.get("request_rate"),
        "sidecar_cpu": {
            "sum_cores": metric_map.get("envoy_cpu_cores_sum"),
            "per_pod_cores": metric_map.get("envoy_cpu_cores_per_pod"),
        },
        "trace_volume": {
            "spans_per_sec": metric_map.get("otel_spans_per_sec"),
            "bytes_per_sec": metric_map.get("otel_bytes_per_sec"),
            "accepted_spans_per_sec": metric_map.get("otel_accepted_spans_per_sec"),
            "effective_sampling_ratio": metric_map.get("effective_sampling_ratio"),
        },
    },
    "utility_metrics": {
        "rca_topk": rca,
        "critical_path_fidelity": critical,
    },
    "artifacts": {
        "run_context": context_path,
        "load_summary": load_path,
        "cost_metrics": metrics_path,
        "rca_features": str(Path(summary_path).parent / "utility" / "rca_features.json"),
        "rca_ranking": rca_path,
        "critical_path": critical_path,
        "controller_summary": controller_summary_path or None,
        "controller_events": controller_events_path or None,
        "snapshots_dir": str(Path(summary_path).parent / "snapshots"),
        "metrics_raw_dir": str(Path(summary_path).parent / "metrics_raw"),
    },
}
Path(summary_path).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY

python3 - <<'PY' "${INDEX_FILE}" "${OUT_DIR}/summary.json"
import json
import sys
from pathlib import Path

index_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
summary = json.loads(summary_path.read_text(encoding="utf-8"))
record = {
    "run_id": summary.get("run_id"),
    "summary_file": str(summary_path),
    "status": summary.get("status"),
    "app": summary.get("app"),
    "policy": (summary.get("policy") or {}).get("canonical"),
    "budget": (summary.get("policy") or {}).get("budget_canonical"),
    "load_level": (summary.get("load") or {}).get("level"),
    "requested_rps": (summary.get("load") or {}).get("requested_rps"),
    "fault_type": (summary.get("fault") or {}).get("type"),
    "fault_target_type": ((summary.get("fault") or {}).get("ground_truth") or {}).get("fault_target_type"),
    "fault_target": ((summary.get("fault") or {}).get("ground_truth") or {}).get("fault_target"),
    "repeat_id": summary.get("repeat_id"),
}
with index_path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, ensure_ascii=True) + "\n")
PY

echo "${OUT_DIR}" > "${RESULTS_DIR}/last_experiment_dir.txt"
log "Experiment completed. Result directory: ${OUT_DIR}"
echo "RESULT_DIR=${OUT_DIR}"
