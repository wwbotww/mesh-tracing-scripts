#!/usr/bin/env bash
# Start port-forwards for Jaeger, Prometheus, Grafana so you can access them
# from your local machine via SSH tunnel (ssh -L 16686:localhost:16686 ...).
set -euo pipefail

OBS_NS="${OBS_NS:-observability}"
PID_FILE="${PID_FILE:-/tmp/mesh-tracing-port-forward.pids}"

stop_forward() {
  if [[ -f "${PID_FILE}" ]]; then
    while read -r pid; do
      [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
    done < "${PID_FILE}"
    rm -f "${PID_FILE}"
    echo "Stopped all port-forwards."
  fi
}

if [[ "${1:-}" == "--stop" || "${1:-}" == "-s" ]]; then
  stop_forward
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
kubectl get ns "${OBS_NS}" >/dev/null 2>&1 || { echo "Namespace ${OBS_NS} not found. Is observability stack installed?"; exit 1; }

# Stop any previous run
stop_forward

echo "Starting port-forwards in background (namespace=${OBS_NS})..."
kubectl -n "${OBS_NS}" port-forward svc/jaeger-query 16686:16686 >/dev/null 2>&1 &
echo $! >> "${PID_FILE}"
kubectl -n "${OBS_NS}" port-forward svc/obs-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
echo $! >> "${PID_FILE}"
kubectl -n "${OBS_NS}" port-forward svc/obs-grafana 3000:80 >/dev/null 2>&1 &
echo $! >> "${PID_FILE}"

sleep 1
echo ""
echo "Port-forwards are running. On your local machine (with SSH -L), open:"
echo "  Jaeger:    http://localhost:16686"
echo "  Prometheus: http://localhost:9090"
echo "  Grafana:   http://localhost:3000"
echo ""
echo "To stop: bash $(dirname "$0")/port-forward-ui.sh --stop"
echo "PIDs saved in ${PID_FILE}"
