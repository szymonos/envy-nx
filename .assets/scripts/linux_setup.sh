#!/usr/bin/env bash
: '
# :set up the system using default values
.assets/scripts/linux_setup.sh
# :set up the system using specified values
scope="pwsh"
scope="k8s_base pwsh python"
scope="az docker k8s_base pwsh terraform bun"
scope="az distrobox k8s_ext rice pwsh"
# :set up the system using the specified scope
.assets/scripts/linux_setup.sh --scope "$scope"
# :set up the system using the specified scope and omp theme
omp_theme="base"
omp_theme="nerd"
.assets/scripts/linux_setup.sh --omp_theme "$omp_theme"
.assets/scripts/linux_setup.sh --omp_theme "$omp_theme" --scope "$scope"
# :upgrade system first and then set up the system
.assets/scripts/linux_setup.sh --sys_upgrade true --scope "$scope" --omp_theme "$omp_theme"
# :unattended mode (skip all interactive steps)
.assets/scripts/linux_setup.sh --unattended true --scope "$scope" --omp_theme "$omp_theme"
'
set -e

if [ $EUID -eq 0 ]; then
  printf '\e[31;1mDo not run the script as root.\e[0m\n'
  exit 1
else
  user=$(id -un)
fi

# parse named parameters
scope=${scope}
omp_theme=${omp_theme}
sys_upgrade=${sys_upgrade:-false}
unattended=${unattended:-false}
update_modules="${update_modules:-false}"
while [ $# -gt 0 ]; do
  if [[ $1 == *"--"* ]]; then
    param="${1/--/}"
    # `declare` rejects a hyphen in a variable name, so the hyphenated spelling
    # nix/setup.sh uses (--omp-theme) has to be folded onto this script's
    # underscored one (--omp_theme). Both entry points now take either.
    param="${param//-/_}"
    declare "$param=$2"
  fi
  shift
done

# set script working directory to workspace folder
SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
pushd "$(cd "${SCRIPT_ROOT}/../../" && pwd)" >/dev/null

# -- Installation provenance (trap-based, writes on exit) --------------------
# shellcheck source=../../.assets/lib/install_record.sh
source .assets/lib/install_record.sh
_IR_SCRIPT_ROOT="$(pwd)"
_ir_phase="bootstrap"

_on_exit() {
  local exit_code=$?
  local status="success" error=""
  if [[ $exit_code -ne 0 ]]; then
    status="failed"
    error="${_ir_error:-exit code $exit_code}"
    [[ -n "$_failed_optional" ]] && error="$error (also tolerated: $_failed_optional)"
  elif [[ -n "$_failed_optional" ]]; then
    # Exit 0 with tolerated failures still means the machine is short of what
    # was asked for; "success" would make `nx doctor` pass while the tool is
    # absent. "partial" is safe to emit: nx_doctor.sh warns on any non-"success"
    # value, nx_lifecycle.sh prints it red, and nothing in CI, tests, the
    # Makefile or .assets/docker reads this script's record
    # (Dockerfile.test-nix's `.status == "success"` only sees nix/setup.sh).
    status="partial"
    error="tolerated failures: $_failed_optional"
  fi
  _IR_ENTRY_POINT="linux"
  _IR_SCOPES="${scope_arr[*]:-}"
  _IR_MODE="install"
  _IR_PLATFORM="Linux"
  write_install_record "$status" "$_ir_phase" "$error"
}
trap _on_exit EXIT

# Yellow warning to stderr (matches .assets/scripts/fix_wsl_dns.sh:38). This
# script has no ERR trap and its EXIT trap prints nothing, so a skipped
# optional step is otherwise invisible.
print_warn() { printf '\e[33m%s\e[0m\n' "$1" >&2; }

# Record an optional step that failed without aborting. `print_warn` on the
# right of `||` swallows the installer's non-zero status, so the EXIT trap
# would otherwise write status=success with the failed scope still in scopes[].
_failed_optional=""
note_optional_failure() {
  _failed_optional="${_failed_optional:+$_failed_optional }$1"
  print_warn "optional step failed: $1 - continuing setup"
}

_ir_phase="preflight-tls"
# Probe TLS before anything is installed. On debian/ubuntu apt is plain HTTP,
# so the system upgrade and base packages both succeed and the run only dies at
# the first HTTPS fetch (the nix installer), leaving a half-provisioned box with
# no rollback. Other distros fail at the package manager instead, with an error
# that names the mirror rather than the certificate.
# `sudo` scrubs the environment, so a user override of the probe URL has to be
# passed through explicitly. Only `false` is fatal: `unknown` means no probe
# tool is installed yet, which wsl_phases.ps1 also treats as non-fatal.
if [ "$(sudo NIX_ENV_TLS_PROBE_URL="${NIX_ENV_TLS_PROBE_URL:-}" .assets/check/check_ssl.sh)" = 'false' ]; then
  _ir_error='TLS verification failed - proxy certificate chain not installed'
  printf '\e[31;1mTLS verification fails from this distro - refusing to provision.\e[0m\n' >&2
  printf 'A proxy is intercepting TLS. Install its certificate chain first:\n' >&2
  printf '  from the Windows host: wsl/wsl_certs_add.ps1 <Distro>\n' >&2
  printf '  or run wsl/wsl_setup.ps1, which probes and adds certificates automatically.\n' >&2
  exit 1
fi

# *System prep: base packages, optional upgrade, nix bootstrap
# The upgrade is opt-in and advisory; a failing mirror must not block setup.
if [ "$sys_upgrade" = true ]; then
  printf "\e[96mupdating system...\e[0m\n"
  sudo .assets/provision/upgrade_system.sh || note_optional_failure system-upgrade
fi
printf "\e[96minstalling base packages...\e[0m\n"
sudo .assets/provision/install_base.sh
printf "\e[96minstalling nix...\e[0m\n"
# A daemon (multi-user) install leaves /nix root-owned and needs a running
# nix-daemon to mediate user-scope writes. Without systemd that daemon never
# starts and every `nix profile` call dies with
# `opening lock file /nix/var/nix/db/big-lock: Permission denied`; --no-daemon
# gives the invoking user an owned store instead. Duplicating install_nix.sh's
# probe is safe - passing --no-daemon takes a branch that skips its own check.
# A missing `pidof` reads as "no systemd", which is the safe direction.
nix_install_args=()
if [ "$(uname -s)" = "Linux" ] && ! pidof systemd &>/dev/null; then
  printf "\e[96mno systemd detected - installing nix in single-user mode\e[0m\n"
  nix_install_args+=(--no-daemon)
fi
sudo .assets/provision/install_nix.sh "${nix_install_args[@]}"

_ir_phase="bootstrap-jq"
# -- Bootstrap jq via nix -----------------------------------------------------
# scopes.sh hard-exits when jq is missing, and because it is *sourced* that
# exit kills this script. jq is an always-nix package - install_base.sh
# deliberately does not provide it - so it only arrives once the nix profile is
# realized. These are the same phases nix/setup.sh runs before its own
# `source scopes.sh`.
#
# install_nix.sh does not put nix on *this* shell's PATH, so
# phase_bootstrap_detect_nix (which sources the nix profile) has to run first;
# it is also what makes an already-realized jq visible to the guard below.
if ! command -v jq >/dev/null 2>&1; then
  # shellcheck source=../../nix/lib/io.sh
  source nix/lib/io.sh
  # shellcheck source=../../.assets/lib/helpers.sh
  source .assets/lib/helpers.sh
  # shellcheck source=../../nix/lib/phases/bootstrap.sh
  source nix/lib/phases/bootstrap.sh
  # phase_bootstrap_resolve_paths reassigns SCRIPT_ROOT to the repo root. This
  # script only uses its own SCRIPT_ROOT above (to pushd), so that is inert.
  phase_bootstrap_resolve_paths "$PWD"
  # Same order as nix/setup.sh: a stale NIX_SSL_CERT_FILE/SSL_CERT_FILE
  # pointing at a missing file makes the `nix profile` call below fail, and
  # this phase unsets it before that can happen.
  phase_bootstrap_ensure_certs
  phase_bootstrap_detect_nix
  phase_bootstrap_sync_env_dir
  phase_bootstrap_install_jq
fi

_ir_phase="scope-resolve"
# -- Source shared scope library (requires jq - must come after bootstrap) ----
# shellcheck source=../../.assets/lib/scopes.sh
source .assets/lib/scopes.sh

# *Calculate and show installation scopes
# run the check_distro.sh script and capture the output
distro_check=$(.assets/check/check_distro.sh array)

# build _scope_set from CLI parameter and distro check
_scope_set=" "
read -ra cli_scopes <<<"$scope"
for s in "${cli_scopes[@]}"; do
  [[ -n "$s" ]] && scope_add "$s"
done
while IFS= read -r line; do
  [[ -n "$line" ]] && scope_add "$line"
done <<<"$distro_check"
# detect oh_my_posh from existing install
# shellcheck disable=SC2034  # _scope_set is used by resolve_scope_deps
[[ -f /usr/bin/oh-my-posh ]] && scope_add oh_my_posh

# resolve dependencies and sort
resolve_scope_deps
sort_scopes
# shellcheck disable=SC2154  # _scope_sorted is populated by sort_scopes
scope_arr=("${_scope_sorted[@]}")

# get distro name from os-release
. /etc/os-release
# display distro name and scopes to install
printf "\e[95m$NAME$([ "${#scope_arr[@]}" -gt 0 ] && echo " : \e[3m${scope_arr[*]}" || true)\e[0m\n"

_ir_phase="scopes"
# -- Root-requiring scopes (nix cannot install these) -------------------------
# These scopes are optional and partly auto-detected rather than requested -
# check_distro.sh emits `zsh` from nothing more than /usr/bin/zsh existing. The
# installers fail loudly on an unsupported distro so the failure is
# diagnosable, but tolerating it here keeps one optional scope from aborting
# before nix/setup.sh and costing the whole distro-agnostic environment.
# install_base.sh / install_nix.sh above are mandatory and stay fatal.
for sc in "${scope_arr[@]}"; do
  case $sc in
  distrobox)
    printf "\e[96minstalling distrobox...\e[0m\n"
    # Chained, not two independent guards: a failed podman install must still
    # prevent distrobox from being layered on a missing container runtime.
    sudo .assets/provision/install_podman.sh &&
      sudo .assets/provision/install_distrobox.sh "$user" ||
      note_optional_failure distrobox
    ;;
  docker)
    printf "\e[96minstalling docker...\e[0m\n"
    sudo .assets/provision/install_docker.sh "$user" || note_optional_failure docker
    ;;
  zsh)
    printf "\e[96minstalling zsh system-wide...\e[0m\n"
    sudo .assets/provision/install_zsh.sh || note_optional_failure zsh
    ;;
  esac
