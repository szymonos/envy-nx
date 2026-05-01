#!/usr/bin/env bash
: '
.assets/lib/nx.sh
# standalone execution
bash .assets/lib/nx.sh help
bash .assets/lib/nx.sh scope list
bash .assets/lib/nx.sh version
# sourced mode (for testing / bash wrapper)
source .assets/lib/nx.sh
nx_main help
'

# nx CLI entry point. Defines the shared helpers that every verb family
# needs (read/write packages, apply nix-profile changes, list scopes,
# locate sibling library files), then sources the four verb-family files
# and dispatches `nx <verb>` to `_nx_<family>_<verb>`.
#
# Family layout (all in the same directory as nx.sh, both at dev time and
# after `phase_bootstrap_sync_env_dir` copies them to ~/.config/nix-env/):
#   nx_pkg.sh        search / install / remove / upgrade / list / prune / gc / rollback
#   nx_scope.sh      scope / overlay / pin
#   nx_profile.sh    profile + managed-block rendering (also called from profiles.sh)
#   nx_lifecycle.sh  setup / self / doctor / version / help

# Constants
_NX_ENV_DIR="$HOME/.config/nix-env"
_NX_PKG_FILE="$_NX_ENV_DIR/packages.nix"
_NX_INSTALL_JSON="$HOME/.config/dev-env/install.json"
_NX_DEFAULT_REPO_URL="https://github.com/szymonos/envy-nx.git"

# --- Shared helpers ---

function _nx_read_pkgs() {
  [ -f "$_NX_PKG_FILE" ] && sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' "$_NX_PKG_FILE"
}

function _nx_write_pkgs() {
  local tmp
  tmp="$(mktemp)"
  printf '[\n' >"$tmp"
  sort -u | while IFS= read -r name; do
    [ -n "$name" ] && printf '  "%s"\n' "$name" >>"$tmp"
  done
  printf ']\n' >>"$tmp"
  mv "$tmp" "$_NX_PKG_FILE"
}

function _nx_apply() {
  printf "\e[96mapplying changes...\e[0m\n"
  nix profile upgrade nix-env || {
    printf "\e[31mnix profile upgrade failed\e[0m\n" >&2
    return 1
  }
  printf "\e[32mdone.\e[0m\n"
}

# Clear pwsh module-analysis cache + startup profile data. Both are pure
# caches (regenerate on next pwsh launch) but reference module paths that
# go stale after `nix store gc` (old pwsh GC'd) or `nix profile upgrade`
# (bundled module versions/paths shift). Without this, `Install-PSResource`
# and other PSResourceGet operations crash with "Could not find a part of
# the path .../Modules/PSReadLine/<ver>/PSReadLine.format.ps1xml".
function _nx_clear_pwsh_cache() {
  local _cache_dir="$HOME/.cache/powershell"
  [ -d "$_cache_dir" ] || return 0
  local _cleared=0 _f
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    rm -f "$_f" && _cleared=$((_cleared + 1))
  done < <(find "$_cache_dir" -maxdepth 1 -type f \( -name 'ModuleAnalysisCache-*' -o -name 'StartupProfileData-*' \) 2>/dev/null)
  [ "$_cleared" -gt 0 ] &&
    printf "\e[90mCleared %d stale PowerShell cache file(s) (regenerates on next pwsh launch).\e[0m\n" "$_cleared"
  return 0
}

function _nx_validate_pkg() {
  nix eval "nixpkgs#${1}.name" &>/dev/null
}

function _nx_scope_pkgs() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n '/\[/,/\]/{
    s/^[[:space:]]*\([a-zA-Z][a-zA-Z0-9_-]*\).*/\1/p
  }' "$file"
}

function _nx_scopes() {
  local config_nix="$_NX_ENV_DIR/config.nix"
  [ -f "$config_nix" ] || return 0
  sed -n '/scopes[[:space:]]*=[[:space:]]*\[/,/\]/{
    s/^[[:space:]]*"\([^"]*\)".*/\1/p
  }' "$config_nix"
}

function _nx_is_init() {
  local config_nix="$_NX_ENV_DIR/config.nix"
  [ -f "$config_nix" ] || {
    echo "false"
    return
  }
  sed -n -E 's/^[[:space:]]*isInit[[:space:]]*=[[:space:]]*(true|false).*/\1/p' "$config_nix"
}

