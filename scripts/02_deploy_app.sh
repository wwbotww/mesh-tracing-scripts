#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

APP=""
NAMESPACE="mesh-app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
ISTIO_NS="istio-system"

BOOKINFO_APP_URL="https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/platform/kube/bookinfo.yaml"
BOOKINFO_GATEWAY_URL="https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/networking/bookinfo-gateway.yaml"
ONLINEBOUTIQUE_APP_URL="https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/release/v0.10.2/release/kubernetes-manifests.yaml"

usage() {
  cat <<'EOF'
Usage: scripts/02_deploy_app.sh --app bookinfo|onlineboutique [--namespace mesh-app]
EOF
}

validate_page_content() {
  local app="$1"
  local content="$2"
  local lower
  lower="$(printf "%s" "${content}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${app}" == "bookinfo" ]]; then
    [[ "${lower}" == *"bookinfo"* || "${lower}" == *"bookstore"* || "${lower}" == *"sign in to bookinfo"* || "${lower}" == *"<html"* ]]
  else
    [[ "${lower}" == *"online boutique"* || "${lower}" == *"hipster shop"* || "${lower}" == *"<html"* ]]
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -n "${APP}" ]] || err "--app is required"
[[ "${APP}" == "bookinfo" || "${APP}" == "onlineboutique" ]] || err "--app must be bookinfo|onlineboutique"

command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
command -v curl >/dev/null 2>&1 || err "curl not found"
command -v istioctl >/dev/null 2>&1 || err "istioctl not found"
mkdir -p "${RESULTS_DIR}" || err "Failed to create results directory: ${RESULTS_DIR}"

if [[ "${APP}" == "bookinfo" ]]; then
  LOG_FILE="${RESULTS_DIR}/deploy_bookinfo.log"
else
  LOG_FILE="${RESULTS_DIR}/deploy_onlineboutique.log"
fi

rm -f "${LOG_FILE}" || true
exec > >(tee -a "${LOG_FILE}") 2>&1
set -x

log "Starting app deployment..."
log "app=${APP}, namespace=${NAMESPACE}, istio_namespace=${ISTIO_NS}"

log "Ensuring target namespace exists..."
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}" || err "Failed to create namespace: ${NAMESPACE}"

log "Enabling sidecar injection label on namespace=${NAMESPACE}..."
kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite || err "Failed to label namespace for sidecar injection"

if [[ "${APP}" == "bookinfo" ]]; then
  log "Deploying Bookinfo application..."
  kubectl apply -n "${NAMESPACE}" -f "${BOOKINFO_APP_URL}" || err "Failed to apply official Bookinfo manifests"

  log "Deploying Bookinfo ingress resources (Gateway + VirtualService)..."
  APPLY_GATEWAY_OK=0
  if kubectl apply -n "${NAMESPACE}" -f "${BOOKINFO_GATEWAY_URL}"; then
    APPLY_GATEWAY_OK=1
  fi
  if [[ "${APPLY_GATEWAY_OK}" -eq 0 ]]; then
    warn "Bookinfo gateway manifest apply failed (likely API version mismatch). Applying compatible v1beta1 gateway/virtualservice fallback..."
    kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: bookinfo-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: bookinfo
spec:
  hosts:
  - "*"
  gateways:
  - bookinfo-gateway
  http:
  - match:
    - uri:
        exact: /productpage
    - uri:
        prefix: /static
    - uri:
        exact: /login
    - uri:
        exact: /logout
    - uri:
        prefix: /api/v1/products
    route:
    - destination:
        host: productpage
        port:
          number: 9080
EOF
  fi
else
  log "Deploying OnlineBoutique (gRPC microservices)..."
  kubectl apply -n "${NAMESPACE}" -f "${ONLINEBOUTIQUE_APP_URL}" || err "Failed to apply official OnlineBoutique manifests"

  log "Disabling loadgenerator so only fortio-injected traffic affects experiments..."
  kubectl scale deployment loadgenerator -n "${NAMESPACE}" --replicas=0 2>/dev/null || warn "loadgenerator deployment not found or already scaled (ignored)"

  log "Deploying OnlineBoutique ingress resources (Gateway + VirtualService)..."
  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: onlineboutique-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: onlineboutique-vs
spec:
  hosts:
  - "*"
  gateways:
  - onlineboutique-gateway
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: frontend
        port:
          number: 80
EOF
fi

log "Validation: waiting for pods to become Ready..."
kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --field-selector=status.phase=Running --timeout=300s || err "Not all running pods became Ready in namespace ${NAMESPACE}"

log "Validation: deployments rollout completed..."
while IFS= read -r deploy; do
  kubectl -n "${NAMESPACE}" rollout status "${deploy}" --timeout=300s || err "Deployment not ready: ${deploy}"
done < <(kubectl get deploy -n "${NAMESPACE}" -o name)

log "Validation: istio-proxy container must exist in each pod..."
MISSING_SIDECAR=0
for pod in $(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{range .items[?(@.metadata.deletionTimestamp==null)]}{.metadata.name}{"\n"}{end}'); do
  containers="$(kubectl get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[*].name}')"
  case " ${containers} " in
    *" istio-proxy "*) ;;
    *) MISSING_SIDECAR=1 ;;
  esac
done

