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

# Constants
_NX_ENV_DIR="$HOME/.config/nix-env"
_NX_PKG_FILE="$_NX_ENV_DIR/packages.nix"

# --- Helpers ---

_nx_read_pkgs() {
  [ -f "$_NX_PKG_FILE" ] && sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' "$_NX_PKG_FILE"
}

_nx_write_pkgs() {
  local tmp
  tmp="$(mktemp)"
  printf '[\n' >"$tmp"
  sort -u | while IFS= read -r name; do
    [ -n "$name" ] && printf '  "%s"\n' "$name" >>"$tmp"
  done
  printf ']\n' >>"$tmp"
  mv "$tmp" "$_NX_PKG_FILE"
}

_nx_apply() {
  printf "\e[96mapplying changes...\e[0m\n"
  nix profile upgrade nix-env || {
    printf "\e[31mnix profile upgrade failed\e[0m\n" >&2
    return 1
  }
  printf "\e[32mdone.\e[0m\n"
}

_nx_validate_pkg() {
  nix eval "nixpkgs#${1}.name" &>/dev/null
}

_nx_scope_file_add() {
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

_nx_scope_pkgs() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n '/\[/,/\]/{
    s/^[[:space:]]*\([a-zA-Z][a-zA-Z0-9_-]*\).*/\1/p
  }' "$file"
}

_nx_scopes() {
  local config_nix="$_NX_ENV_DIR/config.nix"
  [ -f "$config_nix" ] || return 0
  sed -n '/scopes[[:space:]]*=[[:space:]]*\[/,/\]/{
    s/^[[:space:]]*"\([^"]*\)".*/\1/p
  }' "$config_nix"
}

_nx_is_init() {
  local config_nix="$_NX_ENV_DIR/config.nix"
  [ -f "$config_nix" ] || { echo "false"; return; }
  sed -n -E 's/^[[:space:]]*isInit[[:space:]]*=[[:space:]]*(true|false).*/\1/p' "$config_nix"
}

