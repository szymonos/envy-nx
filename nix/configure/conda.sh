#!/usr/bin/env bash
# Post-install conda/miniforge configuration (cross-platform, Nix variant)
# Nix does not package miniforge, so we install it via the official installer.
: '
nix/configure/conda.sh
'
set -eo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_ROOT/.assets/config/shell_cfg/functions.sh"
. "$SCRIPT_ROOT/.assets/lib/helpers.sh"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

find_conda() {
  local candidates=(
    "$HOME/miniforge3/bin/conda"
    "$HOME/miniforge3/condabin/conda"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  if command -v conda &>/dev/null; then
    command -v conda
    return 0
  fi
  return 1
}

# install miniforge if not present
if ! find_conda &>/dev/null; then
  info "installing Miniforge..."
  OS_NAME="$(uname -s)"
  ARCH="$(uname -m)"
  case "$OS_NAME" in
  Linux) os_label="Linux" ;;
  Darwin) os_label="MacOSX" ;;
  *)
    err "Unsupported OS: $OS_NAME"
    exit 1
    ;;
  esac
  MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-${os_label}-${ARCH}.sh"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  download_file --uri "$MINIFORGE_URL" --target_dir "$TMP_DIR"
  bash "$TMP_DIR/$(basename "$MINIFORGE_URL")" -b -p "$HOME/miniforge3"
fi

# miniforge post-install
conda_bin="$(find_conda || true)"
if [[ -n "$conda_bin" ]]; then
  # initialize conda shell function so `conda activate` works inside this script
  eval "$("$conda_bin" shell.bash hook 2>/dev/null)"

  # patch conda's certifi for MITM proxy certs - must run inside conda base
  # so `pip show certifi` resolves to conda's own python, not whatever else is on PATH
  _fix_conda_certs() {
    conda activate base || return 1
    fixcertpy || warn "certifi certificate fix failed - pip/conda may have SSL issues behind proxy"
    conda deactivate
  }

  _fix_conda_certs
  info "updating conda..."
  "$conda_bin" update --name base --channel conda-forge conda --yes --update-all 2>/dev/null || warn "conda update failed"
  # update may replace cacert.pem - re-patch
  _fix_conda_certs
  "$conda_bin" clean --yes --all 2>/dev/null || true
  # initialize shell integration and disable auto-activate
  "$conda_bin" init bash zsh 2>/dev/null || warn "conda shell init failed - run 'conda init bash zsh' manually"
  "$conda_bin" config --set auto_activate_base false
  ok "conda configured"
else
  warn "conda binary not found after miniforge install"
fi
