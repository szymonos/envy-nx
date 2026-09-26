: '
# Sourced by nx.sh, not run directly. After `source .assets/lib/nx.sh`:
nx_main version
nx_main doctor
nx_main self update
nx_main setup --shell
'

# nx tool-itself verbs (setup, self, doctor, version, help).
#
# Sourced by nx.sh; expects shared helpers (_nx_find_lib,
# _nx_read_install_field) and constants (_NX_ENV_DIR, _NX_INSTALL_JSON,
# _NX_DEFAULT_REPO_URL) to already be defined.

function _nx_self_sync() {
  # Delegate to the freshly pulled nix/setup.sh instead of doing our own file
  # copy, so the *latest* phase_bootstrap_sync_env_dir determines the file
  # list - critical for cross-major upgrades, where an OLD installed copy of
  # this function would otherwise know nothing about new lib files (e.g.
  # 1.3.x -> 1.5.x added nx_pkg.sh / nx_scope.sh / nx_profile.sh /
  # nx_lifecycle.sh, so the OLD sync left the install half-broken).
  # --sync-only stops right after that sync: packages, profiles and tool
  # configs are left for `nx upgrade`. --skip-repo-update because the caller
  # (`_nx_self_dispatch update`) already pulled.
  local repo_path="$1"
  if [ ! -x "$repo_path/nix/setup.sh" ]; then
    printf "\e[31mnx self sync: %s/nix/setup.sh not found or not executable\e[0m\n" "$repo_path" >&2
    return 1
  fi
  bash "$repo_path/nix/setup.sh" --skip-repo-update --sync-only
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
      case " $* " in
      *" --help "* | *" -h "*)
        printf "nx setup runs nix/setup.sh from the envy-nx repo, and none is on disk.\n"
        printf "Run \e[1mnx setup\e[0m to clone it to %s, then nx setup --help.\n" "$_setup_target"
        return 0
        ;;
      esac
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
  local _setup_rc=$?
  # force the nx() wrapper to re-source the nx.sh setup just synced
  unset -f nx_main
  return "$_setup_rc"
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
      printf "\e[33m[warn] the upgrade is NOT complete until you run: cd %s && nx setup\e[0m\n" "$_self_new" >&2
      printf "\e[33m       The install record still points at the old tarball path; the new clone is not yet wired up.\e[0m\n" >&2
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

    _nx_self_sync "$_self_repo_path"
    local _self_rc=$?
    # force the nx() wrapper to re-source nx.sh on the next call
    unset -f nx_main
    return "$_self_rc"
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
  update [--force]  Update nx itself: pull the source repository and sync
                    the nx files into ~/.config/nix-env (no packages touched)
                    Default: git pull --ff-only
                    --force: fetch + reset --hard origin/<branch>
  path              Print the source repository path
  help              Show this help

To update nx and upgrade all packages in one go, run `nx upgrade`.
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
  upgrade   [--latest]     update nx and upgrade everything to the validated nixpkgs revision
  rollback                 rollback to previous profile generation
  list                     list installed packages
  scope                    manage scopes (nx scope help)
  overlay                  manage overlay directory (nx overlay help)
  pin                      manage nixpkgs revision pin (nx pin help)
  profile                  manage shell profile blocks (nx profile help)
  setup     [flags...]     add or remove scopes and themes, then upgrade (runs nix/setup.sh)
  self                     manage the source repository (nx self help)
  doctor                   run health checks
  prune                    remove old profile generations
  gc                       run nix garbage collection
  version                  show version information
  help                     show help
NX_HELP_EOF
}
# <<< nx-help generated <<<

# >>> nx-verb-help generated >>> (regenerate: python3 -m tests.hooks.gen_nx_completions)
function _nx_verb_help() {
  case "$1" in
  search)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx search <query>

search nixpkgs for a package

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  install | add)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx install <packages...>

install packages from nixpkgs

