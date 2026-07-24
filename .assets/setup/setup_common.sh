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

# shellcheck source=../lib/helpers.sh
source "$SCRIPT_ROOT/.assets/lib/helpers.sh"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

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
  # install PS modules first, so setup_profile_user.ps1 can register completers
  # gated on module functions (e.g. Register-MakeCompleter in do-unix). Running
  # the profile setup before the modules are on disk silently skips those blocks
  # on a first provision - they'd only appear on a re-run.
  info "installing PS modules..."
  modules=('do-common' 'do-unix')
  has_scope az && modules+=(do-az) || true
  command -v git &>/dev/null && modules+=(aliases-git) || true
  command -v kubectl &>/dev/null && modules+=(aliases-kubectl) || true
  printf "\e[3;32mCurrentUser\e[23m : %s\e[0m\n" "${modules[*]}"
  mods=''
  for element in "${modules[@]}"; do
    mods="$mods'$element',"
  done
  pushd "$SCRIPT_ROOT" >/dev/null
  # CLEANUP: CQ-002 - remove legacy do-linux module (renamed to do-unix)
  _io_pwsh_nop -c "if (Get-Module do-linux -ListAvailable) { .assets/scripts/module_manage.ps1 do-linux -Delete }" || true
  _io_pwsh_nop -c "@(${mods%,}) | .assets/scripts/module_manage.ps1 -CleanUp"
  popd >/dev/null

  info "setting up PowerShell profile for current user..."
  if [[ "$update_modules" == "true" ]]; then
    _io_pwsh_nop "$SCRIPT_ROOT/.assets/setup/setup_profile_user.ps1" -UpdateModules
  else
    _io_pwsh_nop "$SCRIPT_ROOT/.assets/setup/setup_profile_user.ps1"
  fi

  # install Az modules last: after setup_profile_user.ps1 has trusted PSGallery
  # (for unattended Install-PSResource) and after do-common is present.
  if has_scope az; then
    cmnd='if (-not (Get-Module -ListAvailable "Az")) {
  Write-Host "installing Az..."
  Install-PSResource Az -WarningAction SilentlyContinue -ErrorAction Stop
}
if (-not (Get-Module -ListAvailable "Az.ResourceGraph")) {
  Write-Host "installing Az.ResourceGraph..."
  Install-PSResource Az.ResourceGraph -ErrorAction Stop
}
# disable the WAM broker: a Windows feature, non-functional on Linux (msalruntime.so),
# so interactive Az login must fall through to the browser auth-code flow (wslview
# shim). Runs here, after Az.Accounts exists. Idempotent - skip if already off.
# Use a truthy test + numeric 0 for the [bool] param (avoid $false).
if ((Get-AzConfig -EnableLoginByWam).Value) {
  Write-Host "disabling WAM login for Az PowerShell..."
  Set-AzConfig -EnableLoginByWam 0 -Scope CurrentUser -WarningAction SilentlyContinue | Out-Null
}'
    _io_pwsh_nop -c "$cmnd"
  fi
fi
