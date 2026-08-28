#!/usr/bin/env pwsh
<#
.SYNOPSIS
Setting up PowerShell for the current user.

.PARAMETER UpdateModules
Run update_psresources.ps1 to update all installed modules.

.EXAMPLE
.assets/setup/setup_profile_user.ps1
# :update modules
.assets/setup/setup_profile_user.ps1 -UpdateModules
#>
param (
    [switch]$UpdateModules
)
$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'Ignore'

# Dot-sourcing runs under SilentlyContinue, so a missing or unparsable library
# leaves the helpers undefined without raising - probe for one before using them.
. (Join-Path $PSScriptRoot 'setup_az_login.ps1')
$azLoginReady = [bool](Get-Command Set-AzPowerShellWamConfig -ErrorAction Ignore)
if (-not $azLoginReady) {
    Write-Host 'WARNING: setup_az_login.ps1 did not load - skipping Az/MSAL browser auth setup.' -ForegroundColor Yellow
}

if ($IsLinux -and $azLoginReady) {
    $azConfigPath = Join-Path $HOME '.Azure/PSConfig.json'
    try {
        if (Set-AzPowerShellWamConfig -Path $azConfigPath -ErrorAction Stop) {
            Write-Host 'disabling WAM login for Az PowerShell...'
        }
    } catch {
        Write-Host "WARNING: unable to configure Az PowerShell browser login: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# *PowerShell profile
# create user profile powershell config directory
$profileDir = [IO.Path]::GetDirectoryName($PROFILE)
if (-not (Test-Path $profileDir -PathType Container)) {
    New-Item $profileDir -ItemType Directory | Out-Null
}
# set up Microsoft.PowerShell.PSResourceGet and update installed modules
if (Get-Module -Name Microsoft.PowerShell.PSResourceGet -ListAvailable) {
    if (-not (Get-PSResourceRepository -Name PSGallery).Trusted) {
        Write-Host 'setting PSGallery trusted...'
        Set-PSResourceRepository -Name PSGallery -Trusted

        # update help, assuming this is the initial setup
        if (Test-Connection 'aka.ms' -TcpPort 443 -TimeoutSeconds 1) {
            Write-Host 'updating help...'
            Update-Help -UICulture en-US
        }
    }
    # update existing modules
    if ($PSBoundParameters.UpdateModules -and (Test-Path .assets/setup/update_psresources.ps1 -PathType Leaf)) {
        .assets/setup/update_psresources.ps1
    }
}
# install PSReadLine
for ($i = 0; ((Get-Module PSReadLine -ListAvailable).Count -eq 1) -and $i -lt 5; $i++) {
    Write-Host 'installing PSReadLine...'
    Install-PSResource -Name PSReadLine
}
# Install posh-git.
# Gated on git being available (posh-git is a no-op without git) and on posh-git not already being installed.
# `Install-PSResource` defaults to CurrentUser scope when -Scope is omitted.
# Loop up to 5x for transient PSGallery hiccups, same shape as PSReadLine above.
for ($i = 0; (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) -and -not (Get-Module posh-git -ListAvailable) -and $i -lt 5; $i++) {
    Write-Host 'installing posh-git...'
    Install-PSResource -Name posh-git
}

#region wslview shim for MSAL browser auth
# Az/Graph PowerShell (Connect-AzAccount / Connect-MgGraph) start the browser
# auth-code flow by exec'ing the first opener found on PATH from a list hardcoded
# in MSAL.NET (NetCorePlatformProxy.cs GetOpenTool): default order
# xdg-open, gnome-open, kfmclient, microsoft-edge, wslview. `wslview` is just a PATH
# binary name to MSAL - NOT a wslu dependency (wslu was archived 2025-03), so our
# shim is unaffected by that. On headless Linux (WSL, SSH VMs) none exist, so MSAL
# falls back to device code flow - now blocked by the Entra Conditional Access
# policy. Filling the last-resort wslview slot with a shim makes MSAL print the
# sign-in URL (like `az login`) so it can be CTRL+Clicked, keeping the localhost
# listener open to catch the redirect - no device code. Skip on Windows (WAM) and
# desktop Linux (a real opener already works), and never shadow a real wslview.
# Resolve the shim source relative to this script - setup_common.sh does not cd to
# the repo root around this call, so a bare relative path would not resolve.
$shimSource = Join-Path $PSScriptRoot '../config/bin/wslview'
$wslviewPath = "$HOME/.local/bin/wslview"
# a real opener earlier in MSAL's list means wslview is never reached - skip.
$hasRealOpener = @('xdg-open', 'gnome-open', 'kfmclient', 'microsoft-edge').Where(
    { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue }, 'First'
)
# a real wslview elsewhere on PATH (not our shim) must not be shadowed
$realWslview = Get-Command wslview -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object Source -NE $wslviewPath
# "headless" = Linux with no MSAL browser opener of its own - the only case we
# install the shim. WAM is disabled separately through PSConfig.json above.
$headlessNoOpener = $IsLinux -and -not $hasRealOpener -and -not $realWslview
if ($headlessNoOpener -and (Test-Path $shimSource -PathType Leaf)) {
    # (re)install the shim only when missing or changed
    $installed = (Test-Path $wslviewPath -PathType Leaf) ? [System.IO.File]::ReadAllText($wslviewPath) : ''
    if ($installed -ne [System.IO.File]::ReadAllText($shimSource)) {
        Write-Host 'installing wslview shim for MSAL browser auth...'
        $binDir = [IO.Path]::GetDirectoryName($wslviewPath)
        if (-not (Test-Path $binDir -PathType Container)) {
            New-Item $binDir -ItemType Directory | Out-Null
        }
        & install -m 0755 $shimSource $wslviewPath
    }
}
$hasWslview = [bool]$realWslview -or (Test-Path $wslviewPath -PathType Leaf)
$needsMsalDisplay = $azLoginReady -and (Test-MsalBrowserAuthNeedsDisplay `
        -IsLinuxPlatform $IsLinux `
        -HasEarlierOpener ([bool]$hasRealOpener) `
        -HasWslview $hasWslview)
#endregion

#region $PROFILE.CurrentUserCurrentHost
# load existing profile
$profileContent = [System.Collections.Generic.List[string]]::new()
if (Test-Path $PROFILE.CurrentUserCurrentHost -PathType Leaf) {
    $profileContent.AddRange([System.IO.File]::ReadAllLines($PROFILE.CurrentUserCurrentHost))
}
# track if profile is modified
$isProfileModified = $false

# install kubectl autocompletion
if (Test-Path /usr/bin/kubectl -PathType Leaf) {
    if (-not ($profileContent | Select-String '__kubectlCompleterBlock' -SimpleMatch -Quiet)) {
        Write-Host 'adding kubectl auto-completion...'
        # build completer text
        $profileContent.AddRange(
            [string[]]@(
                "`n#region kubectl completer"
                (/usr/bin/kubectl completion powershell) -join "`n"
                "`n# setup autocompletion for the 'k' alias"
                'Set-Alias -Name k -Value kubectl'
                "Register-ArgumentCompleter -CommandName 'k' -ScriptBlock `${__kubectlCompleterBlock}"
                "`n# setup autocompletion for the 'kubecolor' binary"
                'if (Test-Path /usr/bin/kubecolor -PathType Leaf) {'
                '    Set-Alias -Name kubectl -Value kubecolor'
                "    Register-ArgumentCompleter -CommandName 'kubecolor' -ScriptBlock `${__kubectlCompleterBlock}"
                '}'
                '#endregion'
            )
        )
        $isProfileModified = $true
    }
}

