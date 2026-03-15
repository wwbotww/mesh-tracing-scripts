#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

PROFILE="demo"
ISTIO_NAMESPACE="istio-system"
INJECT_NAMESPACE="mesh-app"
OTEL_TRACING_SERVICE="otel-collector.observability.svc.cluster.local"
OTEL_TRACING_PORT="4317"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
LOG_FILE="${RESULTS_DIR}/install_istio.log"

usage() {
  cat <<'EOF'
Usage: scripts/01_install_istio.sh [--profile demo|default] [--namespace istio-system]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --namespace) ISTIO_NAMESPACE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ "${PROFILE}" =~ ^(demo|default)$ ]] || err "--profile must be demo|default"
[[ -n "${ISTIO_NAMESPACE}" ]] || err "--namespace cannot be empty"

command -v istioctl >/dev/null 2>&1 || err "istioctl not found"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"

log "Running Istio precheck..."
istioctl x precheck || err "Istio precheck failed"

log "Ensuring namespace ${ISTIO_NAMESPACE} exists..."
kubectl get namespace "${ISTIO_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${ISTIO_NAMESPACE}" || err "Failed to create namespace ${ISTIO_NAMESPACE}"

log "Installing/upgrading Istio via istioctl (stable for local/minikube)..."
istioctl install -y -i "${ISTIO_NAMESPACE}" \
  --set profile="${PROFILE}" \
  --set meshConfig.enablePrometheusMerge=true \
  --set meshConfig.enableTracing=true \
  --set meshConfig.defaultProviders.metrics[0]=prometheus \
  --set meshConfig.defaultProviders.tracing[0]=otel-tracing \
  --set meshConfig.extensionProviders[0].name=otel-tracing \
  --set meshConfig.extensionProviders[0].opentelemetry.service="${OTEL_TRACING_SERVICE}" \
  --set meshConfig.extensionProviders[0].opentelemetry.port="${OTEL_TRACING_PORT}" \
  || err "Istio install failed"

log "Ensuring sidecar injection label is enabled on namespace=${INJECT_NAMESPACE}..."
kubectl get namespace "${INJECT_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${INJECT_NAMESPACE}" || err "Failed to create namespace ${INJECT_NAMESPACE}"
kubectl label namespace "${INJECT_NAMESPACE}" istio-injection=enabled --overwrite || err "Failed to label namespace ${INJECT_NAMESPACE}"

if kubectl -n "${INJECT_NAMESPACE}" get deploy -o name >/dev/null 2>&1; then
  DEPLOY_COUNT="$(kubectl -n "${INJECT_NAMESPACE}" get deploy -o name | wc -l | tr -d ' ')"
  if [[ "${DEPLOY_COUNT}" -gt 0 ]]; then
    log "Restarting workloads in namespace=${INJECT_NAMESPACE} so sidecars pick up latest Istio config..."
    kubectl -n "${INJECT_NAMESPACE}" rollout restart deployment || err "Failed to restart deployments in ${INJECT_NAMESPACE}"
    while IFS= read -r deploy; do
      [[ -n "${deploy}" ]] || continue
      kubectl -n "${INJECT_NAMESPACE}" rollout status "${deploy}" --timeout=300s || err "Deployment not ready after restart: ${deploy}"
    done < <(kubectl -n "${INJECT_NAMESPACE}" get deploy -o name)
  fi
fi

mkdir -p "${RESULTS_DIR}" || err "Failed to create results directory: ${RESULTS_DIR}"
{
  echo "==== install_istio validation log ===="
  echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "profile: ${PROFILE}"
  echo "istio_namespace: ${ISTIO_NAMESPACE}"
  echo "inject_namespace: ${INJECT_NAMESPACE}"
  echo
} > "${LOG_FILE}"

log "Validation: waiting for istiod rollout..."
kubectl -n "${ISTIO_NAMESPACE}" rollout status deployment/istiod --timeout=180s 2>&1 | tee -a "${LOG_FILE}" || err "istiod is not ready"

log "Running istioctl verify-install (if supported by current istioctl version)..."
if istioctl --help | awk '/verify-install/{found=1} END{exit(found?0:1)}'; then
  istioctl verify-install 2>&1 | tee -a "${LOG_FILE}" || warn "istioctl verify-install reported issues."
else
  warn "Current istioctl does not support verify-install; skipping."
fi

log "Running istioctl analyze..."
istioctl analyze 2>&1 | tee -a "${LOG_FILE}" || warn "istioctl analyze reported issues. Continue for lab environment."

log "Getting Istio pods..."
kubectl get pods -n "${ISTIO_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}" || err "Failed to list Istio pods in namespace ${ISTIO_NAMESPACE}"

log "Validation: checking tracing and metrics providers in istio mesh config..."
kubectl get configmap istio -n "${ISTIO_NAMESPACE}" -o yaml 2>&1 | tee -a "${LOG_FILE}" | awk '/defaultProviders:|metrics:|tracing:|extensionProviders:|otel-tracing|prometheus|opentelemetry|service:|port:|enablePrometheusMerge/{print}' || true

log "Istio installation step completed."
