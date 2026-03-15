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
  - single-node minikube mode
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

check_single_node_mode() {
  python3 - <<'PY'
import json
import subprocess
import sys

try:
    raw = subprocess.check_output(
        ["kubectl", "get", "nodes", "-o", "json"],
        text=True,
        stderr=subprocess.STDOUT,
    )
except subprocess.CalledProcessError as exc:
    print(f"[ERROR] Failed to query cluster nodes: {exc.output.strip()}", file=sys.stderr)
    sys.exit(1)

doc = json.loads(raw)
items = doc.get("items", [])
node_names = [item.get("metadata", {}).get("name", "") for item in items]

ready_nodes = []
for item in items:
    for condition in item.get("status", {}).get("conditions", []):
        if condition.get("type") == "Ready" and condition.get("status") == "True":
            ready_nodes.append(item.get("metadata", {}).get("name", ""))
            break

if len(items) != 1 or len(ready_nodes) != 1:
    print("[ERROR] This project now expects single-node minikube mode.", file=sys.stderr)
    print(f"[ERROR] Detected nodes: {node_names}", file=sys.stderr)
    print(f"[ERROR] Ready nodes: {ready_nodes}", file=sys.stderr)
    print("[ERROR] Suggested recovery:", file=sys.stderr)
    print("[ERROR]   minikube delete", file=sys.stderr)
    print("[ERROR]   minikube start --driver=docker --cpus=4 --memory=6144", file=sys.stderr)
    sys.exit(1)

print(f"[INFO] Single-node mode confirmed: {ready_nodes[0]}")
PY
}

log "Checking minikube status..."
minikube status || err "minikube is not reachable or not running."

log "Checking kubectl connectivity..."
kubectl cluster-info >/dev/null 2>&1 || err "kubectl cannot reach the cluster."
kubectl get nodes -o wide || err "Failed to list cluster nodes."
check_single_node_mode || err "Single-node mode validation failed."

log "Validation: checking Istio CRDs visibility (may be empty before install)..."
kubectl get crd | grep -E 'istio.io|telemetry.istio.io' || warn "Istio CRDs not found yet (expected before install)."

log "Prerequisite checks completed."
