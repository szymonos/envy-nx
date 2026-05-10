# nx scope/overlay/pin verbs - the "config-shape" surface.
#
# Sourced by nx.sh; expects shared helpers (_nx_apply, _nx_validate_pkg,
# _nx_scope_pkgs, _nx_scopes, _nx_is_init, _nx_read_pkgs) and constants
# (_NX_ENV_DIR) to already be defined.

# Append packages to a local scope .nix file. Caller passes the absolute
# scope file path and the packages to add; we union with the existing
# package list, sort, and rewrite. Returns 1 if nothing actually changed.
function _nx_scope_file_add() {
  local file="$1"
  shift
  local existing
  existing="$(_nx_scope_pkgs "$file")"
  local all_pkgs=()
  if [ -n "$existing" ]; then
    while IFS= read -r p; do
      all_pkgs+=("$p")
    done <<<"$existing"
  fi
  local p added=false
  for p in "$@"; do
    if printf '%s\n' "${all_pkgs[@]}" | grep -qx "$p" 2>/dev/null; then
      printf "\e[33m%s is already in scope\e[0m\n" "$p" >&2
    else
      all_pkgs+=("$p")
      printf "\e[32madded %s\e[0m\n" "$p" >&2
      added=true
    fi
  done
  [ "$added" = false ] && return 1
  local sorted
  sorted="$(printf '%s\n' "${all_pkgs[@]}" | sort -u)"
  local content="{ pkgs }: with pkgs; ["
  while IFS= read -r p; do
    [ -n "$p" ] && content+=$'\n'"  $p"
  done <<<"$sorted"
  content+=$'\n'"]"$'\n'
  printf '%s' "$content" >"$file"
  return 0
}

