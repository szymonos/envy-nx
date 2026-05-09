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

# Filter user-supplied package names by whether they are claimed by a
# managed scope. Args after $1 are the package names; $1 is the action
# verb ("install" or "remove") which only changes the wording of the
# stderr message ("already installed in scope X" vs "managed by scope X").
#
# stdout: one un-managed pkg per line (the args that passed the filter).
# stderr: one warning per scope-managed pkg.
#
# Closes FU-001 (the inline-filter test-isolation problem from the
# 2026-05-09 test-quality cycle): tests can drive this helper directly
# with a stubbed `_nx_all_scope_pkgs` instead of needing the full verb
# wrapper. Subsumes F-005's request for an `_nx_lookup_pkg_scope` helper
# (the lookup is centralized here, single source of truth).
function _nx_filter_scope_args() {
  local action="$1"
  shift
  local scope_pkgs p in_scope
  scope_pkgs="$(_nx_all_scope_pkgs)"
  for p in "$@"; do
    in_scope="$(printf '%s\n' "$scope_pkgs" | grep -m1 "^${p}	" 2>/dev/null | cut -f2)"
    if [ -n "$in_scope" ]; then
      case "$action" in
      install)
        printf "\e[33m%s is already installed in scope '%s'\e[0m\n" "$p" "$in_scope" >&2
        ;;
      remove)
        printf "\e[33m%s is managed by scope '%s' - use: nx scope remove %s\e[0m\n" "$p" "$in_scope" "$in_scope" >&2
        ;;
      esac
    else
      printf '%s\n' "$p"
    fi
  done
}

function _nx_find_lib() {
  local name="$1"
  # NX_LIB_DIR is an explicit override - lets tests and dev iteration
  # point at .assets/lib/ in a repo checkout without copying files into
  # ~/.config/nix-env/. Wins over auto-discovery when set + readable.
  if [ -n "${NX_LIB_DIR:-}" ] && [ -f "$NX_LIB_DIR/$name" ]; then
    echo "$NX_LIB_DIR/$name"
    return 0
  fi
  local script_dir
  # BASH_SOURCE-based self-location with a zsh fallback: in zsh BASH_SOURCE[0]
  # is empty, the else branch falls through to the durable config dir.
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
#
# If any family file is missing the install is in a broken intermediate
# state (typically: cross-major upgrade where an old `_nx_self_sync` knew
# only about an older file list). Print actionable recovery instructions
# and replace `nx_main` with a stub that surfaces the same message on every
# subsequent invocation - cleaner than letting `nx <verb>` fall through to
# `command not found: _nx_<family>_<verb>`.
_nx_missing_families=""
for _nx_family in nx_pkg.sh nx_scope.sh nx_profile.sh nx_lifecycle.sh; do
  _nx_family_path="$(_nx_find_lib "$_nx_family")" || {
    _nx_missing_families="$_nx_missing_families $_nx_family"
    continue
  }
  # shellcheck source=/dev/null
  source "$_nx_family_path"
done
if [ -n "$_nx_missing_families" ]; then
  _nx_repo_path="$(_nx_read_install_field repo_path)"
  printf "\e[31mnx: environment is incomplete - missing family file(s):%s\e[0m\n" "$_nx_missing_families" >&2
  printf "\e[31mthis usually means a cross-version upgrade left the install half-synced.\e[0m\n" >&2
  if [ -n "$_nx_repo_path" ] && [ -d "$_nx_repo_path/.git" ]; then
    printf "\e[33mrecover with:\e[0m bash %s/nix/setup.sh\n" "$_nx_repo_path" >&2
  else
    printf "\e[33mrecover with:\e[0m clone https://github.com/szymonos/envy-nx and run nix/setup.sh from the clone\n" >&2
  fi
  function nx_main() {
    printf "\e[31mnx is unusable - run the recovery command printed at shell startup, then exec \$SHELL\e[0m\n" >&2
    return 1
  }
  unset _nx_family _nx_family_path _nx_missing_families _nx_repo_path
  return 0 2>/dev/null || true
fi
unset _nx_family _nx_family_path _nx_missing_families

# --- Main dispatch ---

function nx_main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true
  case "$cmd" in
  # >>> nx-main generated >>> (regenerate: python3 -m tests.hooks.gen_nx_completions)
  search) _nx_pkg_search "$@" ;;
  install | add) _nx_pkg_install "$@" ;;
  remove | uninstall) _nx_pkg_remove "$@" ;;
  upgrade | update) _nx_pkg_upgrade ;;
  rollback) _nx_pkg_rollback ;;
  list | ls) _nx_pkg_list ;;
  scope) _nx_scope_dispatch "$@" ;;
  overlay) _nx_overlay_dispatch "$@" ;;
  pin) _nx_pin_dispatch "$@" ;;
  profile) _nx_profile_dispatch "$@" ;;
  setup) _nx_lifecycle_setup "$@" ;;
  self) _nx_self_dispatch "$@" ;;
  doctor) _nx_lifecycle_doctor "$@" ;;
  prune) _nx_pkg_prune ;;
  gc | clean) _nx_pkg_gc ;;
  version) _nx_lifecycle_version ;;
  help | -h | --help) _nx_lifecycle_help ;;
  *)
    printf "\e[31mUnknown command: %s\e[0m\n" "$cmd" >&2
    _nx_lifecycle_help
    return 1
    ;;
  # <<< nx-main generated <<<
  esac
}

# --- Execution guard ---
# In bash: fires when nx.sh is run as a script (not sourced).
# In zsh: BASH_SOURCE[0] is empty, comparison is false, nx_main is not auto-invoked.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  nx_main "$@"
fi
