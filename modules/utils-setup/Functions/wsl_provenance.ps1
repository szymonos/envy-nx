<#
.SYNOPSIS
Resolve install version metadata from the current git checkout on the
Windows host.
.DESCRIPTION
Returns Version (`git describe --tags --dirty`, falling back to short SHA
on a detached HEAD with no tags reachable), SourceRef (full HEAD SHA),
and Source ('git' if Version resolved via describe/rev-parse, 'tarball'
otherwise). Run once on the Windows host before iterating distros so the
same metadata lands in every distro's install.json.
.NOTES
Resolution happens on the Windows side - bypasses git safe.directory
warnings that fire when invoking git inside the distro on a clone owned
by the Windows user.
#>
function Get-WslInstallVersion {
    [CmdletBinding()]
    param ()

    $version = git describe --tags --dirty 2>$null
    if (-not $version) {
        $version = git rev-parse --short HEAD 2>$null
    }
    $sourceRef = git rev-parse HEAD 2>$null

    return [pscustomobject]@{
        Version   = $version
        SourceRef = $sourceRef
        Source    = $version ? 'git' : 'tarball'
    }
}

<#
.SYNOPSIS
Write an install provenance record into a WSL distro by sourcing
.assets/lib/install_record.sh and calling write_install_record.
.DESCRIPTION
Best-effort: swallows wsl.exe errors so a single broken / unreachable
distro doesn't fail the whole clean block.
.PARAMETER Distro
Name of the WSL distro.
.PARAMETER Record
Per-distro hashtable: phase, scopes (string[]), mode, error.
.PARAMETER Version
Output of Get-WslInstallVersion (Version/SourceRef/Source fields).
.PARAMETER IsSuccess
True if the distro completed setup without falling into $failDistros.
#>
function Write-WslInstallRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [hashtable]$Record,

        [Parameter(Mandatory)]
        [pscustomobject]$Version,

        [Parameter(Mandatory)]
        [bool]$IsSuccess
    )

    $status = $IsSuccess ? 'success' : 'failed'
    $irScopes = ($Record.scopes -join ' ').Trim()
    $bashCmd = [string]::Join("`n",
        'source .assets/lib/install_record.sh',
        "_IR_ENTRY_POINT='wsl/nix'",
        "_IR_VERSION='$($Version.Version)'",
        "_IR_SOURCE='$($Version.Source)'",
        "_IR_SOURCE_REF='$($Version.SourceRef)'",
        "_IR_SCOPES='$irScopes'",
        "_IR_MODE='$($Record.mode)'",
        "_IR_PLATFORM='WSL'",
        "write_install_record '$status' '$($Record.phase)' '$($Record.error)'"
    )
    try {
        wsl.exe --distribution $Distro --exec bash -c $bashCmd 2>$null | Out-Default
    } catch {
        # best-effort: don't fail cleanup if the distro is unreachable
    }
}