function _nx_scope_dispatch() {
  local env_dir="$_NX_ENV_DIR"
  local config_nix="$env_dir/config.nix"
  local scopes_dir="$env_dir/scopes"
  case "${1:-help}" in
  list | ls)
    local scopes
    scopes="$(_nx_scopes)"
    # discover orphaned local scopes (files exist but not in config.nix);
    # `find` instead of glob so zsh callers don't trip NOMATCH when the dir is empty
    local f lname
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      lname="$(basename "$f" .nix)"
      if ! printf '%s\n' "$scopes" | grep -qx "$lname" 2>/dev/null; then
        scopes="${scopes:+$scopes
}$lname"
      fi
    done < <(find "$scopes_dir" -maxdepth 1 -type f -name 'local_*.nix' 2>/dev/null)
    scopes="$(printf '%s\n' "$scopes" | sort)"
    if [ -n "$scopes" ]; then
      printf "\e[96mInstalled scopes:\e[0m\n"
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        local display="${s#local_}"
        if [[ "$s" == local_* ]]; then
          printf "  \e[1m*\e[0m %s \e[90m(local)\e[0m\n" "$display"
        else
          printf "  \e[1m*\e[0m %s\n" "$display"
        fi
      done <<<"$scopes"
    else
      printf "\e[33mNo scopes configured.\e[0m Run \e[1mnix/setup.sh\e[0m to initialize.\n"
    fi
    ;;
  show)
    shift
    [ $# -eq 0 ] && {
      echo "Usage: nx scope show <scope>" >&2
      return 1
    }
    local scope_file="$scopes_dir/$1.nix"
    if [ ! -f "$scope_file" ]; then
      printf "\e[31mScope '%s' not found.\e[0m\n" "$1" >&2
      return 1
    fi
    printf "\e[96m%s:\e[0m\n" "$1"
    local pkg
    while IFS= read -r pkg; do
      [ -n "$pkg" ] && printf "  \e[1m*\e[0m %s\n" "$pkg"
    done < <(_nx_scope_pkgs "$scope_file" | sort)
    ;;
  tree)
    local scopes s
    if [ -d "$scopes_dir" ]; then
      printf "\e[96mbase:\e[0m\n"
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf "  \e[1m*\e[0m %s\n" "$pkg"
      done < <(_nx_scope_pkgs "$scopes_dir/base.nix" | sort)
    fi
    scopes="$(_nx_scopes)"
    local f lname
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      lname="$(basename "$f" .nix)"
      if ! printf '%s\n' "$scopes" | grep -qx "$lname" 2>/dev/null; then
        scopes="${scopes:+$scopes
}$lname"
      fi
    done < <(find "$scopes_dir" -maxdepth 1 -type f -name 'local_*.nix' 2>/dev/null)
    scopes="$(printf '%s\n' "$scopes" | sort)"
    if [ -n "$scopes" ]; then
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        local display="${s#local_}"
        if [[ "$s" == local_* ]]; then
          printf "\e[96m%s (local):\e[0m\n" "$display"
        else
          printf "\e[96m%s:\e[0m\n" "$display"
        fi
        while IFS= read -r pkg; do
          [ -n "$pkg" ] && printf "  \e[1m*\e[0m %s\n" "$pkg"
        done < <(_nx_scope_pkgs "$scopes_dir/$s.nix" | sort)
      done <<<"$scopes"
    fi
    local pkgs
    pkgs="$(_nx_read_pkgs)"
    if [ -n "$pkgs" ]; then
      printf "\e[96mextra:\e[0m\n"
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf "  \e[1m*\e[0m %s\n" "$pkg"
      done <<<"$pkgs"
    fi
    ;;
  remove | rm)
    shift
    [ $# -eq 0 ] && {
      echo "Usage: nx scope remove <scope> [scope...]" >&2
      return 1
    }
    if [ ! -f "$config_nix" ]; then
      printf "\e[31mNo nix-env config found. Run nix/setup.sh to initialize.\e[0m\n" >&2
      return 1
    fi
    local current_scopes is_init
    current_scopes="$(_nx_scopes)"
    is_init="$(_nx_is_init)"
    if [ -z "$current_scopes" ]; then
      printf "\e[33mNo scopes configured - nothing to remove.\e[0m\n"
      return 0
    fi
    local ov_dir="$env_dir/local"
    if [ -n "${NIX_ENV_OVERLAY_DIR:-}" ] && [ -d "$NIX_ENV_OVERLAY_DIR" ]; then
      ov_dir="$NIX_ENV_OVERLAY_DIR"
    fi
    local remove_set=" "
    local r
    for r in "$@"; do
      remove_set+="$r local_$r "
    done
    local remaining=() removed=false
    while IFS= read -r s; do
      if [[ " $remove_set " == *" $s "* ]]; then
        printf "\e[32mremoved scope: %s\e[0m\n" "${s#local_}"
        removed=true
      else
        remaining+=("$s")
      fi
    done <<<"$current_scopes"
    for r in "$@"; do
      rm -f "$ov_dir/scopes/$r.nix" "$scopes_dir/local_$r.nix"
      if [ -f "$scopes_dir/$r.nix" ] && [[ "$r" != local_* ]]; then
        printf "\e[33mNote: '%s' is a base-managed scope - it will be removed from config.nix and re-added on next nix/setup.sh run unless you also pass it to setup.sh --remove\e[0m\n" "$r" >&2
      fi
    done
    for r in "$@"; do
      if [[ " $remove_set " == *" $r "* ]]; then
        local _found=false
        printf '%s\n' "$current_scopes" | grep -qx "$r" 2>/dev/null && _found=true
        printf '%s\n' "$current_scopes" | grep -qx "local_$r" 2>/dev/null && _found=true
        [ "$_found" = false ] && printf "\e[33mscope '%s' is not configured - skipping\e[0m\n" "$r" >&2
      fi
    done
    if [ "$removed" = false ]; then
      return 0
    fi
    local nix_scopes=""
    local s
    for s in "${remaining[@]}"; do
      nix_scopes+="    \"$s\""$'\n'
    done
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
# Generated by nx scope remove - re-run nix/setup.sh to reconfigure.
{
  isInit = ${is_init:-false};

  scopes = [
$nix_scopes  ];
}
EOF
    mv "$tmp" "$config_nix"
    _nx_apply
    printf "Restart your shell to apply changes.\n"
    ;;
  add | create)
    shift
    [ $# -eq 0 ] && {
      echo "Usage: nx scope add <name> [pkg...]" >&2
      return 1
    }
    local name="${1//-/_}"
    shift
    # Reject overlay names that collide with managed scopes (defined in
    # nix/scopes/<name>.nix and listed in scopes.json:valid_scopes).
    # Without this guard, `nx scope add python` silently creates
    # ~/.config/nix-env/local/scopes/python.nix and adds local_python to
    # config.nix - the shadow then competes with the canonical python scope
    # on the next nix/setup.sh run. Skipped if scopes.json is unavailable
    # (very-first-run before phase_bootstrap_sync_env_dir, or jq missing).
    local _scopes_json
    _scopes_json="$(_nx_find_lib scopes.json 2>/dev/null)" || _scopes_json=""
    if [ -n "$_scopes_json" ] && command -v jq >/dev/null 2>&1; then
      if jq -e --arg n "$name" '.valid_scopes | index($n)' "$_scopes_json" >/dev/null 2>&1; then
        printf "\e[31m'%s' is a managed scope (defined in nix/scopes/%s.nix). Pick a different name for your overlay.\e[0m\n" "$name" "$name" >&2
        return 1
      fi
    fi
    local ov_dir="$env_dir/local"
    if [ -n "${NIX_ENV_OVERLAY_DIR:-}" ] && [ -d "$NIX_ENV_OVERLAY_DIR" ]; then
      ov_dir="$NIX_ENV_OVERLAY_DIR"
    fi
    local scope_file="$ov_dir/scopes/$name.nix"
    local created=false
    if [ ! -f "$scope_file" ]; then
      mkdir -p "$ov_dir/scopes" "$scopes_dir"
      printf '{ pkgs }: with pkgs; []\n' >"$scope_file"
      command cp "$scope_file" "$scopes_dir/local_$name.nix"
      if [ -f "$config_nix" ]; then
        local current_scopes
        current_scopes="$(_nx_scopes)"
        if ! printf '%s\n' "$current_scopes" | grep -qx "local_$name" 2>/dev/null; then
          local is_init
          is_init="$(_nx_is_init)"
          local all_scopes=()
          if [ -n "$current_scopes" ]; then
            while IFS= read -r s; do
              all_scopes+=("$s")
            done <<<"$current_scopes"
          fi
          all_scopes+=("local_$name")
          local nix_scopes=""
          for s in "${all_scopes[@]}"; do
            nix_scopes+="    \"$s\""$'\n'
          done
          cat >"$config_nix" <<SCOPE_ADD_EOF