# save profile if modified
if ($isProfileModified) {
    [System.IO.File]::WriteAllText(
        $PROFILE.CurrentUserCurrentHost,
        "$(($profileContent -join "`n").Trim())`n"
    )
}
#endregion

#region $PROFILE.CurrentUserAllHosts
# load existing profile
$profileContent = [System.Collections.Generic.List[string]]::new()
if (Test-Path $PROFILE.CurrentUserAllHosts -PathType Leaf) {
    $profileContent.AddRange([System.IO.File]::ReadAllLines($PROFILE.CurrentUserAllHosts))
}
# track if profile is modified
$isProfileModified = $false

# MSAL requires DISPLAY to be non-empty before it probes browser openers. This
# region lets headless PowerShell reach either a genuine wslview or our shim.
if ($azLoginReady) {
    try {
        if (Set-MsalBrowserAuthProfileRegion -Content $profileContent -Enabled $needsMsalDisplay -ErrorAction Stop) {
            Write-Host "$($needsMsalDisplay ? 'adding' : 'removing') MSAL browser auth profile configuration..."
            $isProfileModified = $true
        }
    } catch {
        Write-Host "WARNING: unable to configure the MSAL browser auth profile region: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# remove legacy devenv region (replaced by nx version)
$devenvStart = $profileContent.FindIndex({ param($l) $l -match '^\s*#region devenv' })
if ($devenvStart -ge 0) {
    $devenvEnd = $profileContent.FindIndex($devenvStart, { param($l) $l -match '^\s*#endregion' })
    if ($devenvEnd -ge 0) {
        $profileContent.RemoveRange($devenvStart, $devenvEnd - $devenvStart + 1)
        while ($devenvStart -gt 0 -and [string]::IsNullOrWhiteSpace($profileContent[$devenvStart - 1])) {
            $profileContent.RemoveAt($devenvStart - 1)
            $devenvStart--
        }
        $isProfileModified = $true
    }
}

# setup conda initialization
$condaCli = 'miniforge3/bin/conda'
if (Test-Path "$HOME/$condaCli" -PathType Leaf) {
    if (-not ($profileContent | Select-String $condaCli -SimpleMatch -Quiet)) {
        Write-Verbose 'adding miniforge initialization...'
        $profileContent.AddRange(
            [string[]]@(
                "`n#region conda"
                '# initialization'
                "try { (& `"`$HOME/$condaCli`" 'shell.powershell' 'hook') | Out-String | Invoke-Expression | Out-Null } catch { Out-Null }"
                '#endregion'
            )
        )
        $isProfileModified = $true
    }
    # hide conda env in shell prompt if oh-my-posh is installed
    if (Get-Command oh-my-posh -CommandType Application -ErrorAction SilentlyContinue) {
        $changeps1 = & "$HOME/$condaCli" config --show | Select-String 'changeps1: False' -SimpleMatch -Quiet
        if (-not $changeps1) {
            & "$HOME/$condaCli" config --set changeps1 false
        }
    }
}

# set up uv
$uvCli = '.local/bin/uv'
if (Test-Path "$HOME/$uvCli" -PathType Leaf) {
    if (-not ($profileContent | Select-String 'UV_SYSTEM_CERTS' -SimpleMatch -Quiet)) {
        Write-Verbose 'adding uv autocompletion...'
        $profileContent.AddRange(
            [string[]]@(
                "`n#region uv"
                '# use system certificates'
                '[System.Environment]::SetEnvironmentVariable("UV_SYSTEM_CERTS", $true)'
            )
        )
        $isProfileModified = $true

        $completionCmd = 'generate-shell-completion powershell'
        if (-not ($profileContent | Select-String $completionCmd -SimpleMatch -Quiet)) {
            $profileContent.AddRange(
                [string[]]@(
                    '# autocompletion'
                    "try { (& `"`$HOME/$uvCli`" $completionCmd) | Out-String | Invoke-Expression | Out-Null } catch { Out-Null }"
                    '#endregion'
                )
            )
            $isProfileModified = $true
        } else {
            $profileContent.Add('#endregion')
        }
    }
}

# set up make completer
$completerFunction = 'Register-MakeCompleter'
if (Get-Command $completerFunction -Module 'do-unix' -CommandType Function -ErrorAction SilentlyContinue) {
    if (-not ($profileContent | Select-String $completerFunction -SimpleMatch -Quiet)) {
        Write-Host 'adding make auto-completion...'
        $profileContent.AddRange(
            [string[]]@(
                "`n#region make completer"
                'Set-Alias -Name m -Value make'
                $completerFunction
                '#endregion'
            )
        )
        $isProfileModified = $true
    }
}

# set up opencode
$openCodePath = '.opencode/bin'
if (Test-Path "$HOME/$openCodePath/opencode" -PathType Leaf) {
    if (-not ($profileContent | Select-String $openCodePath -SimpleMatch -Quiet)) {
        Write-Verbose 'adding opencode path...'
        $profileContent.AddRange(
            [string[]]@(
                "`n#region opencode"
                "if ((Test-Path `"`$HOME/$openCodePath/opencode`" -PathType Leaf) -and `"`$HOME/$openCodePath`" -notin `$env:PATH.Split([IO.Path]::PathSeparator)) {"
                "    [Environment]::SetEnvironmentVariable('PATH', [string]::Join([IO.Path]::PathSeparator, `"`$HOME/$openCodePath`", `$env:PATH))"
                '}'
                '#endregion'
            )
        )
        $isProfileModified = $true
    }
}

# set up custom CA certs environment variables for MITM proxy certificates
$certCustom = [IO.Path]::Combine($HOME, '.config', 'certs', 'ca-custom.crt')
$certBundle = [IO.Path]::Combine($HOME, '.config', 'certs', 'ca-bundle.crt')
if (Test-Path $certCustom -PathType Leaf) {
    if (-not ($profileContent | Select-String 'NODE_EXTRA_CA_CERTS' -SimpleMatch -Quiet)) {
        Write-Verbose 'adding NODE_EXTRA_CA_CERTS env var...'
        $profileContent.AddRange([string[]]@(
                "`n#region certs"
                "if (Test-Path `"$certCustom`" -PathType Leaf) {"
                "    [Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', `"$certCustom`")"
                '}'
                '#endregion'
            )
        )
        $isProfileModified = $true
    }
}
if (Test-Path $certBundle -PathType Leaf) {
    if (-not ($profileContent | Select-String 'REQUESTS_CA_BUNDLE' -SimpleMatch -Quiet)) {
        Write-Verbose 'adding REQUESTS_CA_BUNDLE and SSL_CERT_FILE env vars...'
        $profileContent.AddRange([string[]]@(
                "`n#region ca-bundle"
                "if (Test-Path `"$certBundle`" -PathType Leaf) {"
                "    [Environment]::SetEnvironmentVariable('REQUESTS_CA_BUNDLE', `"$certBundle`")"
                "    [Environment]::SetEnvironmentVariable('SSL_CERT_FILE', `"$certBundle`")"
                '}'
                '#endregion'
            )
        )
        $isProfileModified = $true
    }
    if (-not ($profileContent | Select-String 'CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE' -SimpleMatch -Quiet)) {
        if ((Test-Path /usr/bin/gcloud -PathType Leaf) -or (Test-Path "$HOME/.nix-profile/bin/gcloud" -PathType Leaf) -or (Test-Path "$HOME/google-cloud-sdk/bin/gcloud" -PathType Leaf)) {
            Write-Verbose 'adding CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE env var...'
            $profileContent.AddRange([string[]]@(
                    "`n#region gcloud-certs"
                    "if (Test-Path `"$certBundle`" -PathType Leaf) {"
                    "    [Environment]::SetEnvironmentVariable('CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE', `"$certBundle`")"
                    '}'
                    '#endregion'
                )
            )
            $isProfileModified = $true
        }
    }
}

# save profile if modified
if ($isProfileModified) {
    [System.IO.File]::WriteAllText(
        $PROFILE.CurrentUserAllHosts,
        "$(($profileContent -join "`n").Trim())`n"
    )
}
#endregion
