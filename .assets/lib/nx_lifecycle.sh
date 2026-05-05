# nx tool-itself verbs (setup, self, doctor, version, help).
#
# Sourced by nx.sh; expects shared helpers (_nx_find_lib,
# _nx_read_install_field) and constants (_NX_ENV_DIR, _NX_INSTALL_JSON,
# _NX_DEFAULT_REPO_URL) to already be defined.

function _nx_self_sync() {
  # Delegate to nix/setup.sh --skip-repo-update instead of doing our own
  # file copy. This guarantees the *latest* phase_bootstrap_sync_env_dir
  # determines the file list - critical for cross-major upgrades, where
  # an OLD installed copy of this function would otherwise know nothing
  # about new lib files (e.g. 1.3.x -> 1.5.x added nx_pkg.sh /
  # nx_scope.sh / nx_profile.sh / nx_lifecycle.sh, so the OLD sync left
  # the install half-broken). Skipping --skip-repo-update would also be
  # fine - the auto-refresh-and-exec chain in setup.sh handles the pull
  # - but the caller (`_nx_self_dispatch update`) already pulled, so
  # explicit --skip-repo-update saves a wasted ls-remote round-trip.
  local repo_path="$1"
  if [ ! -x "$repo_path/nix/setup.sh" ]; then
    printf "\e[31mnx self sync: %s/nix/setup.sh not found or not executable\e[0m\n" "$repo_path" >&2
    return 1
  fi
  bash "$repo_path/nix/setup.sh" --skip-repo-update
}