# Generated by nx scope add - re-run nix/setup.sh to reconfigure.
{
  isInit = ${is_init:-false};

  scopes = [
$nix_scopes  ];
}
SCOPE_ADD_EOF
        fi
      fi
      created=true
      printf "\e[32mCreated scope '%s' at %s\e[0m\n" "$name" "$scope_file"
    fi
    if [ $# -gt 0 ]; then
      local validated=() p
      for p in "$@"; do
        printf "\e[90mvalidating %s...\e[0m\r" "$p"
        if _nx_validate_pkg "$p"; then
          validated+=("$p")
        else
          printf "\e[31m%s not found in nixpkgs\e[0m\n" "$p" >&2
        fi
      done
      if [ ${#validated[@]} -gt 0 ]; then
        _nx_scope_file_add "$scope_file" "${validated[@]}"
        command cp "$scope_file" "$scopes_dir/local_$name.nix"
        _nx_apply
      fi
    elif [ "$created" = true ]; then
      printf "Add packages: \e[1mnx scope add %s <pkg> [pkg...]\e[0m\n" "$name"
    else
      printf "\e[33mScope '%s' already exists.\e[0m Add packages: nx scope add %s <pkg>\n" "$name" "$name"
    fi
    ;;
  edit)
    shift
    [ $# -eq 0 ] && {
      echo "Usage: nx scope edit <name>" >&2
      return 1
    }
    local name="${1//-/_}"
    local ov_dir="$env_dir/local"
    if [ -n "${NIX_ENV_OVERLAY_DIR:-}" ] && [ -d "$NIX_ENV_OVERLAY_DIR" ]; then
      ov_dir="$NIX_ENV_OVERLAY_DIR"
    fi
    local scope_file="$ov_dir/scopes/$name.nix"
    if [ ! -f "$scope_file" ]; then
      if [ -f "$scopes_dir/$name.nix" ]; then
        printf "\e[33mScope '%s' is managed by the base repository and is read-only.\e[0m\n" "$name" >&2
        printf "To customize it, create an overlay scope: \e[1mnx scope add %s <pkg>\e[0m\n" "$name" >&2
        return 1
      fi
      printf "\e[31mScope '%s' not found.\e[0m Create it first: \e[1mnx scope add %s\e[0m\n" "$name" "$name" >&2
      return 1
    fi
    "${EDITOR:-vi}" "$scope_file"
    command cp "$scope_file" "$scopes_dir/local_$name.nix"
    printf "\e[32mSynced scope '%s'.\e[0m Run \e[1mnx upgrade\e[0m to apply.\n" "$name"
    ;;
  *)
    cat <<'EOF'
Usage: nx scope <command> [args]

Commands:
  list                      List enabled scopes
  show <scope>              Show packages in a scope
  tree                      Show all scopes with their packages
  add <name> [pkg...]       Create a scope or add packages to it
  edit <name>               Open a scope file in $EDITOR
  remove <scope> [scope...] Remove one or more scopes
EOF
    ;;
  esac
}

