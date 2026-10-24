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
# certs.sh defines cert_intercept (re-exported by functions.sh for the
# user-shell alias). Lives in .assets/lib/ as the canonical home but is
# deployed alongside functions.sh so the user shell can source it.
_install_cfg_file "$LIB/certs.sh" "$HOME/.config/shell/certs.sh"

# ---------------------------------------------------------------------------
# Copy overlay shell config files to ~/.config/shell/overlay/, which the managed
# block sources. OVERLAY_DIR lists the org overlay first; walking it backwards
# lets a personal file win over an org file of the same name. Files no overlay
# provides any more are removed.
# ---------------------------------------------------------------------------
_overlay_dst="$HOME/.config/shell/overlay"
_overlay_keep=" "
while IFS= read -r _overlay_dir; do
  [ -n "$_overlay_dir" ] && [ -d "$_overlay_dir/shell_cfg" ] || continue
  for _overlay_cfg in "$_overlay_dir/shell_cfg"/*; do
    [ -f "$_overlay_cfg" ] || continue
    _overlay_name="$(basename "$_overlay_cfg")"
    # the same names the profile renderer sources; the keep list is space-delimited
    case "$_overlay_name" in *[!A-Za-z0-9_.-]*) continue ;; esac
    [[ "$_overlay_keep" == *" $_overlay_name "* ]] && continue
    _overlay_keep+="$_overlay_name "
    _install_cfg_file "$_overlay_cfg" "$_overlay_dst/$_overlay_name"
  done
done < <(printf '%s\n' "${OVERLAY_DIR:-}" | tr ':' '\n' | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }')
for _overlay_cfg in "$_overlay_dst"/*; do
  [ -f "$_overlay_cfg" ] || continue
  [[ "$_overlay_keep" == *" $(basename "$_overlay_cfg") "* ]] || rm -f "$_overlay_cfg"
done

# ---------------------------------------------------------------------------
# Build the CA bundle and configure VS Code Server
# ---------------------------------------------------------------------------
build_ca_bundle
setup_vscode_certs
setup_vscode_server_env
setup_vscode_macos_env

# ---------------------------------------------------------------------------
# Delegate managed block rendering to nx
# ---------------------------------------------------------------------------
# shellcheck source=../../.assets/lib/nx.sh
source "$LIB/nx.sh"
_nx_profile_regenerate

ok "bash profile configured"
