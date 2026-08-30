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
# _nx_apply, _nx_validate_pkg, _nx_clear_stale_caches, _nx_scope_pkgs,
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
  printf "\e[90mvalidating %s...\e[0m\r" "$*"
  local validated=() valid_set p
  valid_set="$(_nx_validate_pkgs "$@")"
  for p in "$@"; do
    if printf '%s\n' "$valid_set" | grep -Fqx "$p" 2>/dev/null; then
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
  # Abort before mutating packages.nix if the backup could not be made - else a
  # later rollback would see an empty backup and rm the existing manifest.
  local _backup
  _backup="$(_nx_backup_pkgs)" || {
    printf "\e[31mcould not back up %s - aborting install to protect the manifest\e[0m\n" "$_NX_PKG_FILE" >&2
    return 1
  }
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
  if [ "$(cat "$_NX_PKG_FILE" 2>/dev/null)" != "$_before" ]; then
    _nx_apply_or_rollback "$_backup"
  else
    [ -n "$_backup" ] && command rm -f "$_backup"
  fi
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
  # Abort before mutating packages.nix if the backup could not be made - else a
  # later rollback would see an empty backup and rm the existing manifest.
  local _backup
  _backup="$(_nx_backup_pkgs)" || {
    printf "\e[31mcould not back up %s - aborting remove to protect the manifest\e[0m\n" "$_NX_PKG_FILE" >&2
    return 1
  }
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
  if [ "$(cat "$_NX_PKG_FILE" 2>/dev/null)" != "$_before" ]; then
    _nx_apply_or_rollback "$_backup"
  else
    [ -n "$_backup" ] && command rm -f "$_backup"
  fi
}

function _nx_pkg_upgrade() {
  local _want_latest=false _arg
  for _arg in "$@"; do
    case "$_arg" in
    --latest) _want_latest=true ;;
    *)
      printf "\e[31munknown flag: %s\e[0m\n" "$_arg" >&2
      printf "Usage: nx upgrade [--latest]\n" >&2
      return 1
      ;;
    esac
  done

  # Records the failed attempt so `nx doctor` can surface a machine that
  # quietly stopped advancing; cleared on success. nx_doctor.sh is standalone
  # after install (it never sources nx.sh), so it hardcodes the same name.
  local _err_file="$_NX_ENV_DIR/last_upgrade_error"
  local _resolved _mode _rev
  _resolved="$(_nx_rev_resolve "$_NX_ENV_DIR" "$_want_latest")"
  _mode="${_resolved%% *}"
  _rev=""
  case "$_resolved" in *" "*) _rev="${_resolved#* }" ;; esac

  # Refuse to move backwards. Without this, a user who ran `nx upgrade
  # --latest` would be dragged back to an older nixpkgs by the next plain
  # upgrade whenever the CI bump is behind them.
  if [ "$_mode" = "validated" ]; then
    local _cand_epoch
    _cand_epoch="$(_nx_rev_json_field "$_NX_ENV_DIR/nixpkgs_rev.json" lastModified)"
    if _nx_rev_is_downgrade "$_NX_ENV_DIR" "$_cand_epoch"; then
      printf "\e[96malready at or ahead of the validated revision (%s) - nothing to do.\e[0m\n" "${_rev:0:12}"
      printf "\e[90mto go back deliberately: nx pin set %s\e[0m\n" "${_rev:0:12}"
      return 0
    fi
  fi

  printf "\e[96mupgrading packages...\e[0m\n"

  # flake.lock is rewritten before the slow, cancellable `nix profile upgrade`,
  # so a Ctrl-C or a build failure would otherwise leave the lock naming a
  # revision the profile never received. Snapshot it and put it back on
  # failure: the lock is already the per-machine record of the revision in
  # use, so restoring it is the whole "stay on the last working rev" contract -
  # no second bookkeeping file to drift from profile generations.
  local _lock="$_NX_ENV_DIR/flake.lock" _lock_backup=""
  if [ -f "$_lock" ]; then
    _lock_backup="$(mktemp "${_lock}.bak.XXXXXX")" || {
      printf "\e[31mcould not back up flake.lock - aborting to protect the current revision\e[0m\n" >&2
      return 1
    }
    command cp "$_lock" "$_lock_backup" || {
      command rm -f "$_lock_backup"
      printf "\e[31mcould not back up flake.lock - aborting to protect the current revision\e[0m\n" >&2
      return 1
    }
  fi

  # nix writes progress (the live progress bar and per-path "copying path"
  # lines) to stderr; let it through so the user sees what's happening
  # during the network-bound flake update.
  case "$_mode" in
  pinned)
    printf "\e[96mpinning nixpkgs to %s (nx pin)\e[0m\n" "$_rev"
    nix flake lock --override-input nixpkgs "github:nixos/nixpkgs/$_rev" "$_NX_ENV_DIR" ||
      printf "\e[33mflake lock failed - using existing lock\e[0m\n" >&2
    ;;
  validated)
    printf "\e[96musing validated nixpkgs %s\e[0m\n" "${_rev:0:12}"
    nix flake lock --override-input nixpkgs "github:nixos/nixpkgs/$_rev" "$_NX_ENV_DIR" ||
      printf "\e[33mflake lock failed - using existing lock\e[0m\n" >&2
    ;;
  latest)
    printf "\e[33musing nixpkgs-unstable HEAD - not validated by CI\e[0m\n"
    nix flake update --flake "$_NX_ENV_DIR" ||
      printf "\e[33mflake update failed (network issue?) - using existing lock\e[0m\n" >&2
    ;;
  *)
    printf "\e[33mno validated revision found - keeping the current lock\e[0m\n" >&2
    printf "\e[90mrun nx self update to fetch one\e[0m\n" >&2
    ;;
  esac

  if ! nix profile upgrade nix-env; then
    printf "\e[31mnix profile upgrade failed\e[0m\n" >&2
    if [ -n "$_lock_backup" ]; then
      command mv "$_lock_backup" "$_lock"
      printf "\e[33mrestored the previous flake.lock - still on the last working revision\e[0m\n" >&2
    fi
    # Record what was actually attempted. `latest` really did reach for HEAD;
    # `none` touched no lock at all, and naming HEAD there made nx doctor
    # report an upgrade that never happened.
    local _target
    case "$_mode" in
    latest) _target="nixpkgs-unstable HEAD" ;;
    none) _target="existing lock (no validated rev synced)" ;;
    *) _target="$_rev" ;;
    esac
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target" >"$_err_file" 2>/dev/null
    return 1
  fi

  [ -n "$_lock_backup" ] && command rm -f "$_lock_backup"
  command rm -f "$_err_file"
  _nx_clear_stale_caches
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
  _nx_clear_stale_caches
}

function _nx_pkg_rollback() {
  nix profile rollback || {
    printf "\e[31mnix profile rollback failed\e[0m\n" >&2
    return 1
  }
  printf "\e[32mRolled back to previous profile generation.\e[0m\n"
  printf "Restart your shell to apply changes.\n"
}
