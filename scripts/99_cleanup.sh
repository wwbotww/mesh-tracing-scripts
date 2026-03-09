#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NS="mesh-app"
OBS_NS="observability"
APP=""

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
kubectl delete virtualservice -n "${APP_NS}" -l app.kubernetes.io/managed-by=trace-exp --ignore-not-found || true
kubectl delete virtualservice -n "${APP_NS}" fault-productpage fault-frontend --ignore-not-found || true
kubectl delete cm tracing-sampling-policy -n istio-system --ignore-not-found || true

if [[ -n "${APP}" ]]; then
  APP_MANIFEST="${ROOT_DIR}/manifests/app/${APP}.yaml"
  if [[ -f "${APP_MANIFEST}" ]]; then
    log "Deleting app manifest ${APP_MANIFEST}"
    kubectl delete -n "${APP_NS}" -f "${APP_MANIFEST}" --ignore-not-found || warn "Failed to delete app resources"
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
