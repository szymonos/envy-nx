#Requires -Modules Pester
# Unit tests for --help routing in the nx function in _aliases_nix.ps1: the
# natively handled `nx profile` commands must not run when given -h/--help
# (nx.sh prints the help; bats covers that side).

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    # Load only the nx function - dot-sourcing the whole file would run its
    # alias and environment setup in the test session. It is loaded from a file
    # rather than a script block so its $PSScriptRoot lookup has a path to join.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$repoRoot/.assets/config/pwsh_cfg/_aliases_nix.ps1", [ref]$null, [ref]$null
    )
    $fn = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'nx'
        }, $true)
    Set-Content -Path "$TestDrive/nx.ps1" -Value ('function global:nx {0}' -f $fn.Body.Extent.Text)
    . "$TestDrive/nx.ps1"

    function global:_NxProfileRegenerate { $global:NxNativeCalls.Add('regenerate') | Out-Null }
    function global:_NxProfileUninstall { $global:NxNativeCalls.Add('uninstall') | Out-Null }
    function global:bash { }
}

AfterAll {
    Remove-Item -Path 'Function:\nx', 'Function:\_NxProfileRegenerate', 'Function:\_NxProfileUninstall', 'Function:\bash' -ErrorAction SilentlyContinue
    Remove-Variable -Name NxNativeCalls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'nx profile --help routing' {
    BeforeEach {
        $global:NxNativeCalls = [System.Collections.Generic.List[string]]::new()
    }

    It 'runs the native handler without --help' {
        nx profile regenerate
        $global:NxNativeCalls | Should -Be @('regenerate')
    }

    It 'does not run <Sub> when given <Flag>' -ForEach @(
        @{ Sub = 'regenerate'; Flag = '--help' }
        @{ Sub = 'regenerate'; Flag = '-h' }
        @{ Sub = 'uninstall'; Flag = '--help' }
    ) {
        nx profile $Sub $Flag 6>$null
        $global:NxNativeCalls.Count | Should -Be 0
    }
}
