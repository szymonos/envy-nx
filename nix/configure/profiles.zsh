#!/usr/bin/env zsh
# Post-install zsh profile setup (cross-platform, Nix variant)
# Provisions config files, installs zsh plugins, delegates profile
# block management to nx.
: '
nix/configure/profiles.zsh
'
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
REPO_ROOT="${SCRIPT_ROOT:h:h}"
LIB="$REPO_ROOT/.assets/lib"
SHELL_CFG="$REPO_ROOT/.assets/config/shell_cfg"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok()   { printf "\e[32m%s\e[0m\n" "$*"; }

# shellcheck source=../../.assets/lib/certs.sh
source "$LIB/certs.sh"
# shellcheck source=../../.assets/lib/vscode.sh
source "$LIB/vscode.sh"
# shellcheck source=../../.assets/lib/helpers.sh
source "$LIB/helpers.sh"

info "configuring zsh profile..."

# create .zshrc if missing
[[ -f "$HOME/.zshrc" ]] || touch "$HOME/.zshrc"

# ---------------------------------------------------------------------------
# Copy alias/function files to durable location
# ---------------------------------------------------------------------------
_install_cfg_file() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  # Skip when content matches; otherwise install atomically so a shell
  # opening a new terminal mid-setup never sources a half-written file.
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install_atomic "$src" "$dst"
  fi
}

_install_cfg_file "$SHELL_CFG/aliases_nix.sh"      "$HOME/.config/shell/aliases_nix.sh"
_install_cfg_file "$SHELL_CFG/aliases_git.sh"      "$HOME/.config/shell/aliases_git.sh"
_install_cfg_file "$SHELL_CFG/aliases_kubectl.sh"  "$HOME/.config/shell/aliases_kubectl.sh"
_install_cfg_file "$SHELL_CFG/functions.sh"        "$HOME/.config/shell/functions.sh"
_install_cfg_file "$SHELL_CFG/completions.zsh"     "$HOME/.config/shell/completions.zsh"

# ---------------------------------------------------------------------------
# Copy overlay shell config files (if overlay directory is active)
# ---------------------------------------------------------------------------
if [[ -n "${OVERLAY_DIR:-}" ]] && [[ -d "$OVERLAY_DIR/shell_cfg" ]]; then
  for _overlay_cfg in "$OVERLAY_DIR/shell_cfg"/*; do
    [[ -f "$_overlay_cfg" ]] || continue
    _install_cfg_file "$_overlay_cfg" "$HOME/.config/shell/${_overlay_cfg:t}"
  done
fi

# ---------------------------------------------------------------------------
# Install zsh plugins (git clone / pull)
# ---------------------------------------------------------------------------
ZSH_PLUGIN_DIR="$HOME/.zsh"
mkdir -p "$ZSH_PLUGIN_DIR"

typeset -A ZSH_PLUGINS
ZSH_PLUGINS=(
  zsh-autocomplete        'https://github.com/marlonrichert/zsh-autocomplete.git'
  zsh-make-complete       'https://github.com/22peacemaker/zsh-make-complete.git'
  zsh-autosuggestions     'https://github.com/zsh-users/zsh-autosuggestions.git'
  zsh-syntax-highlighting 'https://github.com/zsh-users/zsh-syntax-highlighting.git'
)

ZSH_PLUGIN_ORDER=(zsh-autocomplete zsh-make-complete zsh-autosuggestions zsh-syntax-highlighting)

for plugin in "${ZSH_PLUGIN_ORDER[@]}"; do
  local url="${ZSH_PLUGINS[$plugin]}"
  if [[ -d "$ZSH_PLUGIN_DIR/$plugin" ]]; then
    git -C "$ZSH_PLUGIN_DIR/$plugin" pull --quiet 2>/dev/null || true
  else
    git clone --depth 1 "$url" "$ZSH_PLUGIN_DIR/$plugin"
    ok "installed zsh plugin: $plugin"
  fi
done

# ---------------------------------------------------------------------------
# Build the CA bundle and configure VS Code Server
# ---------------------------------------------------------------------------
build_ca_bundle
setup_vscode_certs
setup_vscode_server_env

# ---------------------------------------------------------------------------
# Delegate managed block rendering to nx
# ---------------------------------------------------------------------------
bash "$LIB/nx.sh" profile regenerate

ok "zsh profile configured"
