#Requires -PSEdition Core -Version 7.3
<#
.SYNOPSIS
Setting up WSL distro(s).
.DESCRIPTION
Uses Nix package manager for user-scope package management. You can use the script for:
- installing base packages and setting up bash and pwsh shells,
- installing docker-ce locally inside WSL distro (WSL2 only),
- installing podman with distrobox (WSL2 only),
- installing tools for interacting with kubernetes,
- setting gtk theme in WSLg (WSL2 only),
- installing Python environment management tools: uv, venv and conda,
- cloning GH repositories and setting up VSCode workspace,
- updating packages in all existing WSL distros.
When GH repositories cloning is used, you need to generate and add an SSH key to your GH account.

.PARAMETER Distro
Name of the WSL distro to set up. If not specified, script will update all existing distros.
.PARAMETER Scope
List of installation scopes. Valid values:
- az: azure-cli, azcopy, Az PowerShell module if pwsh scope specified; autoselects python scope
- bun: Bun - all-in-one JavaScript, TypeScript & JSX toolkit using JavaScriptCore engine
- conda: miniforge
- distrobox: (WSL2 only) - podman and distrobox
- docker: (WSL2 only) - docker, containerd buildx docker-compose
- gcloud: google-cloud-cli
- k8s_base: kubectl, kubelogin, k9s, kubecolor, kubectx, kubens
- k8s_dev: argorollouts, cilium, hubble, helm, flux, kustomize and trivy cli tools; autoselects k8s_base scope
- k8s_ext: (WSL2 only) - minikube, k3d, kind local kubernetes tools; autoselects docker, k8s_base and k8s_dev scopes
- nodejs: Node.js JavaScript runtime environment using V8 engine
- pwsh: PowerShell Core and corresponding PS modules; autoselects shell scope
- python: uv, prek, pip, venv
- rice: btop, cmatrix, cowsay, fastfetch
- shell: bat, eza, oh-my-posh, ripgrep, yq, copilot-cli
- terraform: terraform, terrascan, tflint, tfswitch
- zsh: zsh shell with plugins
.PARAMETER OmpTheme
Specify to install oh-my-posh prompt theme engine and name of the theme to be used.
You can specify one of the three included profiles: base, powerline, nerd,
or use any theme available on the page: https://ohmyposh.dev/docs/themes/
.PARAMETER GtkTheme
Specify gtk theme for wslg. Available values: light, dark.
Default: automatically detects based on the system theme.
.PARAMETER Repos
List of GitHub repositories in format "Owner/RepoName" to clone into the WSL.
.PARAMETER AddCertificate
Intercept and add certificates from chain into selected distro.
.PARAMETER FixNetwork
Set network settings from the selected network interface in Windows.
.PARAMETER SkipModulesUpdate
Skip updating installed PowerShell modules (Az, PSReadLine, etc.).
.PARAMETER SkipRepoUpdate
Skip updating current repository before running the setup.
.PARAMETER WebDownload
Switch, whether to use web download for WSL distro installation instead of Microsoft Store.
This is useful when the Store download is very slow or unavailable.

.EXAMPLE
$Distro = 'Ubuntu'
# :set up WSL distro using default values
wsl/wsl_setup.ps1 $Distro
wsl/wsl_setup.ps1 $Distro -AddCertificate
wsl/wsl_setup.ps1 $Distro -FixNetwork -AddCertificate
# :set up WSL distro with specified installation scopes
$Scope = @('conda', 'pwsh')
$Scope = @('conda', 'k8s_ext', 'pwsh', 'rice')
$Scope = @('az', 'docker', 'shell')
$Scope = @('az', 'k8s_base', 'pwsh', 'bun', 'terraform')
$Scope = @('az', 'gcloud', 'k8s_ext', 'pwsh')
wsl/wsl_setup.ps1 $Distro -s $Scope
wsl/wsl_setup.ps1 $Distro -s $Scope -AddCertificate
# :set up shell with the specified oh-my-posh theme
$OmpTheme = 'nerd'
wsl/wsl_setup.ps1 $Distro -s $Scope -o $OmpTheme
wsl/wsl_setup.ps1 $Distro -s $Scope -o $OmpTheme -AddCertificate
# :set up WSL distro and clone specified GitHub repositories
$Repos = @('szymonos/envy-nx')
wsl/wsl_setup.ps1 $Distro -r $Repos -s $Scope -o $OmpTheme
wsl/wsl_setup.ps1 $Distro -r $Repos -s $Scope -o $OmpTheme -AddCertificate
# :update all existing WSL distros
wsl/wsl_setup.ps1