function _nx_lifecycle_version() {
  local install_json="$_NX_INSTALL_JSON"
  if [ ! -f "$install_json" ]; then
    printf "\e[33mNo install record found.\e[0m\n"
    return 0
  fi
  if ! type jq &>/dev/null; then
    cat "$install_json"
    return 0
  fi
  # `ir_status` (not `status`) - `$status` is a zsh special read-only
  # variable (the exit code of the last command, equivalent to bash's `$?`)
  # and `local status=...` errors with `read-only variable: status` under
  # zsh. nx_lifecycle.sh is sourced into the user's interactive shell
  # (bash AND zsh), so all locals must avoid zsh's read-only specials.
  local ver entry src src_ref scopes installed_at mode ir_status phase plat nix_ver bash_ver err_msg
  ver="$(jq -r '.version // "unknown"' "$install_json")"
  entry="$(jq -r '.entry_point // "unknown"' "$install_json")"
  src="$(jq -r '.source // "unknown"' "$install_json")"
  src_ref="$(jq -r '.source_ref // "" | if . == "" then "n/a" else .[0:12] end' "$install_json")"
  scopes="$(jq -r '.scopes // [] | join(", ")' "$install_json")"
  installed_at="$(jq -r '.installed_at // "unknown"' "$install_json")"
  mode="$(jq -r '.mode // "unknown"' "$install_json")"
  ir_status="$(jq -r '.status // "unknown"' "$install_json")"
  phase="$(jq -r '.phase // "unknown"' "$install_json")"
  plat="$(jq -r '"\(.platform // "unknown")/\(.arch // "unknown")"' "$install_json")"
  nix_ver="$(jq -r '.nix_version // ""' "$install_json")"
  bash_ver="$(jq -r '.bash_version // ""' "$install_json")"
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
  local repo_path
  repo_path="$(jq -r '.repo_path // ""' "$install_json")"
  [ -n "$repo_path" ] && printf "  \e[90mRepo:      \e[0m%s\n" "$repo_path"
  printf "  \e[90mPlatform:  \e[0m%s\n" "$plat"
  printf "  \e[90mMode:      \e[0m%s\n" "$mode"
  if [ "$ir_status" = "success" ]; then
    printf "  \e[90mStatus:    \e[32m%s\e[0m\n" "$ir_status"
  else
    printf "  \e[90mStatus:    \e[31m%s\e[0m (phase: %s)\n" "$ir_status" "$phase"
    [ -n "$err_msg" ] && printf "  \e[90mError:     \e[31m%s\e[0m\n" "$err_msg"
  fi
  printf "  \e[90mInstalled: \e[0m%s\n" "$installed_at"
  [ -n "$nix_ver" ] && printf "  \e[90mNix:       \e[0m%s\n" "$nix_ver"
  [ -n "$bash_ver" ] && printf "  \e[90mBash:      \e[0m%s\n" "$bash_ver"
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

function _nx_lifecycle_setup() {
  # primary: install.json:repo_path if it points to a valid envy-nx checkout.
  # fallback: canonical szymonos location (cloned on demand, no prompt).
  local _setup_target _setup_recorded
  _setup_recorded="$(_nx_read_install_field repo_path)"

  if [ -n "$_setup_recorded" ] && [ -f "$_setup_recorded/nix/setup.sh" ]; then
    _setup_target="$_setup_recorded"
  else
    _setup_target="$HOME/source/repos/szymonos/envy-nx"
    if [ -n "$_setup_recorded" ] && [ "$_setup_recorded" != "$_setup_target" ]; then
      printf "\e[33mRecorded repo_path %s is missing - falling back to %s\e[0m\n" \
        "$_setup_recorded" "$_setup_target"
    fi
    if [ -e "$_setup_target" ] && [ ! -f "$_setup_target/nix/setup.sh" ]; then
      printf "\e[31mPath exists but is not an envy-nx repo: %s\e[0m\n" "$_setup_target" >&2
      return 1
    fi
    if [ ! -d "$_setup_target" ]; then
      local _setup_repo_url
      _setup_repo_url="$(_nx_read_install_field repo_url)"
      [ -z "$_setup_repo_url" ] && _setup_repo_url="$_NX_DEFAULT_REPO_URL"
      printf "\e[96mCloning %s -> %s\e[0m\n" "$_setup_repo_url" "$_setup_target"
      mkdir -p "$(dirname "$_setup_target")"
      git clone "$_setup_repo_url" "$_setup_target" || {
        printf "\e[31mClone failed.\e[0m\n" >&2
        return 1
      }
    fi
  fi

  # No "Running setup from ..." print here - phase_bootstrap_print_banner in
  # nix/setup.sh emits the same line with the version field appended, so a
  # print here would just duplicate it. The banner runs early in setup.sh
  # (right after phase_bootstrap_resolve_paths) so it shows up at the same
  # spot users were used to seeing this line.
  bash "$_setup_target/nix/setup.sh" "$@"
}

function _nx_self_dispatch() {
  case "${1:-help}" in
  update)
    shift
    local _self_force=false
    [ "${1:-}" = "--force" ] && {
      _self_force=true
      shift
    }

    local _self_repo_path
    _self_repo_path="$(_nx_read_install_field repo_path)"

    if [ -z "$_self_repo_path" ] || [ ! -d "$_self_repo_path" ]; then
      printf "\e[31mRepo not found at %s\e[0m\n" "${_self_repo_path:-<not set>}" >&2
      printf "Run \e[1mnx setup\e[0m to clone and re-run the bootstrapper.\n" >&2
      return 1
    fi

    if [ ! -d "$_self_repo_path/.git" ]; then
      local _self_repo_url
      _self_repo_url="$(_nx_read_install_field repo_url)"
      [ -z "$_self_repo_url" ] && _self_repo_url="$_NX_DEFAULT_REPO_URL"
      printf "\e[33mInstalled from tarball - converting to git.\e[0m\n"
      # Refuse the prompt when stdin isn't a terminal - `</dev/tty` would
      # otherwise block forever in non-interactive contexts (cron, scripts
      # piping nx, etc.). See ARCHITECTURE.md §7.9.
      if [ ! -t 0 ]; then
        printf "\e[31mNon-interactive shell - cannot prompt for clone.\e[0m\n" >&2
        printf "Re-run from an interactive shell, or git clone %s manually.\n" "$_self_repo_url" >&2
        return 1
      fi
      printf "Clone from %s? [Y/n] " "$_self_repo_url"
      local _self_reply
      read -r _self_reply </dev/tty # tty-ok
      case "$_self_reply" in
      [nN]*)
        return 1
        ;;
      esac
      local _self_parent
      _self_parent="$(dirname "$_self_repo_path")"
      local _self_new="$_self_parent/envy-nx"
      git clone "$_self_repo_url" "$_self_new" || {
        printf "\e[31mClone failed.\e[0m\n" >&2
        return 1
      }
      printf "\e[32mCloned to %s\e[0m\n" "$_self_new"
      printf "Run \e[1mnx setup\e[0m from the new clone to update install record.\n"
      return 0
    fi

    printf "\e[96mUpdating %s\e[0m\n" "$_self_repo_path"
    if [ "$_self_force" = true ]; then
      git -C "$_self_repo_path" fetch origin || {
        printf "\e[31mFetch failed.\e[0m\n" >&2
        return 1
      }
      local _self_branch
      _self_branch="$(git -C "$_self_repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || _self_branch="main"
      git -C "$_self_repo_path" reset --hard "origin/$_self_branch" || {
        printf "\e[31mReset failed.\e[0m\n" >&2
        return 1
      }
      printf "\e[32mForce-updated to origin/%s\e[0m\n" "$_self_branch"
    else
      git -C "$_self_repo_path" pull --ff-only || {
        printf "\e[31mFast-forward failed.\e[0m Use \e[1mnx self update --force\e[0m to reset.\n" >&2
        return 1
      }
      printf "\e[32mUpdated.\e[0m\n"
    fi

    # `_nx_self_sync` now runs the full setup pipeline (no separate "run
    # nx setup" follow-up needed) - keeps the upgrade chain in lockstep
    # with the latest phase_bootstrap_sync_env_dir.
    _nx_self_sync "$_self_repo_path"
    # force the nx() wrapper to re-source nx.sh on the next call
    unset -f nx_main
    ;;
  path)
    local _self_path
    _self_path="$(_nx_read_install_field repo_path)"
    if [ -n "$_self_path" ]; then
      printf '%s\n' "$_self_path"
    else
      printf "\e[33mNo repo path recorded.\e[0m Run \e[1mnx setup\e[0m to set it.\n" >&2
      return 1
    fi
    ;;
  help | *)
    cat <<'SELF_HELP'
