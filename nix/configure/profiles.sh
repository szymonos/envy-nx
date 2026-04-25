#!/usr/bin/env bash
# Post-install bash profile setup (cross-platform, Nix variant)
# Provisions config files, builds CA bundle, delegates profile
# block management to nx.
: '
nix/configure/profiles.sh
'
set -eo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_ROOT/../.." && pwd)"
LIB="$REPO_ROOT/.assets/lib"
BASH_CFG="$REPO_ROOT/.assets/config/bash_cfg"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok()   { printf "\e[32m%s\e[0m\n" "$*"; }

# shellcheck source=../../.assets/lib/certs.sh
source "$LIB/certs.sh"

info "configuring bash profile..."

# create .bashrc if missing
[ -f "$HOME/.bashrc" ] || touch "$HOME/.bashrc"

# ---------------------------------------------------------------------------
# Copy alias/function files to durable location
# ---------------------------------------------------------------------------
_install_cfg_file() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
  fi
}

_install_cfg_file "$BASH_CFG/aliases_nix.sh"    "$HOME/.config/bash/aliases_nix.sh"
_install_cfg_file "$BASH_CFG/aliases_git.sh"    "$HOME/.config/bash/aliases_git.sh"
_install_cfg_file "$BASH_CFG/aliases_kubectl.sh" "$HOME/.config/bash/aliases_kubectl.sh"
_install_cfg_file "$BASH_CFG/functions.sh"      "$HOME/.config/bash/functions.sh"

# ---------------------------------------------------------------------------
# Copy overlay shell config files (if overlay directory is active)
# ---------------------------------------------------------------------------
if [ -n "${OVERLAY_DIR:-}" ] && [ -d "$OVERLAY_DIR/bash_cfg" ]; then
  for _overlay_cfg in "$OVERLAY_DIR/bash_cfg"/*.sh; do
    [ -f "$_overlay_cfg" ] || continue
    _install_cfg_file "$_overlay_cfg" "$HOME/.config/bash/$(basename "$_overlay_cfg")"
  done
fi

# ---------------------------------------------------------------------------
# Build the CA bundle and configure VS Code Server certs
# ---------------------------------------------------------------------------
build_ca_bundle
setup_vscode_certs

# ---------------------------------------------------------------------------
# Delegate managed block rendering to nx
# ---------------------------------------------------------------------------
# shellcheck source=../../.assets/lib/nx.sh
source "$LIB/nx.sh"
_nx_profile_regenerate

ok "bash profile configured"
