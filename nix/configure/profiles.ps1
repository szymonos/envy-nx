#!/usr/bin/env pwsh
<#
.SYNOPSIS
Setting up PowerShell profile for Nix package manager.
Provisions config files, then delegates profile region management to nx.

.EXAMPLE
nix/configure/profiles.ps1
#>
$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'Ignore'

# resolve paths
$scriptRoot = $PSScriptRoot
$repoRoot = (Resolve-Path "$scriptRoot/../..").Path
$pwshCfg = [IO.Path]::Combine($repoRoot, '.assets/config/pwsh_cfg')

# ============================================================================
# Install user-scope alias files
# ============================================================================
$userScriptsPath = [IO.Path]::Combine(
    [Environment]::GetFolderPath('UserProfile'), '.config/powershell/Scripts')
if (-not [IO.Directory]::Exists($userScriptsPath)) {
    [IO.Directory]::CreateDirectory($userScriptsPath) | Out-Null
}
$aliasFile = '_aliases_nix.ps1'
$src = [IO.Path]::Combine($pwshCfg, $aliasFile)
$dst = [IO.Path]::Combine($userScriptsPath, $aliasFile)
if ([IO.File]::Exists($src)) {
    $needsCopy = -not [IO.File]::Exists($dst) -or
        [IO.File]::ReadAllText($src) -ne [IO.File]::ReadAllText($dst)
    if ($needsCopy) {
        [IO.File]::Copy($src, $dst, $true)
        Write-Host "`e[32minstalled $aliasFile for PowerShell`e[0m"
    }
}

# ============================================================================
# Install base profile to durable config
# ============================================================================
$envDir = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.config/nix-env')
$baseProfileSrc = [IO.Path]::Combine($pwshCfg, 'profile_nix.ps1')
$baseProfileDst = [IO.Path]::Combine($envDir, 'profile_base.ps1')
if ([IO.File]::Exists($baseProfileSrc)) {
    $needsCopy = -not [IO.File]::Exists($baseProfileDst) -or
        [IO.File]::ReadAllText($baseProfileSrc) -ne [IO.File]::ReadAllText($baseProfileDst)
    if ($needsCopy) {
        [IO.File]::Copy($baseProfileSrc, $baseProfileDst, $true)
        Write-Host "`e[32minstalled base profile for PowerShell`e[0m"
    }
}

# ============================================================================
# Delegate profile region management to nx
# ============================================================================
# Source the newly-copied alias file to get _NxProfileRegenerate
. $dst
_NxProfileRegenerate
