$ErrorActionPreference = 'Stop'

. $PSScriptRoot/Functions/scopes.ps1
. $PSScriptRoot/Functions/wsl.ps1
. $PSScriptRoot/Functions/wsl_install.ps1
. $PSScriptRoot/Functions/wsl_phases.ps1
. $PSScriptRoot/Functions/wsl_provenance.ps1
# load shared scope definitions from JSON
$scopesData = [System.IO.File]::ReadAllText("$PSScriptRoot/../../.assets/lib/scopes.json") | ConvertFrom-Json
[string[]]$Script:ValidScopes = $scopesData.valid_scopes
[string[]]$Script:InstallOrder = $scopesData.install_order
$Script:ScopeDependencyRules = $scopesData.dependency_rules

$exportModuleMemberParams = @{
    Function = @(
        # scopes
        'Resolve-ScopeDeps'
        'Get-SortedScopes'
        # wsl
        'Get-WslDistro'
        'Set-WslConf'
        # wsl install
        'Get-WslGhConfigFromDefault'
        'Get-WslMigrationChoice'
        'Install-WslDistroIfMissing'
        'Install-WslService'
        'Invoke-WslDistroMigration'
        'Resolve-WslGtkThemePreference'
        # wsl phases
        'Install-WslScopes'
        'Invoke-WslBaseSetup'
        'Invoke-WslDistroCheck'
        'Resolve-WslDistroScopes'
        'Set-WslGitConfig'
        'Set-WslGtkTheme'
        'Sync-WslGitHubConfig'
        'Sync-WslSshKeys'
        # wsl provenance
        'Get-WslInstallVersion'
        'Write-WslInstallRecord'
    )
    Variable = @()
    Alias    = @()
}

Export-ModuleMember @exportModuleMemberParams
