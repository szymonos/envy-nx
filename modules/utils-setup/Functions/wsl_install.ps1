using namespace System.Management.Automation.Host

<#
.SYNOPSIS
Pull ~/.config/gh/hosts.yml from the default WSL distro for replication
into the target distro.
.DESCRIPTION
Returns the lines of hosts.yml as a string array, or @() when the default
distro is the same as the target (nothing to pull) or the file is missing.
.PARAMETER TargetDistro
Distro that will receive the config. When it matches the default distro,
the function is a no-op and returns @().
.PARAMETER InstalledDistros
Output of Get-WslDistro filtered to non-docker-desktop entries.
#>
function Get-WslGhConfigFromDefault {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TargetDistro,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InstalledDistros
    )

    $defaultDistro = $InstalledDistros.Where({ $_.Default }).Name
    if (-not $defaultDistro -or $defaultDistro -eq $TargetDistro) {
        return @()
    }

    Show-LogContext 'getting GitHub authentication config from the default distro'
    $hostsPath = '$HOME/.config/gh/hosts.yml'
    [string[]]$ghConfig = wsl.exe --distribution $defaultDistro -- cat $hostsPath 2>$null
    return $ghConfig ?? @()
}

<#
.SYNOPSIS
Prompt the user to choose how to handle a WSL1 distro.
.DESCRIPTION
Wraps $Host.UI.PromptForChoice - the only non-testable interactive surface
in the wsl_setup phase functions. Returns the choice index:
0 = replace, 1 = select another, 2 = continue with WSL1.
.PARAMETER Distro
Distro name shown in the prompt text.
#>
function Get-WslMigrationChoice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro
    )

    $caption = 'It is strongly recommended to use WSL2.'
    $message = 'Select your choice:'
    $choices = @(
        @{ choice = '&Replace the current distro'; desc = "Delete current '$Distro' distro and install it as WSL2." }
        @{ choice = '&Select another distro to install'; desc = 'Select from other online distros to install as WSL2.' }
        @{ choice = '&Continue setup of the current distro'; desc = "Continue setup of the current WSL1 '$Distro' distro." }
    )
    [ChoiceDescription[]]$options = $choices.ForEach({
            [ChoiceDescription]::new($_.choice, $_.desc)
        })
    return $Host.UI.PromptForChoice($caption, $message, $options, -1)
}

<#
.SYNOPSIS
Install the WSL service when wsl.exe reports it's missing.
.DESCRIPTION
Two paths: when run as admin, invokes wsl.exe directly with the supplied
install args; otherwise spawns an elevated pwsh subprocess. Either way,
prints "restart required" instructions and throws 'restart required' so
the orchestrator can catch and exit 0.
.PARAMETER InstallArgs
Pre-built --install argument list to forward to wsl.exe after restart.
#>
function Install-WslService {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$InstallArgs
    )

    if (Test-IsAdmin) {
        Invoke-WslExe @InstallArgs
        if ($LASTEXITCODE -ne 0) {
            Show-LogContext 'WSL service installation failed.' -Level ERROR
            throw 'WSL service install failed'
        }
    } else {
        Show-LogContext "`nInstalling WSL service. Wait for the process to finish and restart the system!`n" -Level WARNING
        $cmnd = "-NoProfile -Command `"wsl.exe $($InstallArgs -join ' ')`""
        Start-Process -FilePath pwsh.exe -ArgumentList $cmnd -Verb RunAs
        if (-not $?) {
            Show-LogContext 'WSL service installation failed.' -Level ERROR
            throw 'WSL service install failed'
        }
    }
    Show-LogContext 'WSL service installation finished.'
    Show-LogContext "`nRestart the system and run the script again to install the specified WSL distro!`n" -Level WARNING
    # signal the orchestrator to exit 0 via FullyQualifiedErrorId, NOT message
    # text - keeps the user-facing message editable without flipping behavior
    $err = [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new('WSL service installed - restart required to continue'),
        'WslRestartRequired',
        [System.Management.Automation.ErrorCategory]::OperationStopped,
        $null
    )
    throw $err
}

<#
.SYNOPSIS
Install a WSL distro if it isn't already present locally.
.DESCRIPTION
Returns the resolved distro name (same as input). Throws on unknown
distro / install failure / WSL-service-missing (the WSL-service-missing
path delegates to Install-WslService, which throws 'restart required'
for the orchestrator to translate into exit 0).
.PARAMETER Distro
Requested distro name.
.PARAMETER InstalledDistros
Output of Get-WslDistro filtered to non-docker-desktop entries.
.PARAMETER WebDownload
True to forward --web-download to wsl.exe --install.
#>
function Install-WslDistroIfMissing {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InstalledDistros,

        [bool]$WebDownload
    )

    $installArgs = [System.Collections.Generic.List[string]]::new(
        [string[]]@('--install', '--distribution', $Distro)
    )
    if ($WebDownload) {
        $installArgs.Add('--web-download')
    }

    if ($Distro -in $InstalledDistros.Name) {
        return $Distro
    }

    # not installed locally - try online lookup with retry
    $onlineDistros = $null
    for ($i = 0; $i -lt 5; $i++) {
        $onlineDistros = Get-WslDistro -Online
        if ($onlineDistros) { break }
    }

    if ($Distro -notin $onlineDistros.Name) {
        Show-LogContext "The specified distro does not exist ($Distro)." -Level WARNING
        throw "unknown distro '$Distro'"
    }

    Show-LogContext "specified distribution not found ($Distro), proceeding to install"
    try {
        Get-Service -Name WSLService | Out-Null
        Invoke-WslExe @installArgs --no-launch
        if ($LASTEXITCODE -eq 0 -and $Distro -notin (Get-WslDistro -FromRegistry).Name) {
            Write-Host "`nSetting up user profile in WSL distro. Type 'exit' when finished to proceed with WSL setup!`n" -ForegroundColor Yellow
            Invoke-WslExe @installArgs
        }
        if ($LASTEXITCODE -ne 0) {
            Show-LogContext "`"$Distro`" distro installation failed." -Level ERROR
            throw "distro install failed for '$Distro'"
        }
    } catch [Microsoft.PowerShell.Commands.ServiceCommandException], [System.InvalidOperationException] {
        # WSLService missing entirely - delegate to service installer (it throws 'restart required')
        Install-WslService -InstallArgs $installArgs
    }

    return $Distro
}

