#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS_NS="observability"
APP_NS="mesh-app"
PROM_RELEASE="obs"
RESULTS_DIR="${ROOT_DIR}/results"
LOG_FILE="${RESULTS_DIR}/observability.log"

usage() {
  cat <<'EOF'
Usage: scripts/03_install_observability.sh [--namespace observability] [--app-namespace mesh-app]
Installs:
  - OpenTelemetry Collector
  - Jaeger
  - Prometheus + Grafana (kube-prometheus-stack)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) OBS_NS="${2:-}"; shift 2 ;;
    --app-namespace) APP_NS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v helm >/dev/null 2>&1 || err "helm not found"
command -v curl >/dev/null 2>&1 || err "curl not found"

detect_app_access_url() {
  local path="/"
  if kubectl -n "${APP_NS}" get svc productpage >/dev/null 2>&1; then
    path="/productpage"
  fi

  if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
    local ip nodeport
    ip="$(minikube ip || true)"
    nodeport="$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' || true)"
    if [[ -n "${ip}" && -n "${nodeport}" ]]; then
      echo "http://${ip}:${nodeport}${path}"
      return 0
    fi
  fi

  local ingress_host ingress_port
  ingress_host="$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || true)"
  ingress_port="$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}' || true)"
  if [[ -n "${ingress_host}" && -n "${ingress_port}" ]]; then
    echo "http://${ingress_host}:${ingress_port}${path}"
    return 0
  fi

  return 1
}

seed_istio_request_metrics() {
  local target_url
  target_url="$(detect_app_access_url || true)"
  [[ -n "${target_url}" ]] || return 0

  log "Seeding application traffic so Istio request metrics appear in Prometheus..."
  for _ in $(seq 1 20); do
    curl -fsS --max-time 5 "${target_url}" >/dev/null 2>&1 || true
    sleep 1
  done
}

mkdir -p "${RESULTS_DIR}" || err "Failed to create results dir: ${RESULTS_DIR}"
rm -f "${LOG_FILE}" || true
exec > >(tee -a "${LOG_FILE}") 2>&1
set -x

log "Ensuring namespace ${OBS_NS} exists..."
kubectl get ns "${OBS_NS}" >/dev/null 2>&1 || kubectl create ns "${OBS_NS}" || err "Failed to create namespace ${OBS_NS}"
kubectl get ns "${APP_NS}" >/dev/null 2>&1 || kubectl create ns "${APP_NS}" || err "Failed to create namespace ${APP_NS}"

log "Installing Jaeger (all-in-one, easiest path)..."
kubectl apply -n "${OBS_NS}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: jaegertracing/all-in-one:1.57
        ports:
        - containerPort: 16686
        - containerPort: 4317
        - containerPort: 4318
        - containerPort: 14250
        - containerPort: 14268
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-query
spec:
  selector:
    app: jaeger
  ports:
  - name: http-query
    port: 16686
    targetPort: 16686
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-collector
spec:
  selector:
    app: jaeger
  ports:
  - name: grpc-otlp
    appProtocol: grpc
    port: 4317
    targetPort: 4317
  - name: http-otlp
    appProtocol: http
    port: 4318
    targetPort: 4318
  - name: jaeger-grpc
    port: 14250
    targetPort: 14250
  - name: jaeger-http
    port: 14268
    targetPort: 14268
EOF

log "Installing OpenTelemetry Collector (gateway mode: OTLP in, Jaeger+Prom metrics out)..."
kubectl apply -n "${OBS_NS}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    processors:
      batch:
    exporters:
      otlp/jaeger:
        endpoint: jaeger-collector.${OBS_NS}.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: "0.0.0.0:8889"
    service:
      telemetry:
        metrics:
          address: "0.0.0.0:8888"
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/jaeger]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
      - name: otel-collector
        image: otel/opentelemetry-collector-contrib:0.95.0
        args: ["--config=/conf/config.yaml"]
        ports:
        - containerPort: 4317
        - containerPort: 4318
        - containerPort: 8888
        - containerPort: 8889
        volumeMounts:
        - name: config
          mountPath: /conf
      volumes:
      - name: config
        configMap:
          name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  labels:
    app: otel-collector
spec:
  selector:
    app: otel-collector
  ports:
  - name: grpc-otlp
    appProtocol: grpc
    port: 4317
    targetPort: 4317
  - name: http-otlp
    appProtocol: http
    port: 4318
    targetPort: 4318
  - name: prom-telemetry
    port: 8888
    targetPort: 8888
  - name: prom-export
    port: 8889
    targetPort: 8889
EOF