_nx_all_scope_pkgs() {
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

_nx_find_lib() {
  local name="$1"
  local script_dir
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

_nx_version() {
  local install_json="$HOME/.config/dev-env/install.json"
  if [ ! -f "$install_json" ]; then
    printf "\e[33mNo install record found.\e[0m\n"
    return 0
  fi
  if ! type jq &>/dev/null; then
    cat "$install_json"
    return 0
  fi
  local ver entry src src_ref scopes installed_at mode status phase plat nix_ver err_msg
  ver="$(jq -r '.version // "unknown"' "$install_json")"
  entry="$(jq -r '.entry_point // "unknown"' "$install_json")"
  src="$(jq -r '.source // "unknown"' "$install_json")"
  src_ref="$(jq -r '.source_ref // "" | if . == "" then "n/a" else .[0:12] end' "$install_json")"
  scopes="$(jq -r '.scopes // [] | join(", ")' "$install_json")"
  installed_at="$(jq -r '.installed_at // "unknown"' "$install_json")"
  mode="$(jq -r '.mode // "unknown"' "$install_json")"
  status="$(jq -r '.status // "unknown"' "$install_json")"
  phase="$(jq -r '.phase // "unknown"' "$install_json")"
  plat="$(jq -r '"\(.platform // "unknown")/\(.arch // "unknown")"' "$install_json")"
  nix_ver="$(jq -r '.nix_version // ""' "$install_json")"
  err_msg="$(jq -r '.error // ""' "$install_json")"

  local unfree="false"
  local config_nix="$_NX_ENV_DIR/config.nix"
  if [ -f "$config_nix" ]; then
    unfree="$(sed -n -E 's/^[[:space:]]*allowUnfree[[:space:]]*=[[:space:]]*(true|false).*/\1/p' "$config_nix")"
    [ -z "$unfree" ] && unfree="false"
  fi

  local cert_dir="$HOME/.config/certs"
  local ca_bundle="" ca_custom=""
  [ -e "$cert_dir/ca-bundle.crt" ] && ca_bundle="true"
  [ -f "$cert_dir/ca-custom.crt" ] && ca_custom="true"

  printf "\e[96mdev-env\e[0m %s\n" "$ver"
  printf "  \e[90mEntry:     \e[0m%s\n" "$entry"
  printf "  \e[90mSource:    \e[0m%s (%s)\n" "$src" "$src_ref"
  printf "  \e[90mPlatform:  \e[0m%s\n" "$plat"
  printf "  \e[90mMode:      \e[0m%s\n" "$mode"
  if [ "$status" = "success" ]; then
    printf "  \e[90mStatus:    \e[32m%s\e[0m\n" "$status"
  else
    printf "  \e[90mStatus:    \e[31m%s\e[0m (phase: %s)\n" "$status" "$phase"
    [ -n "$err_msg" ] && printf "  \e[90mError:     \e[31m%s\e[0m\n" "$err_msg"
  fi
  printf "  \e[90mInstalled: \e[0m%s\n" "$installed_at"
  [ -n "$nix_ver" ] && printf "  \e[90mNix:       \e[0m%s\n" "$nix_ver"
  printf "  \e[90mScopes:    \e[0m%s\n" "$scopes"
  if [ "$unfree" = "true" ]; then
    printf "  \e[90mUnfree:    \e[33menabled\e[0m\n"
  fi
  if [ "$ca_custom" = "true" ]; then
    if [ "$ca_bundle" = "true" ]; then
      printf "  \e[90mCerts:     \e[0mca-bundle.crt, ca-custom.crt\n"
    else
      printf "  \e[90mCerts:     \e[33mca-custom.crt (missing ca-bundle.crt)\e[0m\n"
    fi
  elif [ "$ca_bundle" = "true" ]; then
    printf "  \e[90mCerts:     \e[0mca-bundle.crt\n"
  fi
}

# --- Profile block rendering ---

_nx_render_env_block() {
  printf '# :local path\n'
  printf 'if [ -d "$HOME/.local/bin" ]; then\n'
  printf '  export PATH="$HOME/.local/bin:$PATH"\n'
  printf 'fi\n'

  if [ -f "$HOME/.config/bash/functions.sh" ]; then
    printf '\n# :aliases\n'
    printf '[ -f "$HOME/.config/bash/functions.sh" ] && . "$HOME/.config/bash/functions.sh"\n'
  fi
  if [ -f "$HOME/.config/bash/aliases_git.sh" ] && command -v git &>/dev/null && [ ! -x "$HOME/.nix-profile/bin/git" ]; then
    printf '[ -f "$HOME/.config/bash/aliases_git.sh" ] && . "$HOME/.config/bash/aliases_git.sh"\n'
  fi
  if [ -f "$HOME/.config/bash/aliases_kubectl.sh" ] && command -v kubectl &>/dev/null && [ ! -x "$HOME/.nix-profile/bin/kubectl" ]; then
    printf '[ -f "$HOME/.config/bash/aliases_kubectl.sh" ] && . "$HOME/.config/bash/aliases_kubectl.sh"\n'
  fi

  local cert_dir="$HOME/.config/certs"
  if [ -f "$cert_dir/ca-custom.crt" ] || [ -e "$cert_dir/ca-bundle.crt" ]; then
    printf '\n# :certs\n'
  fi
  if [ -f "$cert_dir/ca-custom.crt" ]; then
    printf 'if [ -f "$HOME/.config/certs/ca-custom.crt" ]; then\n'
    printf '  export NODE_EXTRA_CA_CERTS="$HOME/.config/certs/ca-custom.crt"\n'
    printf 'fi\n'
  fi
  if [ -e "$cert_dir/ca-bundle.crt" ]; then
    printf 'if [ -f "$HOME/.config/certs/ca-bundle.crt" ]; then\n'
    printf '  export REQUESTS_CA_BUNDLE="$HOME/.config/certs/ca-bundle.crt"\n'
    printf '  export SSL_CERT_FILE="$HOME/.config/certs/ca-bundle.crt"\n'
    printf 'fi\n'
    if command -v gcloud &>/dev/null; then
      printf 'if [ -f "$HOME/.config/certs/ca-bundle.crt" ]; then\n'
      printf '  export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="$HOME/.config/certs/ca-bundle.crt"\n'
      printf 'fi\n'
    fi
  fi
}

_nx_render_nix_block() {
  local shell="${1:-bash}"
  printf '# :path\n'

  local nix_profile
  for nix_profile in \
    "$HOME/.nix-profile/etc/profile.d/nix.sh" \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; do
    if [ -f "$nix_profile" ]; then
      printf '. %s\n' "$nix_profile"
      break
    fi
  done

  if [ -d "$HOME/.nix-profile/bin" ]; then
    printf 'export PATH="$HOME/.nix-profile/bin:$PATH"\n'
  fi

  if [ -f "$HOME/.config/certs/ca-bundle.crt" ]; then
    printf 'export NIX_SSL_CERT_FILE="$HOME/.config/certs/ca-bundle.crt"\n'
  fi

  if [ -f "$HOME/.config/bash/aliases_nix.sh" ] && command -v nix &>/dev/null; then
    printf '\n# :aliases\n'
    printf '. "$HOME/.config/bash/aliases_nix.sh"\n'
  fi
  if [ -f "$HOME/.config/bash/aliases_git.sh" ] && [ -x "$HOME/.nix-profile/bin/git" ]; then
    printf '[ -f "$HOME/.config/bash/aliases_git.sh" ] && . "$HOME/.config/bash/aliases_git.sh"\n'
  fi
  if [ -f "$HOME/.config/bash/aliases_kubectl.sh" ] && [ -x "$HOME/.nix-profile/bin/kubectl" ]; then
    printf '[ -f "$HOME/.config/bash/aliases_kubectl.sh" ] && . "$HOME/.config/bash/aliases_kubectl.sh"\n'
  fi

  if [ "$shell" = "zsh" ]; then
    local _zsh_dir="$HOME/.zsh"
    local _plugin _file _has_plugins=false
    local _zsh_plugins="zsh-autocomplete:zsh-autocomplete.plugin.zsh zsh-make-complete:zsh-make-complete.plugin.zsh zsh-autosuggestions:zsh-autosuggestions.zsh zsh-syntax-highlighting:zsh-syntax-highlighting.zsh"
    for _plugin in $_zsh_plugins; do
      _file="${_plugin#*:}"
      _plugin="${_plugin%%:*}"
      if [ -f "$_zsh_dir/$_plugin/$_file" ]; then
        [ "$_has_plugins" = false ] && printf '\n# :zsh plugins\n' && _has_plugins=true
        printf 'source "$HOME/.zsh/%s/%s"\n' "$_plugin" "$_file"
      fi
    done
  fi

  if [ -x "$HOME/.nix-profile/bin/fzf" ]; then
    printf '\n# :fzf\n'
    printf '[ -x "$HOME/.nix-profile/bin/fzf" ] && eval "$(fzf --%s)"\n' "$shell"
  fi

  if [ -x "$HOME/.nix-profile/bin/uv" ]; then
    printf '\n# :uv\n'
    printf 'if [ -x "$HOME/.nix-profile/bin/uv" ]; then\n'
    printf '  export UV_SYSTEM_CERTS=true\n'
    printf '  eval "$(uv generate-shell-completion %s)"\n' "$shell"
    printf '  eval "$(uvx --generate-shell-completion %s)"\n' "$shell"
    printf 'fi\n'
  fi

  if [ -x "$HOME/.nix-profile/bin/kubectl" ]; then
    printf '\n# :kubectl\n'
    printf 'if [ -x "$HOME/.nix-profile/bin/kubectl" ]; then\n'
    printf '  source <(kubectl completion %s)\n' "$shell"
    if [ "$shell" = "bash" ]; then
      printf '  complete -o default -F __start_kubectl k\n'
    fi
    printf 'fi\n'
  fi

  if [ "$shell" = "bash" ]; then
    printf '\n# :make\n'
    printf 'complete -W "$(if [ -f Makefile ]; then grep -oE '\''^[a-zA-Z0-9_-]+:([^=]|$)'\'' Makefile | sed '\''s/[^a-zA-Z0-9_-]*$//'\''
elif [ -f makefile ]; then grep -oE '\''^[a-zA-Z0-9_-]+:([^=]|$)'\'' makefile | sed '\''s/[^a-zA-Z0-9_-]*$//'\''
fi)" make\n'
  fi

  if [ -x "$HOME/.nix-profile/bin/oh-my-posh" ] && [ -f "$HOME/.config/nix-env/omp/theme.omp.json" ]; then
    printf '\n# :oh-my-posh\n'
    printf '[ -x "$HOME/.nix-profile/bin/oh-my-posh" ] && eval "$(oh-my-posh init %s --config $HOME/.config/nix-env/omp/theme.omp.json)"\n' "$shell"
  fi

  if [ -x "$HOME/.nix-profile/bin/starship" ]; then
    printf '\n# :starship\n'
    printf '[ -x "$HOME/.nix-profile/bin/starship" ] && eval "$(starship init %s)"\n' "$shell"
  fi

  if [ "$shell" = "zsh" ]; then
    printf '\n# :keybindings\n'
    printf "bindkey '^ ' autosuggest-accept\n"
  fi
}

_nx_profile_regenerate() {
  local _pb_lib_path
  _pb_lib_path="$(_nx_find_lib profile_block.sh)" || {
    printf "\e[31mprofile_block.sh not found\e[0m\n" >&2
    return 1
  }
  source "$_pb_lib_path"

  local _nix_marker="nix-env managed"
  local _env_marker="managed env"
  local _legacy_markers=(
    'aliases_nix' 'aliases_git' 'aliases_kubectl' 'functions.sh'
    'fzf --bash' 'fzf --zsh' 'uv generate-shell-completion'
    'kubectl completion' 'Makefile'
    'NODE_EXTRA_CA_CERTS' 'REQUESTS_CA_BUNDLE' 'SSL_CERT_FILE' 'CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE'
    'NIX_SSL_CERT_FILE' 'nix-profile/bin:' '.local/bin' 'nix-daemon.sh'
    'oh-my-posh init' 'starship init'
  )
  local _rc _shell _tmp

  for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    case "$_rc" in
    *.bashrc) _shell="bash" ;;
    *.zshrc)  _shell="zsh" ;;
    esac
    command -v "$_shell" &>/dev/null || continue
    [ -f "$_rc" ] || continue

    # strip legacy injections outside managed blocks (backup once if found)
    local _outside _m _has_legacy=false
    _outside="$(awk '
      /^# >>> .* >>>$/{skip=1;next} skip&&/^# <<< .* <<<$/{skip=0;next} !skip{print}
    ' "$_rc")"
    for _m in "${_legacy_markers[@]}"; do
      printf '%s\n' "$_outside" | grep -qwF "$_m" 2>/dev/null && _has_legacy=true && break
    done
    if [ "$_has_legacy" = true ]; then
      cp -p "$_rc" "${_rc}.nixenv-backup-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      local _markers_file
      _markers_file="$(mktemp)"
      _tmp="$(mktemp)"
      printf '%s\n' "${_legacy_markers[@]}" >"$_markers_file"
      awk '
        FILENAME==ARGV[1] { markers[NR]=$0; nm=NR; next }
        /^# >>> .* >>>$/        { in_block=1; print; next }
        in_block&&/^# <<< .* <<<$/{ in_block=0; print; next }
        in_block                { print; next }
        {
          matched=0
          for (i=1; i<=nm; i++) { if (index($0, markers[i])) { matched=1; break } }
          if (!matched) print
        }
      ' "$_markers_file" "$_rc" >"$_tmp"
      rm -f "$_markers_file"
      command mv -f "$_tmp" "$_rc"
      printf "\e[33mCleaned legacy injections from %s\e[0m\n" "${_rc/#$HOME/\~}"
    fi

    # render and upsert env block
    _tmp="$(mktemp)"
    _nx_render_env_block >"$_tmp"
    manage_block "$_rc" "$_env_marker" upsert "$_tmp"
    rm -f "$_tmp"

    # render and upsert nix block
    _tmp="$(mktemp)"
    _nx_render_nix_block "$_shell" >"$_tmp"
    manage_block "$_rc" "$_nix_marker" upsert "$_tmp"
    rm -f "$_tmp"

    printf "\e[32mRegenerated %s\e[0m\n" "${_rc/#$HOME/\~}"
  done
}