<#
.SYNOPSIS
Migrate a WSL1 distro to WSL2 - interactive choice plus the act.
.DESCRIPTION
Returns the resolved distro name. Choice 0 (replace) keeps the input
name and reinstalls; choice 1 (select another) returns whatever the
user picked from the online list; choice 2 (continue with WSL1)
returns the input unchanged.
.PARAMETER Distro
Current WSL1 distro.
.PARAMETER WebDownload
Forwarded to wsl.exe --install for the new distro.
#>
function Invoke-WslDistroMigration {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [bool]$WebDownload
    )

    Show-LogContext "The distribution `"$Distro`" is currently using WSL1!" -Level WARNING
    $choice = Get-WslMigrationChoice -Distro $Distro
    if ($choice -eq 2) {
        return $Distro
    }

    # ensure the default WSL version is 2 before reinstalling
    $defaultVersion = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss').DefaultVersion
    if ($defaultVersion -ne 2) {
        Invoke-WslExe --set-default-version 2
    }

    switch ($choice) {
        0 {
            Show-LogContext 'unregistering current distro'
            Invoke-WslExe --unregister $Distro
            break
        }
        1 {
            $online = $null
            for ($i = 0; $i -lt 5; $i++) {
                $online = Get-WslDistro -Online
                if ($online) { break }
            }
            $candidates = $online.Name.Where({
                    $_ -ne $Distro -and $_ -match 'ubuntu|debian'
                })
            $Distro = Get-ArrayIndexMenu -Array $candidates -Message 'Choose distro to install' -Value
            Show-LogContext "installing selected distro ($Distro)"
            break
        }
    }

    $installArgs = [System.Collections.Generic.List[string]]::new(
        [string[]]@('--install', '--distribution', $Distro)
    )
    if ($WebDownload) {
        $installArgs.Add('--web-download')
    }
    Invoke-WslExe @installArgs --no-launch

    return $Distro
}

<#
.SYNOPSIS
Read the Windows system theme preference for WSLg apps.
.DESCRIPTION
Returns 'light' if HKCU SystemUsesLightTheme = 1, 'dark' otherwise (also
when the registry value is missing - matches the pre-refactor ternary
behavior).
#>
function Resolve-WslGtkThemePreference {
    [CmdletBinding()]
    param ()

    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $usesLight = Get-ItemPropertyValue `
        -Path $regPath `
        -Name 'SystemUsesLightTheme' `
        -ErrorAction SilentlyContinue
    return $usesLight ? 'light' : 'dark'
}