.NOTES
# :save script example
.assets/scripts/scripts_egsave.ps1 wsl/wsl_setup.ps1
# :override the existing script example if exists
.assets/scripts/scripts_egsave.ps1 wsl/wsl_setup.ps1 -Force
# :open the example script in VSCode
code -r (.assets/scripts/scripts_egsave.ps1 wsl/wsl_setup.ps1 -WriteOutput)
#>
[CmdletBinding(DefaultParameterSetName = 'Update')]
param (
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Setup')]
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'GitHub')]
    [string]$Distro,

    [Alias('s')]
    [Parameter(ParameterSetName = 'Setup')]
    [Parameter(ParameterSetName = 'GitHub')]
    [ValidateScript(
        {
            $valid = ([System.IO.File]::ReadAllText("$PSScriptRoot/../.assets/lib/scopes.json") | ConvertFrom-Json).valid_scopes
            $_.ForEach({ $_ -in $valid }) -notcontains $false
        },
        ErrorMessage = 'Wrong scope provided. Run with -? to see valid values.')
    ]
    [string[]]$Scope,

    [Parameter(ParameterSetName = 'Update')]
    [Parameter(ParameterSetName = 'Setup')]
    [Parameter(ParameterSetName = 'GitHub')]
    [ValidateNotNullOrEmpty()]
    [string]$OmpTheme,

    [Parameter(ParameterSetName = 'Update')]
    [Parameter(ParameterSetName = 'Setup')]
    [Parameter(ParameterSetName = 'GitHub')]
    [ValidateSet('light', 'dark')]
    [string]$GtkTheme,

    [Parameter(Mandatory, ParameterSetName = 'GitHub')]
    [ValidateScript(
        { $_.ForEach({ $_ -match '^[\w-]+/[\w-]+$' }) -notcontains $false },
        ErrorMessage = 'Repos should be provided in "Owner/RepoName" format.')
    ]
    [string[]]$Repos,

    [Parameter(ParameterSetName = 'Setup')]
    [Parameter(ParameterSetName = 'GitHub')]
    [switch]$AddCertificate,

    [Parameter(ParameterSetName = 'Setup')]
    [Parameter(ParameterSetName = 'GitHub')]
    [switch]$FixNetwork,

    [switch]$SkipModulesUpdate,

    [switch]$SkipRepoUpdate,

    [switch]$WebDownload
)