# --- Main dispatch ---

nx_main() {
  case "${1:-help}" in
  search)
    shift
    [ $# -eq 0 ] && {
      echo "Usage: nx search <query>" >&2
      return 1
    }
    local query="$*"
    nix search nixpkgs "$query" --json 2>/dev/null |
      jq -r 'to_entries[] | "[1m* \(.key | split(".")[-1])[0m (\(.value.version))\n  \(.value.description // "")\n"'
    ;;
  install | add)
    shift
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
    local scope_pkgs
    scope_pkgs="$(_nx_all_scope_pkgs)"
    local current _before
    current="$(_nx_read_pkgs)"
    _before="$(cat "$_NX_PKG_FILE" 2>/dev/null)"
    {
      [ -n "$current" ] && printf '%s\n' "$current"
      for p in "${validated[@]}"; do
        local in_scope
        in_scope="$(printf '%s\n' "$scope_pkgs" | grep -m1 "^${p}	" 2>/dev/null | cut -f2)"
        if [ -n "$in_scope" ]; then
          printf "\e[33m%s is already installed in scope '%s'\e[0m\n" "$p" "$in_scope" >&2
        elif printf '%s\n' "$current" | grep -qx "$p" 2>/dev/null; then
          printf "\e[33m%s is already installed (extra)\e[0m\n" "$p" >&2
        else
          printf '%s\n' "$p"
          printf "\e[32madded %s\e[0m\n" "$p" >&2
        fi
      done
    } | _nx_write_pkgs
    [ "$(cat "$_NX_PKG_FILE" 2>/dev/null)" != "$_before" ] && _nx_apply
    ;;
  remove | uninstall)
    shift
    [ $# -eq 0 ] && {
      echo "Usage: nx remove <pkg> [pkg...]" >&2
      return 1
    }
    local scope_pkgs
    scope_pkgs="$(_nx_all_scope_pkgs)"
    local filtered_args=()
    local p
    for p in "$@"; do
      local in_scope
      in_scope="$(printf '%s\n' "$scope_pkgs" | grep -m1 "^${p}	" 2>/dev/null | cut -f2)"
      if [ -n "$in_scope" ]; then
        printf "\e[33m%s is managed by scope '%s' - use: nx scope remove %s\e[0m\n" "$p" "$in_scope" "$in_scope" >&2
      else
        filtered_args+=("$p")
      fi
    done
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
    ;;
  upgrade | update)
    shift
    printf "\e[96mupgrading packages...\e[0m\n"
    local _pinned_rev=""
    [ -f "$_NX_ENV_DIR/pinned_rev" ] && _pinned_rev="$(tr -d '[:space:]' <"$_NX_ENV_DIR/pinned_rev")"
    if [ -n "$_pinned_rev" ]; then
      printf "\e[96mpinning nixpkgs to %s\e[0m\n" "$_pinned_rev"
      nix flake lock --override-input nixpkgs "github:nixos/nixpkgs/$_pinned_rev" --flake "$_NX_ENV_DIR" 2>/dev/null ||
        printf "\e[33mflake lock failed - using existing lock\e[0m\n" >&2
    else
      nix flake update --flake "$_NX_ENV_DIR" 2>/dev/null ||
        printf "\e[33mflake update failed (network issue?) - using existing lock\e[0m\n" >&2
    fi
    nix profile upgrade nix-env || {
      printf "\e[31mnix profile upgrade failed\e[0m\n" >&2
      return 1
    }
    printf "\e[32mdone.\e[0m\n"
    ;;
  list | ls)
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
    ;;
  scope)
    shift
    local env_dir="$_NX_ENV_DIR"
    local config_nix="$env_dir/config.nix"
    local scopes_dir="$env_dir/scopes"
    case "${1:-help}" in
    list | ls)
      local scopes
      scopes="$(_nx_scopes)"
      # discover orphaned local scopes (files exist but not in config.nix)
      local f lname
      for f in "$scopes_dir"/local_*.nix; do
        [ -f "$f" ] || continue
        lname="$(basename "$f" .nix)"
        if ! printf '%s\n' "$scopes" | grep -qx "$lname" 2>/dev/null; then
          scopes="${scopes:+$scopes
}$lname"
        fi
      done
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
      for f in "$scopes_dir"/local_*.nix; do
        [ -f "$f" ] || continue
        lname="$(basename "$f" .nix)"
        if ! printf '%s\n' "$scopes" | grep -qx "$lname" 2>/dev/null; then
          scopes="${scopes:+$scopes
}$lname"
        fi
      done
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
          :
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
    ;;
  profile)
    shift
    local _pb_marker="nix-env managed"
    local _pb_env_marker="managed env"
    local _pb_rc_files=()
    command -v bash &>/dev/null && _pb_rc_files+=("$HOME/.bashrc")
    command -v zsh &>/dev/null && _pb_rc_files+=("$HOME/.zshrc")

    local _pb_lib_path
    _pb_lib_path="$(_nx_find_lib profile_block.sh)" && source "$_pb_lib_path"

    _pb_short() { printf '%s' "${1/#$HOME/\~}"; }

    case "${1:-help}" in
    doctor)
      local _pb_ok=true
      local _pb_rc
      for _pb_rc in "${_pb_rc_files[@]}"; do
        [ -f "$_pb_rc" ] || continue
        printf "\e[96mChecking %s\e[0m\n" "$(_pb_short "$_pb_rc")"
        local _pb_count _pb_m
        for _pb_m in "$_pb_env_marker" "$_pb_marker"; do
          _pb_count="$(grep -cF "# >>> $_pb_m >>>" "$_pb_rc" 2>/dev/null || true)"
          if [ "$_pb_count" -eq 0 ] 2>/dev/null; then
            printf "\e[33m  [warn] no '%s' block - run: nx profile regenerate\e[0m\n" "$_pb_m" >&2
            _pb_ok=false
          elif [ "$_pb_count" -gt 1 ] 2>/dev/null; then
            printf "\e[31m  [fail] %s duplicate '%s' blocks - run: nx profile regenerate\e[0m\n" \
              "$_pb_count" "$_pb_m" >&2
            _pb_ok=false
          fi
        done
      done
      [ "$_pb_ok" = true ] && printf "\e[32m[ok] profiles look healthy\e[0m\n"
      [ "$_pb_ok" = true ] || return 1
      ;;
    uninstall)
      if ! command -v manage_block &>/dev/null 2>&1 && ! type manage_block &>/dev/null 2>&1; then
        printf "\e[31mmanage_block not loaded - cannot uninstall profile\e[0m\n" >&2
        return 1
      fi
      local _pb_rc
      for _pb_rc in "${_pb_rc_files[@]}"; do
        [ -f "$_pb_rc" ] || continue
        manage_block "$_pb_rc" "$_pb_marker" remove
        manage_block "$_pb_rc" "$_pb_env_marker" remove
        printf "\e[32mRemoved managed blocks from %s\e[0m\n" "$(_pb_short "$_pb_rc")"
      done
      printf "\e[96mProfile blocks removed. Sourced files in ~/.config/bash/ are untouched.\e[0m\n"
      ;;
    regenerate)
      _nx_profile_regenerate
      ;;
    help | *)
      cat <<'PROFILE_HELP'