Usage: nx self <command>

Commands:
  update [--force]  Update the source repository
                    Default: git pull --ff-only
                    --force: fetch + reset --hard origin/<branch>
  path              Print the source repository path
  help              Show this help

After updating, run `nx setup` for a full environment re-provisioning.
SELF_HELP
    ;;
  esac
}

function _nx_lifecycle_doctor() {
  # nx.sh is sourced into the user's interactive shell (bash or zsh), so
  # we can detect which one and pass it down. nx_doctor.sh runs as a bash
  # subprocess and would otherwise have no way to know.
  local _dr_script _dr_shell="bash"
  [ -n "${ZSH_VERSION:-}" ] && _dr_shell="zsh"
  _dr_script="$(_nx_find_lib nx_doctor.sh)" || {
    printf '\e[31mnx doctor not found\e[0m\n' >&2
    return 1
  }
  NX_INVOKING_SHELL="$_dr_shell" bash "$_dr_script" "$@"
}

# >>> nx-help generated >>> (regenerate: python3 -m tests.hooks.gen_nx_completions)
function _nx_lifecycle_help() {
  cat <<'NX_HELP_EOF'
Usage: nx <command> [args]

Commands:
  search    <query>        search nixpkgs for a package
  install   <packages...>  install packages from nixpkgs
  remove    <packages...>  remove installed packages
  upgrade                  upgrade all packages
  rollback                 rollback to previous profile generation
  list                     list installed packages
  scope                    manage scopes (nx scope help)
  overlay                  manage overlay directory (nx overlay help)
  pin                      manage nixpkgs revision pin (nx pin help)
  profile                  manage shell profile blocks (nx profile help)
  setup     [flags...]     run nix/setup.sh from anywhere
  self                     manage the source repository (nx self help)
  doctor                   run health checks
  prune                    remove old profile generations
  gc                       run nix garbage collection
  version                  show version information
  help                     show help
NX_HELP_EOF
}
# <<< nx-help generated <<<