function _nx_all_scope_pkgs() {
  local scopes_dir="$_NX_ENV_DIR/scopes"
  [ -d "$scopes_dir" ] || return 0
  local pkg
  while IFS= read -r pkg; do
    [ -n "$pkg" ] && printf '%s\t%s\n' "$pkg" "base"
  done < <(_nx_scope_pkgs "$scopes_dir/base.nix")
  if [ "$(_nx_is_init)" = "true" ]; then
    while IFS= read -r pkg; do
      [ -n "$pkg" ] && printf '%s\t%s\n' "$pkg" "base_init"
    done < <(_nx_scope_pkgs "$scopes_dir/base_init.nix")
  fi
  local scopes s
  scopes="$(_nx_scopes)"
  if [ -n "$scopes" ]; then
    while IFS= read -r s; do
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf '%s\t%s\n' "$pkg" "$s"
      done < <(_nx_scope_pkgs "$scopes_dir/$s.nix")
    done <<<"$scopes"
  fi
}

function _nx_find_lib() {
  local name="$1"
  local script_dir
  # BASH_SOURCE-based self-location with a zsh fallback: in zsh BASH_SOURCE[0]
  # is empty, the else branch falls through to the durable config dir.
  if [ -n "${BASH_SOURCE[0]:-}" ]; then                        # zsh-ok: guarded by [-n]; falls through in zsh
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # zsh-ok: only reached in bash
  else
    script_dir="$HOME/.config/nix-env"
  fi
  local candidate
  for candidate in \
    "$script_dir/$name" \
    "$script_dir/../../.assets/lib/$name" \
    "$HOME/.config/nix-env/$name"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

function _nx_read_install_field() {
  local field="$1"
  [ -f "$_NX_INSTALL_JSON" ] || return 0
  if type jq &>/dev/null; then
    jq -r ".$field // empty" "$_NX_INSTALL_JSON" 2>/dev/null
  else
    sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_NX_INSTALL_JSON" | head -1
  fi
}

# --- Source verb-family files ---
# Family files live next to nx.sh both at dev time (.assets/lib/) and at
# runtime (~/.config/nix-env/, populated by phase_bootstrap_sync_env_dir).
# `_nx_find_lib` does the lookup with the same BASH_SOURCE/zsh fallback.
for _nx_family in nx_pkg.sh nx_scope.sh nx_profile.sh nx_lifecycle.sh; do
  _nx_family_path="$(_nx_find_lib "$_nx_family")" || {
    printf "\e[31mnx: family file %s not found\e[0m\n" "$_nx_family" >&2
    continue
  }
  # shellcheck source=/dev/null
  source "$_nx_family_path"
done
unset _nx_family _nx_family_path

# --- Main dispatch ---

function nx_main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true
  case "$cmd" in
  search) _nx_pkg_search "$@" ;;
  install | add) _nx_pkg_install "$@" ;;
  remove | uninstall) _nx_pkg_remove "$@" ;;
  upgrade | update) _nx_pkg_upgrade "$@" ;;
  list | ls) _nx_pkg_list ;;
  prune) _nx_pkg_prune ;;
  gc | clean) _nx_pkg_gc ;;
  rollback) _nx_pkg_rollback ;;
  scope) _nx_scope_dispatch "$@" ;;
  overlay) _nx_overlay_dispatch "$@" ;;
  pin) _nx_pin_dispatch "$@" ;;
  profile) _nx_profile_dispatch "$@" ;;
  setup) _nx_lifecycle_setup "$@" ;;
  self) _nx_lifecycle_self "$@" ;;
  doctor) _nx_lifecycle_doctor "$@" ;;
  version) _nx_lifecycle_version ;;
  help | -h | --help) _nx_lifecycle_help ;;
  *)
    printf "\e[31mUnknown command: %s\e[0m\n" "$cmd" >&2
    _nx_lifecycle_help
    return 1
    ;;
  esac
}

# --- Execution guard ---
# In bash: fires when nx.sh is run as a script (not sourced).
# In zsh: BASH_SOURCE[0] is empty, comparison is false, nx_main is not auto-invoked.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then # zsh-ok: false in zsh; nx_main only runs under bash standalone
  nx_main "$@"
fi