if [[ "${MISSING_SIDECAR}" -eq 1 ]]; then
  log "No sidecar detected in some pods; applying manual injection fallback via istioctl kube-inject..."
  if [[ "${APP}" == "bookinfo" ]]; then
    curl -fsSL "${BOOKINFO_APP_URL}" | istioctl kube-inject -f - | kubectl apply -n "${NAMESPACE}" -f - || err "Manual injection failed for official Bookinfo"
  else
    curl -fsSL "${ONLINEBOUTIQUE_APP_URL}" | istioctl kube-inject -f - | kubectl apply -n "${NAMESPACE}" -f - || err "Manual injection failed for official OnlineBoutique"
  fi

  kubectl rollout restart deployment -n "${NAMESPACE}" || true
  while IFS= read -r deploy; do
    kubectl -n "${NAMESPACE}" rollout status "${deploy}" --timeout=300s || err "Pods not ready after manual sidecar injection: ${deploy}"
  done < <(kubectl get deploy -n "${NAMESPACE}" -o name)
fi

for pod in $(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{range .items[?(@.metadata.deletionTimestamp==null)]}{.metadata.name}{"\n"}{end}'); do
  containers="$(kubectl get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[*].name}')"
  case " ${containers} " in
    *" istio-proxy "*) ;;
    *) err "Pod ${pod} has no istio-proxy container. Containers: ${containers}" ;;
  esac
done

log "Validation: checking ingress resources..."
kubectl get gateway -n "${NAMESPACE}" || err "Gateway not found in namespace ${NAMESPACE}"
kubectl get virtualservice -n "${NAMESPACE}" || err "VirtualService not found in namespace ${NAMESPACE}"

INGRESS_HOST=""
INGRESS_PORT=""
ACCESS_URL=""
if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
  INGRESS_HOST="$(minikube ip || true)"
  INGRESS_PORT="$(kubectl -n "${ISTIO_NS}" get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' || true)"
  if [[ -n "${INGRESS_HOST}" && -n "${INGRESS_PORT}" ]]; then
    if [[ "${APP}" == "bookinfo" ]]; then
      ACCESS_URL="http://${INGRESS_HOST}:${INGRESS_PORT}/productpage"
    else
      ACCESS_URL="http://${INGRESS_HOST}:${INGRESS_PORT}/"
    fi
  fi
fi

if [[ -z "${ACCESS_URL}" ]]; then
  INGRESS_HOST="$(kubectl -n "${ISTIO_NS}" get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || true)"
  INGRESS_PORT="$(kubectl -n "${ISTIO_NS}" get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}' || true)"
  if [[ -n "${INGRESS_HOST}" && -n "${INGRESS_PORT}" ]]; then
    if [[ "${APP}" == "bookinfo" ]]; then
      ACCESS_URL="http://${INGRESS_HOST}:${INGRESS_PORT}/productpage"
    else
      ACCESS_URL="http://${INGRESS_HOST}:${INGRESS_PORT}/"
    fi
  fi
fi

if [[ -n "${ACCESS_URL}" ]]; then
  log "App access URL: ${ACCESS_URL}"
  page_out="$(curl -fsS --max-time 15 "${ACCESS_URL}" || true)"
  PAGE_OK=0
  validate_page_content "${APP}" "${page_out}" && PAGE_OK=1

  if [[ "${PAGE_OK}" -eq 0 ]]; then
    warn "Direct ingress URL check failed (${ACCESS_URL}). Trying port-forward fallback for verification..."
    kubectl -n "${ISTIO_NS}" port-forward svc/istio-ingressgateway 18080:80 >/tmp/deploy-app-pf.log 2>&1 &
    PF_PID=$!
    trap 'kill ${PF_PID:-} >/dev/null 2>&1 || true' EXIT
    sleep 3
    if [[ "${APP}" == "bookinfo" ]]; then
      page_out="$(curl -fsS --max-time 15 "http://127.0.0.1:18080/productpage" || true)"
      validate_page_content "${APP}" "${page_out}" || err "Bookinfo page validation failed via ingress URL and port-forward fallback"
      log "Validation: Bookinfo page reachable via port-forward fallback."
    else
      page_out="$(curl -fsS --max-time 15 "http://127.0.0.1:18080/" || true)"
      validate_page_content "${APP}" "${page_out}" || err "OnlineBoutique page validation failed via ingress URL and port-forward fallback"
      log "Validation: OnlineBoutique page reachable via port-forward fallback."
    fi
    kill "${PF_PID}" >/dev/null 2>&1 || true
    trap - EXIT
  else
    if [[ "${APP}" == "bookinfo" ]]; then
      log "Validation: Bookinfo page is reachable."
    else
      log "Validation: OnlineBoutique page is reachable."
    fi
  fi
else
  warn "Could not determine direct ingress URL. Trying port-forward fallback..."
  kubectl -n "${ISTIO_NS}" port-forward svc/istio-ingressgateway 18080:80 >/tmp/deploy-app-pf.log 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID:-} >/dev/null 2>&1 || true' EXIT
  sleep 3
  if [[ "${APP}" == "bookinfo" ]]; then
    page_out="$(curl -fsS --max-time 15 "http://127.0.0.1:18080/productpage" || true)"
    validate_page_content "${APP}" "${page_out}" || err "Bookinfo page validation failed via port-forward fallback"
    log "Validation: Bookinfo page reachable via port-forward fallback."
  else
    page_out="$(curl -fsS --max-time 15 "http://127.0.0.1:18080/" || true)"
    validate_page_content "${APP}" "${page_out}" || err "OnlineBoutique page validation failed via port-forward fallback"
    log "Validation: OnlineBoutique page reachable via port-forward fallback."
  fi
  kill "${PF_PID}" >/dev/null 2>&1 || true
  trap - EXIT
fi

log "Final verification command output:"
kubectl get pods -n "${NAMESPACE}" || err "Failed to list pods in namespace ${NAMESPACE}"

log "App deployment completed. Full log: ${LOG_FILE}"
