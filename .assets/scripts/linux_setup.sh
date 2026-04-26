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
    declare $param="$2"
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
  fi
  _IR_ENTRY_POINT="linux"
  _IR_SCOPES="${scope_arr[*]:-}"
  _IR_MODE="install"
  _IR_PLATFORM="Linux"
  write_install_record "$status" "$_ir_phase" "$error"
}
trap _on_exit EXIT

# *System prep: base packages, optional upgrade, nix bootstrap
if [ "$sys_upgrade" = true ]; then
  printf "\e[96mupdating system...\e[0m\n"
  sudo .assets/provision/upgrade_system.sh
fi
printf "\e[96minstalling base packages...\e[0m\n"
sudo .assets/provision/install_base.sh
printf "\e[96minstalling nix...\e[0m\n"
sudo .assets/provision/install_nix.sh

_ir_phase="scope-resolve"
# -- Source shared scope library (requires jq from install_base) --------------
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
# shellcheck disable=SC2154  # sorted_scopes is populated by sort_scopes
scope_arr=("${sorted_scopes[@]}")

# get distro name from os-release
. /etc/os-release
# display distro name and scopes to install
printf "\e[95m$NAME$([ "${#scope_arr[@]}" -gt 0 ] && echo " : \e[3m${scope_arr[*]}" || true)\e[0m\n"

_ir_phase="scopes"
# -- Root-requiring scopes (nix cannot install these) -------------------------
for sc in "${scope_arr[@]}"; do
  case $sc in
  distrobox)
    printf "\e[96minstalling distrobox...\e[0m\n"
    sudo .assets/provision/install_podman.sh
    sudo .assets/provision/install_distrobox.sh $user
    ;;
  docker)
    printf "\e[96minstalling docker...\e[0m\n"
    sudo .assets/provision/install_docker.sh $user
    ;;
  zsh)
    printf "\e[96minstalling zsh system-wide...\e[0m\n"
    sudo .assets/provision/install_zsh.sh
    ;;
  esac
done

# -- Build nix/setup.sh arguments and delegate --------------------------------
nix_args=(--unattended --quiet-summary)
[ "$update_modules" = true ] && nix_args+=(--update-modules)
for sc in "${scope_arr[@]}"; do
  case $sc in
  distrobox|docker) continue ;;
  esac
  nix_args+=("--${sc//_/-}")
done
[ -n "$omp_theme" ] && nix_args+=(--omp-theme "$omp_theme")
printf "\e[96mrunning nix setup...\e[0m\n"
nix/setup.sh "${nix_args[@]}"

_ir_phase="complete"
# restore working directory
popd >/dev/null
