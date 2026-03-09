#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_CHECK=false

usage() {
  cat <<'EOF'
Usage: scripts/00_install_prereq.sh [--skip-check]

Installs required CLI tools for this project:
  - kubectl
  - istioctl
  - helm
  - minikube

Behavior:
  - Idempotent: installed tools are skipped
  - macOS: uses Homebrew
  - Linux: currently unsupported by this installer (manual install required)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-check) SKIP_CHECK=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_with_brew_formula() {
  local cmd_name="$1"
  local formula="$2"
  if command_exists "${cmd_name}"; then
    log "${cmd_name} already installed, skipping."
    return 0
  fi
  log "Installing ${cmd_name} via brew formula ${formula}..."
  brew install "${formula}" || err "Failed to install ${cmd_name} (${formula})"
}

install_minikube_macos() {
  if command_exists minikube; then
    log "minikube already installed, skipping."
    return 0
  fi
  log "Installing minikube via brew formula..."
  if brew install minikube; then
    return 0
  fi
  warn "brew formula install failed, trying cask..."
  brew install --cask minikube || err "Failed to install minikube (formula and cask both failed)"
}

install_on_macos() {
  command_exists brew || err "Homebrew not found. Install brew first: https://brew.sh/"

  install_with_brew_formula kubectl kubernetes-cli
  install_with_brew_formula helm helm
  install_with_brew_formula istioctl istioctl
  install_minikube_macos
}

main() {
  local os_name
  os_name="$(uname -s)"

  case "${os_name}" in
    Darwin)
      install_on_macos
      ;;
    Linux)
      err "Linux auto-install is not implemented in this script. Please install kubectl/istioctl/helm/minikube manually, then run scripts/00_prereq_check.sh."
      ;;
    *)
      err "Unsupported OS: ${os_name}"
      ;;
  esac

  log "Install step finished."
  if [[ "${SKIP_CHECK}" == false ]]; then
    log "Running prerequisite validation..."
    bash "${ROOT_DIR}/scripts/00_prereq_check.sh"
  fi
}

main "$@"