Usage: nx profile <command>

Commands:
  doctor          Check managed block health in shell profiles
  regenerate      Regenerate managed blocks in shell profiles
  uninstall       Remove managed blocks from shell profiles
  help            Show this help
PROFILE_HELP
      ;;
    esac
    ;;
  overlay)
    shift
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
    for f in "$scopes_dir"/local_*.nix; do
      [ -f "$f" ] || continue
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
    done
    [ "$hdr" = false ] && printf "\e[90mNo overlay scopes.\e[0m\n"
    if [ -d "$ov_dir/bash_cfg" ]; then
      hdr=false
      for f in "$ov_dir/bash_cfg"/*.sh; do
        [ -f "$f" ] || continue
        [ "$hdr" = false ] && printf "\e[96mShell config:\e[0m\n" && hdr=true
        local bname installed
        bname="$(basename "$f")"
        installed="$HOME/.config/bash/$bname"
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
      done
    fi
    local hook_dir
    for hook_dir in pre-setup.d post-setup.d; do
      hdr=false
      for f in "$ov_dir/hooks/$hook_dir"/*.sh; do
        [ -f "$f" ] || continue
        [ "$hdr" = false ] && printf "\e[96mHooks (%s):\e[0m\n" "$hook_dir" && hdr=true
        printf "  \e[1m*\e[0m %s\n" "$(basename "$f")"
      done
    done
    ;;
  prune)
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
    ;;
  gc | clean)
    nix profile wipe-history
    nix store gc
    ;;
  rollback)
    nix profile rollback || {
      printf "\e[31mnix profile rollback failed\e[0m\n" >&2
      return 1
    }
    printf "\e[32mRolled back to previous profile generation.\e[0m\n"
    printf "Restart your shell to apply changes.\n"
    ;;
  pin)
    shift
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
    ;;
  doctor)
    local _dr_script
    _dr_script="$(_nx_find_lib nx_doctor.sh)" || {
      printf '\e[31mnx doctor not found\e[0m\n' >&2
      return 1
    }
    bash "$_dr_script" "${@:2}"
    ;;
  version)
    _nx_version
    ;;
  help | -h | --help)
    cat <<'EOF'
Usage: nx <command> [args]

Commands:
  search  <query>         Search for packages in nixpkgs
  install <pkg> [pkg...]  Install packages (declarative, via packages.nix)
  remove  <pkg> [pkg...]  Remove user-installed packages
  upgrade                 Upgrade all packages to latest nixpkgs
  rollback                Roll back to previous profile generation
  pin                     Pin nixpkgs to a specific revision (nx pin help)
  list                    List all installed packages with scope annotations
  scope                   Manage scopes (nx scope help)
  overlay                 Show overlay directory contents and sync status
  profile                 Manage shell rc profile blocks (nx profile help)
  doctor                  Run health checks on the nix-env environment
  prune                   Remove stale imperative profile entries
  gc                      Garbage collect old versions and free disk space
  version                 Show installation provenance and version info
  help                    Show this help
EOF
    ;;
  *)
    printf "\e[31mUnknown command: %s\e[0m\n" "$1" >&2
    nx_main help
    return 1
    ;;
  esac
}

# --- Execution guard ---
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  nx_main "$@"
fi