log "Installing kube-prometheus-stack via Helm..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo update
helm upgrade --install "${PROM_RELEASE}" prometheus-community/kube-prometheus-stack \
  -n "${OBS_NS}" \
  --create-namespace \
  --set grafana.service.type=ClusterIP \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  || err "Failed to install kube-prometheus-stack"

log "Installing PodMonitor for Istio sidecars and OTel Collector metrics..."
kubectl apply -n "${APP_NS}" -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istio-envoy-stats
  labels:
    release: ${PROM_RELEASE}
spec:
  selector:
    matchExpressions:
    - key: security.istio.io/tlsMode
      operator: Exists
  podMetricsEndpoints:
  - port: http-envoy-prom
    path: /stats/prometheus
    interval: 15s
EOF

kubectl apply -n "${OBS_NS}" -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otel-collector-metrics
  labels:
    release: ${PROM_RELEASE}
spec:
  selector:
    matchLabels:
      app: otel-collector
  namespaceSelector:
    matchNames: ["${OBS_NS}"]
  endpoints:
  - port: prom-telemetry
    path: /metrics
    interval: 15s
EOF

log "Applying Istio Telemetry metrics+tracing policy for namespace=${APP_NS}..."
kubectl apply -n "${APP_NS}" -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: tracing-default
spec:
  metrics:
  - providers:
    - name: prometheus
  tracing:
  - providers:
    - name: otel-tracing
    randomSamplingPercentage: 100.0
EOF

log "Validation: wait for core deployments"
kubectl -n "${OBS_NS}" rollout status deployment/otel-collector --timeout=300s || err "otel-collector not ready"
kubectl -n "${OBS_NS}" rollout status deployment/jaeger --timeout=300s || err "jaeger not ready"
kubectl -n "${OBS_NS}" rollout status deployment/"${PROM_RELEASE}"-grafana --timeout=300s || err "grafana not ready"
PROM_STS="$(kubectl -n "${OBS_NS}" get statefulset -l release="${PROM_RELEASE}",app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${PROM_STS}" ]] || err "prometheus statefulset not found"
kubectl -n "${OBS_NS}" rollout status statefulset/"${PROM_STS}" --timeout=300s || err "prometheus not ready"

log "Verification 1/3: collector pod Running"
kubectl get pods -n "${OBS_NS}" -l app=otel-collector
COLLECTOR_PHASE="$(kubectl get pods -n "${OBS_NS}" -l app=otel-collector -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
[[ "${COLLECTOR_PHASE}" == "Running" ]] || err "collector pod is not Running"

log "Verification 2/3: jaeger query UI reachable via port-forward"
kubectl -n "${OBS_NS}" port-forward svc/jaeger-query 16686:16686 >/tmp/jaeger-pf.log 2>&1 &
PF_JAEGER_PID=$!
trap 'kill ${PF_JAEGER_PID} ${PF_PROM_PID:-} >/dev/null 2>&1 || true' EXIT
sleep 3
READY=0
for i in $(seq 1 15); do
  if curl -fsS "http://127.0.0.1:16686/" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
[[ "${READY}" -eq 1 ]] || err "Jaeger UI is not reachable on local port-forward"

log "Verification 3/3: Prometheus has Istio standard metrics"
kubectl -n "${OBS_NS}" port-forward svc/"${PROM_RELEASE}"-kube-prometheus-stack-prometheus 9090:9090 >/tmp/prom-pf.log 2>&1 &
PF_PROM_PID=$!
sleep 3

seed_istio_request_metrics

FOUND_ISTIO_METRIC=0
for i in $(seq 1 24); do
  NAMES="$(curl -fsS "http://127.0.0.1:9090/api/v1/label/__name__/values" || true)"
  if echo "${NAMES}" | python3 -c 'import json,sys; d=json.load(sys.stdin); s=" ".join(d.get("data",[])); sys.exit(0 if ("istio_requests_total" in s or "istio_request_duration_milliseconds_bucket" in s) else 1)'; then
    FOUND_ISTIO_METRIC=1
    break
  fi
  sleep 5
done
[[ "${FOUND_ISTIO_METRIC}" -eq 1 ]] || err "Prometheus cannot find istio_requests_total or istio_request_duration_milliseconds_bucket yet"

log "Verification query example (Istio standard metrics):"
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=istio_requests_total" || true
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=envoy_cluster_upstream_rq_total" || true

log "Verification 4/4: telemetry resource exists"
kubectl get telemetry -n "${APP_NS}" tracing-default || err "Telemetry tracing-default not found in ${APP_NS}"

kill "${PF_JAEGER_PID}" "${PF_PROM_PID}" >/dev/null 2>&1 || true
trap - EXIT

kubectl get pods,svc -n "${OBS_NS}" || err "Failed to list observability resources"
log "Observability installation step completed."
