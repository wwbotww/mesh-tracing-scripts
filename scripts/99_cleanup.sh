#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NS="mesh-app"
OBS_NS="observability"
APP=""
BOOKINFO_APP_URL="https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/platform/kube/bookinfo.yaml"
BOOKINFO_GATEWAY_URL="https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/networking/bookinfo-gateway.yaml"
ONLINEBOUTIQUE_APP_URL="https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/release/v0.10.2/release/kubernetes-manifests.yaml"

usage() {
  cat <<'EOF'
Usage: scripts/99_cleanup.sh [--app bookinfo|onlineboutique] [--app-namespace mesh-app] [--obs-namespace observability]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --app-namespace) APP_NS="${2:-}"; shift 2 ;;
    --obs-namespace) OBS_NS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"

log "Deleting load generator and fault resources (idempotent)..."
kubectl delete job loadgen -n "${APP_NS}" --ignore-not-found
kubectl get jobs -n "${APP_NS}" -o name 2>/dev/null | awk -F/ '/^job.batch\/loadgen-exp-/{print $2}' | while IFS= read -r job; do
  [[ -n "${job}" ]] && kubectl delete job "${job}" -n "${APP_NS}" --ignore-not-found
done
kubectl delete virtualservice -n "${APP_NS}" -l app.kubernetes.io/managed-by=trace-exp --ignore-not-found || true
kubectl delete virtualservice -n "${APP_NS}" fault-productpage fault-frontend --ignore-not-found || true
kubectl delete cm tracing-sampling-policy -n istio-system --ignore-not-found || true

if [[ -n "${APP}" ]]; then
  if [[ "${APP}" == "bookinfo" ]]; then
    log "Deleting official remote Bookinfo resources"
    kubectl delete -n "${APP_NS}" -f "${BOOKINFO_GATEWAY_URL}" --ignore-not-found || warn "Failed to delete official Bookinfo gateway"
    kubectl delete -n "${APP_NS}" -f "${BOOKINFO_APP_URL}" --ignore-not-found || warn "Failed to delete official Bookinfo app"
    kubectl delete gateway -n "${APP_NS}" bookinfo-gateway --ignore-not-found || true
    kubectl delete virtualservice -n "${APP_NS}" bookinfo --ignore-not-found || true
  elif [[ "${APP}" == "onlineboutique" ]]; then
    log "Deleting official remote OnlineBoutique resources"
    kubectl delete -n "${APP_NS}" -f "${ONLINEBOUTIQUE_APP_URL}" --ignore-not-found || warn "Failed to delete official OnlineBoutique app"
    kubectl delete gateway -n "${APP_NS}" onlineboutique-gateway --ignore-not-found || true
    kubectl delete virtualservice -n "${APP_NS}" onlineboutique-vs --ignore-not-found || true
  else
    warn "Unknown app '${APP}', skipping app-specific cleanup"
  fi
fi

log "Deleting observability resources..."
for f in \
  "${ROOT_DIR}/manifests/grafana/grafana.yaml" \
  "${ROOT_DIR}/manifests/prom/prometheus.yaml" \
  "${ROOT_DIR}/manifests/jaeger/jaeger.yaml" \
  "${ROOT_DIR}/manifests/otel/otel-collector.yaml"; do
  if [[ -f "${f}" ]]; then
    kubectl delete -n "${OBS_NS}" -f "${f}" --ignore-not-found || warn "Failed to delete from ${f}"
  fi
done

log "Validation: remaining key namespaces/resources"
kubectl get pods -n "${OBS_NS}" || warn "Observability namespace may not exist."
kubectl get pods -n "${APP_NS}" || warn "App namespace may not exist."

log "Cleanup completed."
