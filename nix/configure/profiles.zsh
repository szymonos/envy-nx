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
BASH_CFG="$REPO_ROOT/.assets/config/bash_cfg"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok()   { printf "\e[32m%s\e[0m\n" "$*"; }

# shellcheck source=../../.assets/lib/certs.sh
source "$LIB/certs.sh"

info "configuring zsh profile..."

# create .zshrc if missing
[[ -f "$HOME/.zshrc" ]] || touch "$HOME/.zshrc"

# ---------------------------------------------------------------------------
# Copy alias/function files to durable location
# ---------------------------------------------------------------------------
_install_cfg_file() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    mkdir -p "${dst:h}"
    cp -f "$src" "$dst"
  fi
}

_install_cfg_file "$BASH_CFG/aliases_nix.sh"     "$HOME/.config/bash/aliases_nix.sh"
_install_cfg_file "$BASH_CFG/aliases_git.sh"     "$HOME/.config/bash/aliases_git.sh"
_install_cfg_file "$BASH_CFG/aliases_kubectl.sh" "$HOME/.config/bash/aliases_kubectl.sh"
_install_cfg_file "$BASH_CFG/functions.sh"       "$HOME/.config/bash/functions.sh"

# ---------------------------------------------------------------------------
# Copy overlay shell config files (if overlay directory is active)
# ---------------------------------------------------------------------------
if [[ -n "${OVERLAY_DIR:-}" ]] && [[ -d "$OVERLAY_DIR/bash_cfg" ]]; then
  for _overlay_cfg in "$OVERLAY_DIR/bash_cfg"/*.sh; do
    [[ -f "$_overlay_cfg" ]] || continue
    _install_cfg_file "$_overlay_cfg" "$HOME/.config/bash/${_overlay_cfg:t}"
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
# Build the CA bundle and configure VS Code Server certs
# ---------------------------------------------------------------------------
build_ca_bundle
setup_vscode_certs

# ---------------------------------------------------------------------------
# Delegate managed block rendering to nx
# ---------------------------------------------------------------------------
bash "$LIB/nx.sh" profile regenerate

ok "zsh profile configured"
