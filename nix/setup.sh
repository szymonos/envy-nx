#!/usr/bin/env bash
# Universal dev environment setup - works on macOS, WSL/Linux, and containers.
# Uses Nix with a buildEnv flake for declarative, cross-platform package management.
# No root/sudo required after the one-time Nix install (see install_nix.sh).
# Additive: scope flags add to existing config; without flags, reconfigures
# using existing package versions. Use --upgrade to pull latest packages.
: '
# :run without scope flags (reconfigure, re-use existing package versions)
nix/setup.sh
# :upgrade all packages to latest nixpkgs
nix/setup.sh --upgrade
# :add new scopes (merged with existing config)
nix/setup.sh --pwsh
nix/setup.sh --k8s-base --pwsh --python --omp-theme "base"
nix/setup.sh --az --k8s-base --pwsh --python --nodejs --omp-theme "base"
nix/setup.sh --az --k8s-dev --pwsh --python --bun --omp-theme "nerd"
nix/setup.sh --az --k8s-ext --rice --pwsh
# :run with oh-my-posh theme
nix/setup.sh --shell --omp-theme "base"
# :run with starship prompt
nix/setup.sh --shell --starship-theme "nerd"
# :remove a scope
nix/setup.sh --remove oh_my_posh
# :unattended mode (skip all interactive steps - for MDM/Ansible/CI)
nix/setup.sh --all --unattended
# :install everything
nix/setup.sh --all
# :show help
nix/setup.sh --help
'
set -eo pipefail

# When launched from a pwsh shell, clean up .NET side-effects:
# 1. LD_LIBRARY_PATH: .NET injects nix store library paths that cause glibc
#    conflicts when nix commands run as children.
# 2. PATH: pwsh adds its share/powershell directory to PATH, which contains
#    the unwrapped pwsh binary (no LD_LIBRARY_PATH setup for libicu/openssl).
#    This shadows the nix bin/pwsh wrapper and causes startup aborts.
unset LD_LIBRARY_PATH 2>/dev/null || true
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/share/powershell$' | tr '\n' ':')"
PATH="${PATH%:}"
export PATH

# ---- resolve paths -----------------------------------------------------------
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_ROOT/nix/lib"
pushd "$SCRIPT_ROOT" >/dev/null

# ---- source libraries --------------------------------------------------------
# shellcheck source=lib/io.sh
source "$LIB_DIR/io.sh"
for _p in bootstrap platform scopes nix_profile configure profiles post_install summary; do
  # shellcheck source=/dev/null
  source "$LIB_DIR/phases/$_p.sh"
done
# shellcheck source=../.assets/lib/install_record.sh
source "$SCRIPT_ROOT/.assets/lib/install_record.sh"
# shellcheck source=../.assets/lib/setup_log.sh
source "$SCRIPT_ROOT/.assets/lib/setup_log.sh"

# ---- trap + provenance -------------------------------------------------------
_IR_ENTRY_POINT="nix"
_IR_SCRIPT_ROOT="$SCRIPT_ROOT"
_IR_REPO_PATH="$SCRIPT_ROOT"
_IR_REPO_URL=""
if git -C "$SCRIPT_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
  _ir_remote="$(git -C "$SCRIPT_ROOT" remote get-url origin 2>/dev/null)" || true
  case "$_ir_remote" in
  https://*) _IR_REPO_URL="$_ir_remote" ;;
  git@*:*)   _IR_REPO_URL="https://$(printf '%s' "$_ir_remote" | sed 's|^git@||; s|:|/|')" ;;
  esac
  unset _ir_remote
fi
[ -z "$_IR_REPO_URL" ] && _IR_REPO_URL="https://github.com/szymonos/envy-nx.git"
_ir_phase="bootstrap"
_ir_skip=false
_ir_error=""
_mode="unknown"
platform="unknown"
sorted_scopes=()

_on_exit() {
  local exit_code=$?
  local log_path="$_SETUP_LOG_FILE"
  setup_log_close
  [[ "$_ir_skip" == "true" ]] && return 0
  local status="success" error=""
  if [[ $exit_code -ne 0 ]]; then
    status="failed"
    error="${_ir_error:-exit code $exit_code}"
    if [[ -n "$log_path" ]]; then
      printf "\n\e[31;1mSetup failed at phase '%s'.\e[0m\n" "$_ir_phase" >&2
      printf "\e[33mCheck %s for details.\e[0m\n\n" "$log_path" >&2
    fi
  fi
  _IR_SCOPES="${sorted_scopes[*]:-}"
  _IR_ALLOW_UNFREE="${allow_unfree:-false}"
  _IR_MODE="${_mode:-unknown}"
  _IR_PLATFORM="${platform:-unknown}"
  write_install_record "$status" "$_ir_phase" "$error"
  popd >/dev/null 2>&1 || true
}
trap _on_exit EXIT

# ---- run phases --------------------------------------------------------------
setup_log_start

phase_bootstrap_check_root
phase_bootstrap_resolve_paths "$SCRIPT_ROOT"
phase_bootstrap_detect_nix
phase_bootstrap_verify_store
phase_bootstrap_sync_env_dir
phase_bootstrap_install_jq

# source scopes library (requires jq - must come after bootstrap)
# shellcheck source=../.assets/lib/scopes.sh
source "$SCRIPT_ROOT/.assets/lib/scopes.sh"

phase_bootstrap_parse_args "$@"
phase_summary_detect_mode

phase_platform_detect
_ir_phase="pre-setup"

export NIX_ENV_PHASE="pre-setup"
phase_platform_run_hooks "$ENV_DIR/hooks/pre-setup.d"
phase_platform_discover_overlay

_ir_phase="scope-resolve"

phase_scopes_load_existing
phase_scopes_apply_removes
phase_scopes_enforce_prompt_exclusivity
phase_scopes_resolve_and_sort
phase_scopes_skip_system_prefer
phase_scopes_detect_init
phase_scopes_write_config

_ir_phase="nix-profile"

phase_nix_profile_load_pinned_rev
phase_nix_profile_print_mode
phase_nix_profile_update_flake
phase_nix_profile_apply
phase_nix_profile_mitm_probe

_ir_phase="configure"

# shellcheck disable=SC2154  # unattended - set by phase_bootstrap_parse_args
phase_configure_gh "$unattended"
phase_configure_git "$unattended"
phase_configure_per_scope

_ir_phase="profiles"

phase_profiles_bash
phase_profiles_zsh
phase_profiles_pwsh
export NIX_ENV_PHASE="post-setup"
phase_platform_run_hooks "$ENV_DIR/hooks/post-setup.d"

_ir_phase="post-install"

# shellcheck disable=SC2154  # update_modules - set by phase_bootstrap_parse_args
phase_post_install_common "$update_modules" "${sorted_scopes[@]}"

_ir_phase="complete"

phase_post_install_gc
setup_log_close
# re-detect: scope removal may have changed the mode
phase_summary_detect_mode
phase_summary_print
