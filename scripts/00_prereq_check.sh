#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/00_prereq_check.sh

Checks:
  - kubectl / istioctl / helm / minikube availability
  - cluster connectivity
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || err "Required command not found: $cmd"
}

check_version() {
  local cmd="$1"
  log "Checking ${cmd} version..."
  case "${cmd}" in
    kubectl)
      # Client-only check avoids failing early when cluster is not up yet.
      kubectl version --client || err "Failed to run: kubectl version --client"
      ;;
    istioctl)
      # Local client version check only; connectivity is validated later.
      istioctl version --remote=false || err "Failed to run: istioctl version --remote=false"
      ;;
    *)
      "$cmd" version || err "Failed to run: $cmd version"
      ;;
  esac
}

require_cmd kubectl
require_cmd istioctl
require_cmd helm
require_cmd minikube

check_version kubectl
check_version istioctl
check_version helm

log "Checking minikube status..."
minikube status || err "minikube is not reachable or not running."

log "Checking kubectl connectivity..."
kubectl cluster-info >/dev/null 2>&1 || err "kubectl cannot reach the cluster."
kubectl get nodes -o wide || err "Failed to list cluster nodes."

log "Validation: checking Istio CRDs visibility (may be empty before install)..."
kubectl get crd | grep -E 'istio.io|telemetry.istio.io' || warn "Istio CRDs not found yet (expected before install)."

log "Prerequisite checks completed."
