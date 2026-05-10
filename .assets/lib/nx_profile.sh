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

  if [ -x "$HOME/.nix-profile/bin/fnm" ]; then
    printf '\n# :fnm\n'
    # fnm computes its multishell symlink dir as $XDG_RUNTIME_DIR/fnm_multishells
    # and doesn't create the parent. Rootless containers (Coder, etc.) export
    # XDG_RUNTIME_DIR=/run/user/$UID but lack systemd-logind to materialize it,
    # so fnm fails on every shell start with "Can't create the symlink for
    # multishells". Self-heal: redirect to a writable /tmp fallback when the
    # configured dir is missing.
    printf 'if [ -x "$HOME/.nix-profile/bin/fnm" ]; then\n'
    printf '  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ ! -d "$XDG_RUNTIME_DIR" ]; then\n'
    printf '    export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"\n'
    printf '    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null\n'
    printf '  fi\n'
    printf '  eval "$(fnm env --use-on-cd --shell %s)"\n' "$shell"
    printf 'fi\n'
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
    # invocation; split into three printfs so the multi-line $(if/elif)
    # helper command can be its own printf with simple single-quote escaping.
    printf 'complete -W "'
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

  local _nix_marker="nix:managed"
  local _env_marker="env:managed"
  # MIGRATION: legacy marker names from <= 1.4.x. Stripped before upserting
  # so users transitioning to the new names don't end up with duplicate
  # blocks. Safe to delete after the next major release once the install
  # base has had a chance to run regenerate at least once.
  local _legacy_nix_marker="nix-env managed"
  local _legacy_env_marker="managed env"
  local _rc _shell _tmp

  for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    case "$_rc" in
    *.bashrc) _shell="bash" ;;
    *.zshrc) _shell="zsh" ;;
    esac
    command -v "$_shell" &>/dev/null || continue
    [ -f "$_rc" ] || continue

    # MIGRATION: silently strip legacy-named blocks if present. manage_block
    # remove is a no-op when the marker is absent, so this is free for users
    # who installed at >=1.5 (no legacy blocks ever existed).
    local _migrated=false
    if grep -qF "# >>> $_legacy_nix_marker >>>" "$_rc" 2>/dev/null; then
      manage_block "$_rc" "$_legacy_nix_marker" remove
      _migrated=true
    fi
    if grep -qF "# >>> $_legacy_env_marker >>>" "$_rc" 2>/dev/null; then
      manage_block "$_rc" "$_legacy_env_marker" remove
      _migrated=true
    fi
    [ "$_migrated" = true ] && printf "\e[33mMigrated legacy marker names in %s\e[0m\n" "${_rc/#$HOME/\~}"

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

# Hoisted helpers for _nx_profile_dispatch. Defining functions inside the
# dispatcher would re-declare them on every `nx profile <verb>` call (bash
# function scope is global regardless of where `function ... { ... }` lexically
# appears). Keep them at module scope so they are defined exactly once at
# source time.

function _pb_short() { printf '%s' "${1/#$HOME/\~}"; }

# _pb_count_either <rc> <new_marker> <legacy_marker>
# Combined count: legacy markers count toward the new-marker total so a
# user who upgraded but hasn't run regenerate yet doesn't see false
# positives. After regenerate, only the new-marker count is non-zero.
function _pb_count_either() {
  local _rc="$1" _new="$2" _legacy="$3" _n _l
  _n="$(grep -cF "# >>> $_new >>>" "$_rc" 2>/dev/null || true)"
  _l="$(grep -cF "# >>> $_legacy >>>" "$_rc" 2>/dev/null || true)"
  echo "$((_n + _l))"
}

# _pb_doctor_one <rc> <new_marker> <legacy_marker>
# Reports a single block's health (warn/fail) and updates _pb_ok in the
# caller's scope (set by _nx_profile_dispatch's `doctor` arm via bash
# dynamic scoping). Inlined call (rather than a for-loop over pairs)
# because legacy marker names contain a space and would mis-split under
# unquoted IFS expansion.
function _pb_doctor_one() {
  local _rc="$1" _new="$2" _legacy="$3" _count
  _count="$(_pb_count_either "$_rc" "$_new" "$_legacy")"
  if [ "$_count" -eq 0 ] 2>/dev/null; then
    printf "\e[33m  [warn] no '%s' block - run: nx profile regenerate\e[0m\n" "$_new" >&2
    _pb_ok=false
  elif [ "$_count" -gt 1 ] 2>/dev/null; then
    printf "\e[31m  [fail] %s duplicate '%s' blocks - run: nx profile regenerate\e[0m\n" \
      "$_count" "$_new" >&2
    _pb_ok=false
  fi
}

function _nx_profile_dispatch() {
  local _pb_marker="nix:managed"
  local _pb_env_marker="env:managed"
  # MIGRATION: legacy marker names from <= 1.4.x. The doctor arm treats them
  # as equivalent to the new names (silent migration); the uninstall arm
  # removes both. Safe to delete after the next major release.
  local _pb_legacy_marker="nix-env managed"
  local _pb_legacy_env_marker="managed env"
  local _pb_rc_files=()
  command -v bash &>/dev/null && _pb_rc_files+=("$HOME/.bashrc")
  command -v zsh &>/dev/null && _pb_rc_files+=("$HOME/.zshrc")

  local _pb_lib_path
  _pb_lib_path="$(_nx_find_lib profile_block.sh)" && source "$_pb_lib_path"

  case "${1:-help}" in
  doctor)
    local _pb_ok=true
    local _pb_rc
    for _pb_rc in "${_pb_rc_files[@]}"; do
      [ -f "$_pb_rc" ] || continue
      printf "\e[96mChecking %s\e[0m\n" "$(_pb_short "$_pb_rc")"
      _pb_doctor_one "$_pb_rc" "$_pb_env_marker" "$_pb_legacy_env_marker"
      _pb_doctor_one "$_pb_rc" "$_pb_marker" "$_pb_legacy_marker"
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
      # MIGRATION: also remove legacy-named blocks for users who never ran
      # regenerate after upgrading.
      manage_block "$_pb_rc" "$_pb_legacy_marker" remove
      manage_block "$_pb_rc" "$_pb_legacy_env_marker" remove
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
