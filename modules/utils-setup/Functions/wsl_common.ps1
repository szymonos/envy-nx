<#
.SYNOPSIS
Invoke wsl.exe with stdin/stdout/stderr inherited from the parent process.
.DESCRIPTION
A direct `wsl.exe ... | Out-Default` inside a value-returning function has
two production problems:

1. wsl.exe native commands (--install, --update, --unregister) emit UTF-16
   LE. PowerShell decodes the pipe with its console encoding (usually UTF-8
   or the system codepage) and renders garbled output ("D o w n l o a d i n g :
   U b u n t u").
2. TTY-aware programs running inside wsl.exe (nix's progress bar, apt-get
   progress, etc.) see a pipe instead of a terminal and fall back to plain
   text logs ("copying path '/nix/store/...' from 'https://cache.nixos.org'..."
   line per dependency, instead of a single live bar).

This wrapper bypasses the PowerShell pipeline entirely via Process.Start
with `UseShellExecute = $false` and the default (inherited) std{in,out,err}
handles. wsl.exe writes directly to the terminal - no PS decoding, no pipe.
Output never enters the calling function's pipeline output, so callers
returning a value (`Install-WslScopes`, `Invoke-WslDistroCheck`, etc.) can't
have their return value polluted.

`$LASTEXITCODE` is set globally to the wsl.exe exit code after WaitForExit,
so callers detect failure with `if ($LASTEXITCODE -ne 0) { ... }`.

`WorkingDirectory` is explicitly set to `$PWD.Path` because PowerShell and
.NET maintain separate CWD state. Without this, Process.Start inherits the
.NET CWD (set at PS startup and not updated by Set-Location), so relative
paths like `nix/setup.sh` resolve against the wrong directory.

Off-Windows (Pester running on Linux/macOS): falls back to the PowerShell
call operator so `Mock wsl.exe { ... }` can intercept. The keying off
`$IsWindows` is intentional - Process.Start with wsl.exe only makes sense
on Windows, and parallel test runners (pester_parallel.ps1) make
env-var-based gating racy across runspaces.
.PARAMETER Arguments
Arguments forwarded to wsl.exe.
.EXAMPLE
Invoke-WslExe --install --distribution Ubuntu --web-download
if ($LASTEXITCODE -ne 0) { throw 'install failed' }
#>
function Invoke-WslExe {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    if (-not $IsWindows) {
        # test fallback - let Pester Mocks intercept via PS call lookup.
        # Reset $LASTEXITCODE so a leftover non-zero value from a prior real
        # external command doesn't make $LASTEXITCODE-based failure checks
        # (e.g. Install-WslScopes after the nix/setup.sh call) spuriously
        # log "<command> failed" during integration tests where the Mock
        # returns successfully but doesn't touch the exit code. Mocks that
        # want to simulate failure can set $global:LASTEXITCODE themselves.
        $global:LASTEXITCODE = 0
        wsl.exe @Arguments | Out-Default
        return
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new('wsl.exe')
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $PWD.Path
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    $global:LASTEXITCODE = $proc.ExitCode
}

<#
.DESCRIPTION
Get list of WSL distros

.PARAMETER Online
Get list of available distros online.
.PARAMETER FromRegistry
Get list of installed distros from registry
#>
function Get-WslDistro {
    [CmdletBinding(DefaultParameterSetName = 'FromCommand')]
    param (
        [Parameter(ParameterSetName = 'Online')]
        [switch]$Online,

        [Parameter(ParameterSetName = 'FromRegistry')]
        [switch]$FromRegistry
    )

    begin {
        # check if the script is running on Windows
        if (-not $IsWindows) {
            Write-Warning 'Run the function on Windows!'
            break
        }

        if ($FromRegistry) {
            # specify list of properties to get from Windows registry lxss
            $prop = [System.Collections.Generic.List[PSObject]]::new(
                [PSObject[]]@(
                    @{ Name = 'Name'; Expression = { $_.DistributionName } }
                    'DefaultUid'
                    @{ Name = 'Version'; Expression = { $_.Flags -lt 8 ? 1 : 2 } }
                    'Flags'
                    @{ Name = 'BasePath'; Expression = { $_.BasePath -replace '^\\\\\?\\' } }
                    'PSPath'
                )
            )
            # determine the default distribution
            $defDistroName = try {
                $defDistroID = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -Name 'DefaultDistribution' -ErrorAction Stop
                Get-ItemPropertyValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\$defDistroID" -Name 'DistributionName' -ErrorAction Stop
            } catch {
                $null
            }
            $prop.Add(@{ Name = 'Default'; Expression = { $_.DistributionName -eq $defDistroName } })
        } else {
            $distros = [Collections.Generic.List[PSCustomObject]]::new()
            $outputEncoding = [Console]::OutputEncoding
        }
    }

    process {
        if ($FromRegistry) {
            # get list of WSL distros from Windows Registry
            $distros = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss -ErrorAction SilentlyContinue `
            | ForEach-Object { $_ | Get-ItemProperty } `
            | Where-Object { $_.DistributionName -notmatch '^docker-desktop' } `
            | Select-Object $prop
        } else {
            if ($Online) {
                # get list of online WSL distros in the loop
                $retry = 0
                $distros = [Collections.Generic.List[PSCustomObject]]::new()
                do {
                    try {
                        $distInfo = Invoke-RestMethod 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
                        $modernDistros = ($distInfo.ModernDistributions | Get-Member -MemberType NoteProperty).Name
                        foreach ($distroFamily in $modernDistros) {
                            foreach ($distro in $distInfo.ModernDistributions.$distroFamily) {
                                $distros.Add([PSCustomObject]@{
                                        Name         = $distro.Name
                                        FriendlyName = $distro.FriendlyName
                                    })
                            }
                        }
                        foreach ($distro in $distInfo.Distributions) {
                            $distros.Add([PSCustomObject]@{
                                    Name         = $distro.Name
                                    FriendlyName = $distro.FriendlyName
                                })
                        }
                        $distros = $distros | Sort-Object -Property Name -Unique
                    } catch {
                        Out-Null
                    }
                    $retry++
                    if ($retry -gt 3) {
                        Write-Error -Message 'Cannot get list of valid distributions.' -Category ConnectionError
                        break
                    }
                } until ($distros.Count -gt 0)
            } else {
                # change console encoding to utf-16
                [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
                # get list of installed locally WSL distros
                [string[]]$result = wsl.exe --list --verbose
                # get distros header
                [string]$head = $result | Select-String 'NAME\s+STATE\s+VERSION' -CaseSensitive | Select-Object -ExpandProperty Line
                # calculate header line index
                if ($head) {
                    $idx = $result.IndexOf($head)
                    $dataIdx = if ($idx -ge 0) {
                        $idx + 1
                    } else {
                        $result.Count - 1
                    }
                    # calculate header columns indexes
                    $nameIdx = $head.IndexOf('NAME')
                    $stateIdx = $head.IndexOf('STATE')
                    $versionIdx = $head.IndexOf('VERSION')
                    # add results to the distros list
                    for ($i = $dataIdx; $i -lt $result.Count; $i++) {
                        $distro = [PSCustomObject]@{
                            Default = $result[$i].Substring(0, $nameIdx).TrimEnd() -eq '*'
                            Name    = $result[$i].Substring($nameIdx, $stateIdx - $nameIdx).TrimEnd()
                            State   = $result[$i].Substring($stateIdx, $versionIdx - $stateIdx).TrimEnd()
                            Version = $result[$i].Substring($versionIdx, $result[$i].Length - $versionIdx).TrimEnd()
                        }
                        $distros.Add($distro)
                    }
                }
            }
        }
    }

    end {
        return $distros
    }

    clean {
        [Console]::OutputEncoding = $outputEncoding
    }
}

<#
.DESCRIPTION
Sets wsl.conf in specified WSL distro from provided ordered dictionary.
.LINK
https://learn.microsoft.com/en-us/windows/wsl/wsl-config#wslconf

.PARAMETER Distro
Name of the WSL distro to set wsl.conf.
.PARAMETER ConfDict
Input dictionary consisting configuration to be saved into wsl.conf.
.PARAMETER ShowConf
Print current wsl.conf after setting the configuration.
#>
function Set-WslConf {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Distro,

        [System.Collections.IDictionary]$ConfDict,

        [switch]$ShowConf
    )

    begin {
        Write-Verbose 'setting wsl.conf'
        $wslConf = wsl.exe -d $Distro --exec cat /etc/wsl.conf 2>$null | ConvertFrom-Cfg
        if (-not ($? -or $ConfDict)) {
            break
        }
    }

    process {
        if ($wslConf) {
            foreach ($key in $ConfDict.Keys) {
                if ($wslConf.$key) {
                    foreach ($option in $ConfDict.$key.Keys) {
                        $wslConf.$key.$option = $ConfDict.$key.$option
                    }
                } else {
                    $wslConf.$key = $ConfDict.$key
                }
            }
        } else {
            $wslConf = $ConfDict
        }
        $wslConfStr = ConvertTo-Cfg -OrderedDict $wslConf -LineFeed
        if ($wslConfStr) {
            # save wsl.conf file
            $cmd = "rm -f /etc/wsl.conf || true && echo '$wslConfStr' >/etc/wsl.conf"
            wsl.exe -d $Distro --user root --exec sh -c $cmd
        }
    }

    end {
        if ($ShowConf) {
            Write-Host "wsl.conf`n" -ForegroundColor Magenta
            wsl.exe -d $Distro --exec cat /etc/wsl.conf | Write-Host
        } else {
            Write-Verbose 'Saved configuration in /etc/wsl.conf.'
        }
    }
}
