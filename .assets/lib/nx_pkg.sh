: '
# Sourced by nx.sh, not run directly. After `source .assets/lib/nx.sh`:
nx_main install ripgrep fd
nx_main remove ripgrep
nx_main upgrade
nx_main list
'

# nx package-management verbs (search/install/remove/upgrade/list/prune/gc/rollback).
#
# Sourced by nx.sh; expects shared helpers (_nx_read_pkgs, _nx_write_pkgs,
# _nx_apply, _nx_validate_pkg, _nx_clear_pwsh_cache, _nx_scope_pkgs,
# _nx_scopes, _nx_is_init, _nx_all_scope_pkgs) and constants (_NX_ENV_DIR,
# _NX_PKG_FILE) to already be defined.

function _nx_pkg_search() {
  [ $# -eq 0 ] && {
    echo "Usage: nx search <query>" >&2
    return 1
  }
  local query="$*"
  nix search nixpkgs "$query" --json |
    jq -r 'to_entries[] | "[1m* \(.key | split(".")[-1])[0m (\(.value.version))\n  \(.value.description // "")\n"'
}

function _nx_pkg_install() {
  [ $# -eq 0 ] && {
    echo "Usage: nx install <pkg> [pkg...]" >&2
    return 1
  }
  local validated=() p
  for p in "$@"; do
    printf "\e[90mvalidating %s...\e[0m\r" "$p"
    if _nx_validate_pkg "$p"; then
      validated+=("$p")
    else
      printf "\e[31m%s not found in nixpkgs\e[0m\n" "$p" >&2
    fi
  done
  [ ${#validated[@]} -eq 0 ] && return 1
  # Filter out scope-managed pkgs; helper emits the "already in scope X"
  # warnings to stderr. Bash 3.2 macOS lacks mapfile, so accumulate via
  # a while-read loop.
  local filtered=() current _before
  while IFS= read -r p; do
    [ -n "$p" ] && filtered+=("$p")
  done < <(_nx_filter_scope_args install "${validated[@]}")
  [ ${#filtered[@]} -eq 0 ] && return 0
  current="$(_nx_read_pkgs)"
  _before="$(cat "$_NX_PKG_FILE" 2>/dev/null)"
  {
    [ -n "$current" ] && printf '%s\n' "$current"
    for p in "${filtered[@]}"; do
      if printf '%s\n' "$current" | grep -qx "$p" 2>/dev/null; then
        printf "\e[33m%s is already installed (extra)\e[0m\n" "$p" >&2
      else
        printf '%s\n' "$p"
        printf "\e[32madded %s\e[0m\n" "$p" >&2
      fi
    done
  } | _nx_write_pkgs
  [ "$(cat "$_NX_PKG_FILE" 2>/dev/null)" != "$_before" ] && _nx_apply
}

function _nx_pkg_remove() {
  [ $# -eq 0 ] && {
    echo "Usage: nx remove <pkg> [pkg...]" >&2
    return 1
  }
  # Filter out scope-managed pkgs; helper emits the "managed by scope X"
  # warnings to stderr. Bash 3.2 macOS lacks mapfile, so accumulate via
  # a while-read loop.
  local filtered_args=() p
  while IFS= read -r p; do
    [ -n "$p" ] && filtered_args+=("$p")
  done < <(_nx_filter_scope_args remove "$@")
  [ ${#filtered_args[@]} -eq 0 ] && return 0
  local current _before
  current="$(_nx_read_pkgs)"
  if [ -z "$current" ]; then
    printf "\e[33mNo user packages installed.\e[0m\n"
    return 0
  fi
  _before="$(cat "$_NX_PKG_FILE" 2>/dev/null)"
  local remove_pattern=" ${filtered_args[*]} "
  {
    while IFS= read -r p; do
      if [[ " $remove_pattern " == *" $p "* ]]; then
        printf "\e[32mremoved %s\e[0m\n" "$p" >&2
      else
        printf '%s\n' "$p"
      fi
    done <<<"$current"
  } | _nx_write_pkgs
  for p in "${filtered_args[@]}"; do
    if ! printf '%s\n' "$current" | grep -qx "$p" 2>/dev/null; then
      printf "\e[33m%s is not installed - skipping\e[0m\n" "$p" >&2
    fi
  done
  [ "$(cat "$_NX_PKG_FILE" 2>/dev/null)" != "$_before" ] && _nx_apply
}

function _nx_pkg_upgrade() {
  printf "\e[96mupgrading packages...\e[0m\n"
  local _pinned_rev=""
  [ -f "$_NX_ENV_DIR/pinned_rev" ] && _pinned_rev="$(tr -d '[:space:]' <"$_NX_ENV_DIR/pinned_rev")"
  # nix writes progress (the live progress bar and per-path "copying path"
  # lines) to stderr; let it through so the user sees what's happening
  # during the network-bound flake update.
  if [ -n "$_pinned_rev" ]; then
    printf "\e[96mpinning nixpkgs to %s\e[0m\n" "$_pinned_rev"
    nix flake lock --override-input nixpkgs "github:nixos/nixpkgs/$_pinned_rev" --flake "$_NX_ENV_DIR" ||
      printf "\e[33mflake lock failed - using existing lock\e[0m\n" >&2
  else
    nix flake update --flake "$_NX_ENV_DIR" ||
      printf "\e[33mflake update failed (network issue?) - using existing lock\e[0m\n" >&2
  fi
  nix profile upgrade nix-env || {
    printf "\e[31mnix profile upgrade failed\e[0m\n" >&2
    return 1
  }
  _nx_clear_pwsh_cache
  printf "\e[32mdone.\e[0m\n"
}

function _nx_pkg_list() {
  local env_dir="$_NX_ENV_DIR"
  local scopes_dir="$env_dir/scopes"
  local all_pkgs
  all_pkgs="$({
    if [ -d "$scopes_dir" ]; then
      local pkg
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf '%s\t(base)\n' "$pkg"
      done < <(_nx_scope_pkgs "$scopes_dir/base.nix")
      if [ "$(_nx_is_init)" = "true" ]; then
        while IFS= read -r pkg; do
          [ -n "$pkg" ] && printf '%s\t(base_init)\n' "$pkg"
        done < <(_nx_scope_pkgs "$scopes_dir/base_init.nix")
      fi
    fi
    local scopes s
    scopes="$(_nx_scopes)"
    if [ -n "$scopes" ]; then
      while IFS= read -r s; do
        while IFS= read -r pkg; do
          [ -n "$pkg" ] && printf '%s\t(%s)\n' "$pkg" "$s"
        done < <(_nx_scope_pkgs "$scopes_dir/$s.nix")
      done <<<"$scopes"
    fi
    local pkgs
    pkgs="$(_nx_read_pkgs)"
    if [ -n "$pkgs" ]; then
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf '%s\t(extra)\n' "$pkg"
      done <<<"$pkgs"
    fi
  } | sort -t$'\t' -k1,1 -u)"
  if [ -n "$all_pkgs" ]; then
    while IFS=$'\t' read -r name scope; do
      printf "  \e[1m*\e[0m %-24s \e[90m%s\e[0m\n" "$name" "$scope"
    done <<<"$all_pkgs"
  else
    printf "\e[33mNo packages installed.\e[0m Use \e[1mnx install <pkg>\e[0m or run \e[1mnix/setup.sh\e[0m.\n"
  fi
}

function _nx_pkg_prune() {
  local profile_json stale_names name
  profile_json="$(nix profile list --json 2>/dev/null)" || {
    printf "\e[31mFailed to list nix profile.\e[0m\n" >&2
    return 1
  }
  stale_names="$(printf '%s\n' "$profile_json" | jq -r '.elements | keys[] | select(. != "nix-env")')"
  if [ -z "$stale_names" ]; then
    printf "\e[32mNo stale profile entries found.\e[0m\n"
    return 0
  fi
  printf "\e[96mStale profile entries:\e[0m\n"
  while IFS= read -r name; do
    printf "  \e[1m*\e[0m %s\n" "$name"
  done <<<"$stale_names"
  printf "\e[96mRemoving...\e[0m\n"
  while IFS= read -r name; do
    nix profile remove "$name" && printf "\e[32mremoved %s\e[0m\n" "$name"
  done <<<"$stale_names"
  printf "\e[32mdone.\e[0m Run \e[1mnx gc\e[0m to free disk space.\n"
}

function _nx_pkg_gc() {
  nix profile wipe-history
  nix store gc
  _nx_clear_pwsh_cache
}

function _nx_pkg_rollback() {
  nix profile rollback || {
    printf "\e[31mnix profile rollback failed\e[0m\n" >&2
    return 1
  }
  printf "\e[32mRolled back to previous profile generation.\e[0m\n"
  printf "Restart your shell to apply changes.\n"
}
