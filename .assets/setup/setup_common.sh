#!/usr/bin/env bash
: '
# common post-install setup (called by nix/setup.sh, which is invoked by wsl_setup.ps1, linux_setup.sh, or directly)
.assets/setup/setup_common.sh shell zsh az k8s_base pwsh
# with module updates
.assets/setup/setup_common.sh --update-modules shell zsh pwsh
'
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  printf '\e[31;1mDo not run the script as root.\e[0m\n' >&2
  exit 1
fi

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

info()  { printf "\e[96m%s\e[0m\n" "$*"; }
ok()    { printf "\e[32m%s\e[0m\n" "$*"; }
warn()  { printf "\e[33m%s\e[0m\n" "$*" >&2; }

# Invoke pwsh -nop via the nix wrapper, clearing LD_LIBRARY_PATH inside pwsh.
# Must use the nix bin/pwsh wrapper (not share/powershell/pwsh) because the
# wrapper sets LD_LIBRARY_PATH for .NET dependencies (libicu, openssl, etc.).
# When run from a pwsh parent, PATH may resolve to the unwrapped inner binary
# which lacks these library paths and aborts at startup.
# The $env:LD_LIBRARY_PATH = $null inside pwsh prevents .NET from leaking
# nix store library paths into child processes.
# Usage: _pwsh_nop script.ps1 [-Param]  or  _pwsh_nop -c 'command'
_pwsh_nop() {
  local _pwsh="$HOME/.nix-profile/bin/pwsh"
  if [[ "${1:-}" == "-c" ]]; then
    shift
    "$_pwsh" -nop -c '$env:LD_LIBRARY_PATH = $null; '"$1"
  else
    local _cmd
    printf -v _cmd '$env:LD_LIBRARY_PATH = $null; & "%s"' "$1"
    shift
    [[ $# -gt 0 ]] && _cmd+=" $*"
    "$_pwsh" -nop -c "$_cmd"
  fi
}

update_modules="false"
if [[ "${1:-}" == "--update-modules" ]]; then
  update_modules="true"
  shift
fi
scopes=("$@")

has_scope() {
  local s="$1"
  for sc in "${scopes[@]}"; do
    [[ "$sc" == "$s" ]] && return 0
  done
  return 1
}

# -- Copilot CLI (shell scope, skip in CI) ------------------------------------
if has_scope shell && [ -z "${CI:-}" ]; then
  "$SCRIPT_ROOT/.assets/provision/install_copilot.sh"
fi

# -- Zsh plugins (zsh scope) --------------------------------------------------
if has_scope zsh && command -v zsh &>/dev/null; then
  info "setting up zsh profile for current user..."
  "$SCRIPT_ROOT/.assets/setup/setup_profile_user.zsh"
fi

# -- PowerShell user profile + modules (pwsh scope) ---------------------------
if command -v pwsh &>/dev/null; then
  info "setting up PowerShell profile for current user..."
  if [[ "$update_modules" == "true" ]]; then
    _pwsh_nop "$SCRIPT_ROOT/.assets/setup/setup_profile_user.ps1" -UpdateModules
  else
    _pwsh_nop "$SCRIPT_ROOT/.assets/setup/setup_profile_user.ps1"
  fi

  info "installing PS modules..."
  modules=('do-common' 'do-linux')
  has_scope az && modules+=(do-az) || true
  command -v git &>/dev/null && modules+=(aliases-git) || true
  command -v kubectl &>/dev/null && modules+=(aliases-kubectl) || true
  printf "\e[3;32mCurrentUser\e[23m : %s\e[0m\n" "${modules[*]}"
  mods=''
  for element in "${modules[@]}"; do
    mods="$mods'$element',"
  done
  pushd "$SCRIPT_ROOT" >/dev/null
  _pwsh_nop -c "@(${mods%,}) | .assets/scripts/module_manage.ps1 -CleanUp"
  popd >/dev/null

  if has_scope az; then
    cmnd='if (-not (Get-Module -ListAvailable "Az")) {
  Write-Host "installing Az..."
  Install-PSResource Az -WarningAction SilentlyContinue -ErrorAction Stop
}
if (-not (Get-Module -ListAvailable "Az.ResourceGraph")) {
  Write-Host "installing Az.ResourceGraph..."
  Install-PSResource Az.ResourceGraph -ErrorAction Stop
}'
    _pwsh_nop -c "$cmnd"
  fi
fi
