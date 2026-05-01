# nx profile verb + the managed-block rendering it depends on.
#
# Sourced by nx.sh; expects shared helper (_nx_find_lib) to already be defined.
# `_nx_profile_regenerate` is also called directly from nix/configure/profiles.sh
# (sourcing nx.sh transitively brings this file in).

function _nx_render_env_block() {
  local skip_local_bin="${1:-false}"
  if [ "$skip_local_bin" != "true" ]; then
    printf '# :local path\n'
    printf 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)\n'
    printf '  [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"\n'
    printf 'esac\n'
  fi

  if [ -f "$HOME/.config/shell/functions.sh" ]; then
    printf '\n# :aliases\n'
    printf '[ -f "$HOME/.config/shell/functions.sh" ] && . "$HOME/.config/shell/functions.sh"\n'
  fi
  if [ -f "$HOME/.config/shell/aliases_git.sh" ] && command -v git &>/dev/null && [ ! -x "$HOME/.nix-profile/bin/git" ]; then
    printf '[ -f "$HOME/.config/shell/aliases_git.sh" ] && . "$HOME/.config/shell/aliases_git.sh"\n'
  fi
  if [ -f "$HOME/.config/shell/aliases_kubectl.sh" ] && command -v kubectl &>/dev/null && [ ! -x "$HOME/.nix-profile/bin/kubectl" ]; then
    printf '[ -f "$HOME/.config/shell/aliases_kubectl.sh" ] && . "$HOME/.config/shell/aliases_kubectl.sh"\n'
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

function _nx_render_nix_block() {
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
    printf 'case ":$PATH:" in *":$HOME/.nix-profile/bin:"*) ;; *)\n'
    printf '  export PATH="$HOME/.nix-profile/bin:$PATH"\n'
    printf 'esac\n'
  fi

  if [ -f "$HOME/.config/certs/ca-bundle.crt" ]; then
    printf 'export NIX_SSL_CERT_FILE="$HOME/.config/certs/ca-bundle.crt"\n'
  fi

  if [ -f "$HOME/.config/shell/aliases_nix.sh" ] && command -v nix &>/dev/null; then
    printf '\n# :aliases\n'
    printf '. "$HOME/.config/shell/aliases_nix.sh"\n'
  fi
  if [ -f "$HOME/.config/shell/aliases_git.sh" ] && [ -x "$HOME/.nix-profile/bin/git" ]; then
    printf '[ -f "$HOME/.config/shell/aliases_git.sh" ] && . "$HOME/.config/shell/aliases_git.sh"\n'
  fi
  if [ -f "$HOME/.config/shell/aliases_kubectl.sh" ] && [ -x "$HOME/.nix-profile/bin/kubectl" ]; then
    printf '[ -f "$HOME/.config/shell/aliases_kubectl.sh" ] && . "$HOME/.config/shell/aliases_kubectl.sh"\n'
  fi
  if [ "$shell" = "bash" ] && [ -f "$HOME/.config/shell/completions.bash" ]; then
    printf '[ -f "$HOME/.config/shell/completions.bash" ] && . "$HOME/.config/shell/completions.bash"\n'
  fi
  if [ "$shell" = "zsh" ] && [ -f "$HOME/.config/shell/completions.zsh" ]; then
    printf '[ -f "$HOME/.config/shell/completions.zsh" ] && . "$HOME/.config/shell/completions.zsh"\n'
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
    # `complete -W` is emitted text for the user's bashrc, not a runtime
    # invocation; split into three printfs so the suppression marker can
    # sit on the same source line as the `complete -W` literal.
    printf 'complete -W "' # zsh-ok: emitted text, not a runtime call
    printf '$(if [ -f Makefile ]; then grep -oE '\''^[a-zA-Z0-9_-]+:([^=]|$)'\'' Makefile | sed '\''s/[^a-zA-Z0-9_-]*$//'\''
elif [ -f makefile ]; then grep -oE '\''^[a-zA-Z0-9_-]+:([^=]|$)'\'' makefile | sed '\''s/[^a-zA-Z0-9_-]*$//'\''
fi)'
    printf '" make\n'
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

function _nx_profile_regenerate() {
  local _pb_lib_path
  _pb_lib_path="$(_nx_find_lib profile_block.sh)" || {
    printf "\e[31mprofile_block.sh not found\e[0m\n" >&2
    return 1
  }
  source "$_pb_lib_path"

  local _nix_marker="nix-env managed"
  local _env_marker="managed env"
  local _rc _shell _tmp

  for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    case "$_rc" in
    *.bashrc) _shell="bash" ;;
    *.zshrc) _shell="zsh" ;;
    esac
    command -v "$_shell" &>/dev/null || continue
    [ -f "$_rc" ] || continue

    # check if .local/bin PATH is already handled outside managed blocks
    local _has_local_bin=false
    if awk '
      /^# >>> .* >>>$/{skip=1;next} skip&&/^# <<< .* <<<$/{skip=0;next} !skip{print}
    ' "$_rc" | grep -qF '.local/bin'; then
      _has_local_bin=true
    fi

    # render and upsert env block
    _tmp="$(mktemp)"
    _nx_render_env_block "$_has_local_bin" >"$_tmp"
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

function _nx_profile_dispatch() {
  local _pb_marker="nix-env managed"
  local _pb_env_marker="managed env"
  local _pb_rc_files=()
  command -v bash &>/dev/null && _pb_rc_files+=("$HOME/.bashrc")
  command -v zsh &>/dev/null && _pb_rc_files+=("$HOME/.zshrc")

  local _pb_lib_path
  _pb_lib_path="$(_nx_find_lib profile_block.sh)" && source "$_pb_lib_path"

  function _pb_short() { printf '%s' "${1/#$HOME/\~}"; }

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
    printf "\e[96mProfile blocks removed. Sourced files in ~/.config/shell/ are untouched.\e[0m\n"
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
}
