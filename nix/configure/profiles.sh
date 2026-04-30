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
SHELL_CFG="$REPO_ROOT/.assets/config/shell_cfg"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }

# shellcheck source=../../.assets/lib/certs.sh
source "$LIB/certs.sh"
# shellcheck source=../../.assets/lib/vscode.sh
source "$LIB/vscode.sh"
# shellcheck source=../../.assets/lib/helpers.sh
source "$LIB/helpers.sh"

info "configuring bash profile..."

# create .bashrc if missing
[ -f "$HOME/.bashrc" ] || touch "$HOME/.bashrc"

# ---------------------------------------------------------------------------
# Copy alias/function files to durable location
# ---------------------------------------------------------------------------
_install_cfg_file() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  # Skip when content matches; otherwise install atomically so a shell
  # opening a new terminal mid-setup never sources a half-written file.
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install_atomic "$src" "$dst"
  fi
}

_install_cfg_file "$SHELL_CFG/aliases_nix.sh" "$HOME/.config/shell/aliases_nix.sh"
_install_cfg_file "$SHELL_CFG/aliases_git.sh" "$HOME/.config/shell/aliases_git.sh"
_install_cfg_file "$SHELL_CFG/aliases_kubectl.sh" "$HOME/.config/shell/aliases_kubectl.sh"
_install_cfg_file "$SHELL_CFG/functions.sh" "$HOME/.config/shell/functions.sh"
_install_cfg_file "$SHELL_CFG/completions.bash" "$HOME/.config/shell/completions.bash"

# ---------------------------------------------------------------------------
# Copy overlay shell config files (if overlay directory is active)
# ---------------------------------------------------------------------------
if [ -n "${OVERLAY_DIR:-}" ] && [ -d "$OVERLAY_DIR/shell_cfg" ]; then
  for _overlay_cfg in "$OVERLAY_DIR/shell_cfg"/*; do
    [ -f "$_overlay_cfg" ] || continue
    _install_cfg_file "$_overlay_cfg" "$HOME/.config/shell/$(basename "$_overlay_cfg")"
  done
fi

# ---------------------------------------------------------------------------
# Build the CA bundle and configure VS Code Server
# ---------------------------------------------------------------------------
build_ca_bundle
setup_vscode_certs
setup_vscode_server_env

# ---------------------------------------------------------------------------
# Delegate managed block rendering to nx
# ---------------------------------------------------------------------------
# shellcheck source=../../.assets/lib/nx.sh
source "$LIB/nx.sh"
_nx_profile_regenerate

ok "bash profile configured"