function _nx_overlay_dispatch() {
  local env_dir="$_NX_ENV_DIR"
  local ov_dir=""
  if [ -n "${NIX_ENV_OVERLAY_DIR:-}" ] && [ -d "$NIX_ENV_OVERLAY_DIR" ]; then
    ov_dir="$NIX_ENV_OVERLAY_DIR"
  elif [ -d "$env_dir/local" ]; then
    ov_dir="$env_dir/local"
  fi
  if [ "${1:-}" = "help" ] || [ "${1:-}" = "-h" ]; then
    printf "Usage: nx overlay\n\nShow overlay directory contents and sync status.\n"
    printf "Overlay scopes are listed in \e[1mnx scope list\e[0m (marked 'local').\n"
    return 0
  fi
  if [ -z "$ov_dir" ]; then
    printf "\e[33mNo overlay directory active.\e[0m\n"
    printf "Create one at %s/local/ or set NIX_ENV_OVERLAY_DIR.\n" "$env_dir"
    return 0
  fi
  printf "\e[96mOverlay directory:\e[0m %s\n" "$ov_dir"
  local scopes_dir="$env_dir/scopes"
  local f hdr name indicator
  hdr=false
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$hdr" = false ] && printf "\e[96mScopes:\e[0m\n" && hdr=true
    name="$(basename "$f" .nix)"
    name="${name#local_}"
    indicator=""
    if [ -f "$ov_dir/scopes/$name.nix" ]; then
      if ! cmp -s "$ov_dir/scopes/$name.nix" "$f" 2>/dev/null; then
        indicator=" \e[33m(modified)\e[0m"
      fi
    else
      indicator=" \e[33m(source missing)\e[0m"
    fi
    printf "  \e[1m*\e[0m %s%b\n" "$name" "$indicator"
  done < <(find "$scopes_dir" -maxdepth 1 -type f -name 'local_*.nix' 2>/dev/null)
  [ "$hdr" = false ] && printf "\e[90mNo overlay scopes.\e[0m\n"
  if [ -d "$ov_dir/shell_cfg" ]; then
    hdr=false
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$hdr" = false ] && printf "\e[96mShell config:\e[0m\n" && hdr=true
      local bname installed
      bname="$(basename "$f")"
      installed="$HOME/.config/shell/$bname"
      indicator=""
      if [ -f "$installed" ]; then
        if cmp -s "$f" "$installed" 2>/dev/null; then
          indicator=" \e[32m(synced)\e[0m"
        else
          indicator=" \e[33m(differs)\e[0m"
        fi
      else
        indicator=" \e[33m(not installed)\e[0m"
      fi
      printf "  \e[1m*\e[0m %s%b\n" "$bname" "$indicator"
    done < <(find "$ov_dir/shell_cfg" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.zsh' \) 2>/dev/null)
  fi
  local hook_dir
  for hook_dir in pre-setup.d post-setup.d; do
    hdr=false
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$hdr" = false ] && printf "\e[96mHooks (%s):\e[0m\n" "$hook_dir" && hdr=true
      printf "  \e[1m*\e[0m %s\n" "$(basename "$f")"
    done < <(find "$ov_dir/hooks/$hook_dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null)
  done
}

function _nx_pin_dispatch() {
  local _pin_file="$_NX_ENV_DIR/pinned_rev"
  case "${1:-show}" in
  set)
    shift
    local _rev="${1:-}"
    if [ -z "$_rev" ]; then
      local _lock="$_NX_ENV_DIR/flake.lock"
      [ -f "$_lock" ] || {
        printf "\e[31mNo flake.lock found - run nx upgrade first.\e[0m\n" >&2
        return 1
      }
      _rev="$(jq -r '.nodes.nixpkgs.locked.rev' "$_lock" 2>/dev/null)" || true
      [ -n "$_rev" ] && [ "$_rev" != "null" ] || {
        printf "\e[31mCould not read nixpkgs revision from flake.lock.\e[0m\n" >&2
        return 1
      }
    fi
    printf '%s\n' "$_rev" >"$_pin_file"
    printf "\e[32mPinned nixpkgs to %s\e[0m\n" "$_rev"
    ;;
  remove | rm)
    if [ -f "$_pin_file" ]; then
      rm "$_pin_file"
      printf "\e[32mPin removed.\e[0m Upgrades will use latest nixpkgs-unstable.\n"
    else
      printf "\e[90mNo pin set.\e[0m\n"
    fi
    ;;
  show)
    if [ -f "$_pin_file" ]; then
      printf "\e[96mPinned to:\e[0m %s\n" "$(tr -d '[:space:]' <"$_pin_file")"
    else
      printf "\e[90mNo pin set.\e[0m Upgrades use latest nixpkgs-unstable.\n"
    fi
    ;;
  help | *)
    cat <<'PIN_HELP'
Usage: nx pin <command>

Commands:
  set [rev]   Pin nixpkgs to a commit SHA (default: current flake.lock rev)
  remove      Remove the pin (use latest nixpkgs-unstable)
  show        Show current pin status (default)
  help        Show this help

The pin takes effect on the next `nx upgrade` or `nix/setup.sh --upgrade`.
PIN_HELP
    ;;
  esac
}
