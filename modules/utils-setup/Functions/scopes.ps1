function Resolve-ScopeDeps {
    <#
    .SYNOPSIS
    Expands implicit scope dependencies in a HashSet using shared rules from scopes.json.
    .PARAMETER ScopeSet
    A HashSet[string] of enabled scopes - modified in-place. Empty sets are
    accepted (no-op): a fresh-distro `wsl_setup.ps1 <Distro>` with no -Scope and
    nothing auto-detected legitimately reaches this function with an empty set.
    .PARAMETER OmpTheme
    If non-empty, implies oh_my_posh scope.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$ScopeSet,

        [string]$OmpTheme
    )

    if ($OmpTheme) {
        $ScopeSet.Add('oh_my_posh') | Out-Null
    }

    foreach ($rule in $Script:ScopeDependencyRules) {
        if ($ScopeSet.Contains($rule.if)) {
            $rule.add.ForEach({ $ScopeSet.Add($_) | Out-Null })
        }
    }
}

function Get-SortedScopes {
    <#
    .SYNOPSIS
    Returns scopes sorted by install order from scopes.json.
    .PARAMETER ScopeSet
    A HashSet[string] of enabled scopes. Empty sets return an empty `[string[]]`
    (no scopes to install - the orchestrator's loop bodies are scope-gated and
    handle this as "nothing to do for this distro").
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$ScopeSet
    )

    if ($ScopeSet.Count -eq 0) {
        # PowerShell unwraps `return @()` to $null in the pipeline; -NoEnumerate
        # preserves the empty [string[]] so callers can do `[string[]]$x = Get-SortedScopes ...`
        # without a $null fallback.
        Write-Output -InputObject ([string[]]@()) -NoEnumerate
        return
    }

    [string[]]$sorted = $ScopeSet | Sort-Object -Unique {
        $idx = [array]::IndexOf($Script:InstallOrder, $_)
        if ($idx -ge 0) { $idx } else { 999 }
    }
    return $sorted
}
