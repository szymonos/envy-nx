#Requires -Version 7.4
<#
.SYNOPSIS
Subprocess harness for wsl/wsl_setup.ps1 tests that need to observe
process-terminating behavior (e.g. `exit 1` on DNS failure).

.DESCRIPTION
Pester mocks live inside the parent test process; once wsl_setup.ps1
calls `exit`, the parent process dies and the test runner with it.
Hosting the mock-and-invoke step in this helper script lets the test
launch a child pwsh, observe `$LASTEXITCODE`, and continue.

The script is intended to be dot-sourced from `pwsh -NoProfile -Command`
(not run via `pwsh -File`). Dot-sourcing under `-Command` puts the
function definitions in the child's global scope so they shadow the
imported module functions for wsl_setup.ps1's call sites.

Each `-DnsResult` / `-SslResult` parameter is one of 'true' / 'false',
mirroring the strings emitted by .assets/check/check_dns.sh /
check_ssl.sh on a real WSL run.

.PARAMETER RepoRoot
Absolute path to the envy-nx checkout under test.

.PARAMETER DnsResult
Stubbed return value for check_dns.sh (default: 'true').

.PARAMETER SslResult
Stubbed return value for check_ssl.sh (default: 'true').

.PARAMETER Distro
Name of the WSL distro the orchestrator iterates (default: 'Ubuntu').

.PARAMETER Scope
Scopes the orchestrator should attempt to install (default: 'shell').

.EXAMPLE
pwsh -NoProfile -Command ". ./Invoke-WslSetupScenario.ps1 -RepoRoot /repo -DnsResult false"
# Returns $LASTEXITCODE != 0 because the DNS check failed.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [string]$DnsResult = 'true',
    [string]$SslResult = 'true',
    [string]$Distro = 'Ubuntu',
    [string[]]$Scope = @('shell')
)

$env:WSL_SETUP_TESTING = '1'
$env:HOMEDRIVE = 'C:'
$env:HOMEPATH = '\Users\testuser'

Set-Location $RepoRoot
Import-Module './modules/do-common' -Force
Import-Module './modules/utils-install' -Force
Import-Module './modules/utils-setup' -Force

# Build the same default check_distro JSON the parent tests use. Inlined
# so the helper has no dependency on Pester / BeforeAll fixtures.
$checkDistroDefaults = @{
    user = 'testuser'; uid = 1000; def_uid = 1000
    az = $false; bun = $false; conda = $false; gcloud = $false
    git_user = $true; git_email = $true; gtkd = $false
    k8s_base = $false; k8s_dev = $false; k8s_ext = $false
    nix = $false; oh_my_posh = $false
    python = $false; pwsh = $false; shell = $false
    ssh_key = $true; systemd = $true; terraform = $false
    wsl_boot = $true; wslg = $false; zsh = $false
}
$checkDistroJson = $checkDistroDefaults | ConvertTo-Json -Compress

# Capture the DNS / SSL / hosts.yml / check_distro.sh args inside the
# wsl.exe stub so the orchestrator's pre-flight gate sees the configured
# verdict instead of attempting a real WSL invocation.
function wsl.exe {
    $argStr = $args -join ' '
    if ($argStr -match 'check_distro\.sh') { return $checkDistroJson }
    if ($argStr -match 'check_dns\.sh') { return $DnsResult }
    if ($argStr -match 'check_ssl\.sh') { return $SslResult }
    if ($argStr -match 'hosts\.yml') { return 'github.com' }
    return ''
}

function Get-WslDistro {
    [CmdletBinding()] param([switch]$FromRegistry, [switch]$Online)
    if ($FromRegistry) {
        [pscustomobject]@{
            Name = $Distro; DefaultUid = 1000; Version = 2; Flags = 15
            BasePath = 'C:\fake'; Default = $true
        }
    } else {
        [pscustomobject]@{
            Default = $true; Name = $Distro; State = 'Running'; Version = 2
        }
    }
}
function Set-WslConf { }
function Update-GitRepository { return 1 }
function Invoke-GhRepoClone { return 2 }
function Test-IsAdmin { return $false }

& './wsl/wsl_setup.ps1' -Distro $Distro -Scope $Scope -SkipRepoUpdate *> $null