Aliases: add

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  remove | uninstall)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx remove <packages...>

remove installed packages

Aliases: uninstall

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  upgrade | update)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx upgrade [--latest]

update nx and upgrade everything to the validated nixpkgs revision

Aliases: update

Options:
  --latest    use nixpkgs-unstable HEAD instead of the validated revision (unvalidated)
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  rollback)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx rollback

rollback to previous profile generation

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  list | ls)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx list

list installed packages

Aliases: ls

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  scope)
    case "${2:-}" in
    list)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx scope list

list all scopes

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    show)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx scope show <scope>

show scope contents

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    tree)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx scope tree

show scope dependency tree

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    add)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx scope add <scope> [packages...]

create a new overlay scope

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    edit)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx scope edit <scope>

edit a scope file

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    remove | rm)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx scope remove <scope>

remove an overlay scope

Aliases: rm

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    *)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx scope <command>

manage scopes

Commands:
  list                       list all scopes
  show <scope>               show scope contents
  tree                       show scope dependency tree
  add <scope> [packages...]  create a new overlay scope
  edit <scope>               edit a scope file
  remove <scope>             remove an overlay scope
NX_VERB_HELP_EOF
      ;;
    esac
    ;;
  overlay)
    case "${2:-}" in
    list)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx overlay list

show overlay directory and contents

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    status)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx overlay status

show overlay sync status

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    *)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx overlay <command>

manage overlay directory

Commands:
  list    show overlay directory and contents
  status  show overlay sync status
NX_VERB_HELP_EOF
      ;;
    esac
    ;;
  pin)
    case "${2:-}" in
    set)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx pin set [revision]

pin nixpkgs to a specific revision

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    remove | rm)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx pin remove

remove the nixpkgs pin

Aliases: rm

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    show)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx pin show

show current pin

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    help)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx pin help

show pin help

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    *)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx pin <command>

manage nixpkgs revision pin

Commands:
  set [revision]  pin nixpkgs to a specific revision
  remove          remove the nixpkgs pin
  show            show current pin
  help            show pin help
NX_VERB_HELP_EOF
      ;;
    esac
    ;;
  profile)
    case "${2:-}" in
    doctor)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx profile doctor

check profile block health

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    regenerate)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx profile regenerate [options]

regenerate profile blocks

Options:
  --dry-run        render blocks to stdout without modifying rc files
  --shell <value>  target shell for --dry-run (bash|zsh)
  -h, --help       show this help
NX_VERB_HELP_EOF
      ;;
    uninstall)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx profile uninstall

remove profile blocks

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    help)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx profile help

show profile help

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    *)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx profile <command>

manage shell profile blocks

Commands:
  doctor      check profile block health
  regenerate  regenerate profile blocks
  uninstall   remove profile blocks
  help        show profile help
NX_VERB_HELP_EOF
      ;;
    esac
    ;;
  self)
    case "${2:-}" in
    update)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx self update [options]

update nx itself (no packages touched)

Options:
  --force     force reset to origin
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    path)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx self path

print the source repository path

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    help)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx self help

show self help

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
      ;;
    *)
      cat <<'NX_VERB_HELP_EOF'
Usage: nx self <command>

manage the source repository

Commands:
  update  update nx itself (no packages touched)
  path    print the source repository path
  help    show self help
NX_VERB_HELP_EOF
      ;;
    esac
    ;;
  doctor)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx doctor [options]

run health checks

Options:
  --strict    treat warnings as failures
  --json      JSON output
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  prune)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx prune

remove old profile generations

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  gc | clean)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx gc

run nix garbage collection

Aliases: clean

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  version)
    cat <<'NX_VERB_HELP_EOF'
Usage: nx version

show version information

Options:
  -h, --help  show this help
NX_VERB_HELP_EOF
    ;;
  *) return 1 ;;
  esac
}
# <<< nx-verb-help generated <<<