done

# -- Build nix/setup.sh arguments and delegate --------------------------------
nix_args=(--unattended --quiet-summary)
[ "$update_modules" = true ] && nix_args+=(--update-modules)
for sc in "${scope_arr[@]}"; do
  case $sc in
  distrobox | docker) continue ;;
  # nix/setup.sh has no --oh-my-posh / --starship flag: those scopes are only
  # reachable through --omp-theme / --starship-theme, which scope_add them
  # internally (its own --all handler skips the same two). Emitting the flag
  # aborts parse_args with "Unknown option". check_distro.sh auto-detects both
  # from an existing binary, so any re-run after a prompt is installed hits it.
  oh_my_posh | starship) continue ;;
  esac
  nix_args+=("--${sc//_/-}")
done
[ -n "$omp_theme" ] && nix_args+=(--omp-theme "$omp_theme")
printf "\e[96mrunning nix setup...\e[0m\n"
nix/setup.sh "${nix_args[@]}"

_ir_phase="complete"
# Re-print tolerated failures: each warning fired before nix/setup.sh, whose
# output has almost certainly scrolled it away by now.
if [ -n "$_failed_optional" ]; then
  print_warn "setup finished, but these optional steps failed: $_failed_optional"
  print_warn "recorded as status=partial in ~/.config/dev-env/install.json"
fi
# restore working directory
popd >/dev/null