begin {
    $ErrorActionPreference = 'Stop'
    # check if the script is running on Windows
    if ($IsLinux -and -not $env:WSL_SETUP_TESTING) {
        Write-Warning 'This script is intended to be run on Windows only (outside of WSL).'
        exit 1
    }

    # set location to workspace folder
    Push-Location "$PSScriptRoot/.."
    Import-Module (Convert-Path './modules/do-common') -Force
    Import-Module (Convert-Path './modules/utils-install') -Force
    Import-Module (Convert-Path './modules/utils-setup') -Force

    if (-not $SkipRepoUpdate) {
        Show-LogContext 'checking if the repository is up to date'
        if ((Update-GitRepository) -eq 2) {
            Write-Warning 'Repository has been updated. Run the script again!'
            exit 0
        }
    }

    # *get list of distros
    $lxss = Get-WslDistro | Where-Object Name -NotMatch '^docker-desktop'
    if ($PsCmdlet.ParameterSetName -ne 'Update') {
        try {
            $Distro = Install-WslDistroIfMissing `
                -Distro $Distro `
                -InstalledDistros $lxss `
                -WebDownload ([bool]$WebDownload)
        } catch {
            if ($_.Exception.Message -eq 'restart required') { exit 0 }
            exit 1
        }
        if ($lxss.Where({ $_.Name -eq $Distro }).Version -eq 1) {
            $Distro = Invoke-WslDistroMigration -Distro $Distro -WebDownload ([bool]$WebDownload)
        }
        $gh_cfg = Get-WslGhConfigFromDefault -TargetDistro $Distro -InstalledDistros $lxss
        # get installed distro details
        $lxss = Get-WslDistro -FromRegistry | Where-Object Name -EQ $Distro
    } elseif ($lxss) {
        Write-Host "Found $($lxss.Count) distro$($lxss.Count -eq 1 ? '' : 's') to update:" -ForegroundColor White
        $lxss.Name.ForEach({ Write-Host " - $_" })
    } else {
        Show-LogContext 'No installed WSL distributions found.' -Level WARNING
        exit 0
    }

    # determine GTK theme if not provided, based on system theme
    if (-not $GtkTheme) {
        $GtkTheme = Resolve-WslGtkThemePreference
    }

    # *set script variables
    $script:sshKeyFp = ''
    $script:pwshEnvSet = $true
    # sets to track success and failed distros
    $script:successDistros = [System.Collections.Generic.SortedSet[string]]::new()
    $script:failDistros = [System.Collections.Generic.SortedSet[string]]::new()
    # per-distro state for install provenance records
    $script:distroRecords = @{}
}

process {
    foreach ($lx in $lxss) {
        $Distro = $lx.Name
        $script:distroRecords[$Distro] = @{
            phase  = 'distro-check'
            scopes = @()
            mode   = $PsCmdlet.ParameterSetName -eq 'Update' ? 'update' : 'install'
            error  = ''
        }

        #region distro checks
        $chk = $null
        try {
            $chk = Invoke-WslDistroCheck -Distro $Distro -DistroRecord $script:distroRecords[$Distro]
        } catch {
            exit 1
        }
        if ($null -eq $chk) {
            $failDistros.Add($Distro) | Out-Null
            continue
        }

        # *resolve scopes from -Scope, distro check, dependencies, install order
        [string[]]$scopes = Resolve-WslDistroScopes `
            -Scope $Scope `
            -Check $chk `
            -WslVersion $lx.Version `
            -OmpTheme $OmpTheme `
            -DistroRecord $script:distroRecords[$Distro]
        # display distro name and installed scopes
        Write-Host "`n`e[95;1m${Distro}$($scopes.Count ? " :`e[0;90m $($scopes -join ', ')`e[0m" : "`e[0m")"
        $script:distroRecords[$Distro].phase = 'base-setup'
        #endregion

        #region perform base setup
        try {
            $netResult = Invoke-WslBaseSetup `
                -Distro $Distro `
                -Check $chk `
                -FixNetwork ([bool]$FixNetwork) `
                -AddCertificate ([bool]$AddCertificate) `
                -DistroRecord $script:distroRecords[$Distro]
        } catch {
            exit 1
        }
        # propagate auto-promoted switch values back to script scope
        if ($netResult.FixNetwork -and -not $FixNetwork) {
            $PSBoundParameters['FixNetwork'] = $FixNetwork = [System.Management.Automation.SwitchParameter]::new($true)
        }
        if ($netResult.AddCertificate -and -not $AddCertificate) {
            $PSBoundParameters['AddCertificate'] = $AddCertificate = [System.Management.Automation.SwitchParameter]::new($true)
        }
        #endregion

        $script:distroRecords[$Distro].phase = 'github'
        #region setup GitHub and SSH keys
        Sync-WslGitHubConfig -Distro $Distro -GhConfig $gh_cfg
        Sync-WslSshKeys -Distro $Distro -HasWslKey ([bool]$chk.ssh_key)
        #endregion

        $script:distroRecords[$Distro].phase = 'scopes'
        #region install scopes
        $scopeResult = Install-WslScopes `
            -Distro $Distro `
            -Scopes $scopes `
            -Check $chk `
            -WslVersion $lx.Version `
            -SshKeyFp $script:sshKeyFp `
            -PwshEnvSet $script:pwshEnvSet `
            -OmpTheme $OmpTheme `
            -SkipModulesUpdate ([bool]$SkipModulesUpdate) `
            -DistroRecord $script:distroRecords[$Distro]
        $script:sshKeyFp = $scopeResult.SshKeyFp
        $script:pwshEnvSet = $scopeResult.PwshEnvSet
        if (-not $scopeResult.Success) {
            $failDistros.Add($Distro) | Out-Null
            continue
        }
        #endregion

        $script:distroRecords[$Distro].phase = 'post-install'
        Set-WslGtkTheme -Distro $Distro -Check $chk -WslVersion $lx.Version -GtkTheme $GtkTheme
        Set-WslGitConfig -Distro $Distro -Check $chk

        # mark distro as successfully set up
        $script:distroRecords[$Distro].phase = 'complete'
        $successDistros.Add($Distro) | Out-Null
    }
    #region clone GitHub repositories
    if ($PsCmdlet.ParameterSetName -eq 'GitHub' -and $Distro -notin $failDistros) {
        Show-LogContext 'cloning GitHub repositories'
        wsl.exe --distribution $Distro --exec .assets/setup/setup_gh_repos.sh --repos "$Repos"
    }
    #endregion
}

end {
    if ($successDistros.Count) {
        if ($successDistros.Count -eq 1) {
            Write-Host "`n`e[95m<< `e[1m$successDistros`e[22m WSL distro was set up successfully >>`e[0m`n"
        } else {
            Write-Host "`n`e[95m<< Successfully set up the following WSL distros >>`e[0m"
            $successDistros.ForEach({ Write-Host " - $_" })
        }
    }
    if ($failDistros.Count) {
        if ($failDistros.Count -eq 1) {
            Write-Host "`n`e[91m<< Failed to set up the `e[4m$failDistros`e[24m WSL distro >>`e[0m`n"
        } else {
            Write-Host "`n`e[91m<< Failed to set up the following WSL distros >>`e[0m"
            $failDistros.ForEach({ Write-Host " - $_" })
        }
    }
}

clean {
    $version = Get-WslInstallVersion
    foreach ($name in $script:distroRecords.Keys) {
        Write-WslInstallRecord `
            -Distro $name `
            -Record $script:distroRecords[$name] `
            -Version $version `
            -IsSuccess ($name -in $script:successDistros)
    }
    Pop-Location
}
