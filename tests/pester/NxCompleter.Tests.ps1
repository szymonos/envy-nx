#Requires -Modules Pester
# Unit tests for the nx argument completer registered in _aliases_nix.ps1.
# Tests use TabExpansion2 to invoke the native completer end-to-end.

BeforeAll {
    $Script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $Script:TestDir = Join-Path ([IO.Path]::GetTempPath()) "nx-completer-test-$PID"
    New-Item -ItemType Directory -Path $Script:TestDir -Force | Out-Null

    # create a fake nix-env dir with config and packages for dynamic completion
    $Script:FakeEnvDir = "$Script:TestDir/.config/nix-env"
    New-Item -ItemType Directory -Path "$Script:FakeEnvDir/scopes" -Force | Out-Null

    # config.nix with scopes
    @'
{
  isInit = false;
  allowUnfree = false;
  scopes = [
    "shell"
    "python"
    "local_mytools"
  ];
}
'@ | Set-Content "$Script:FakeEnvDir/config.nix"

    # a local overlay scope file (not in config.nix)
    '' | Set-Content "$Script:FakeEnvDir/scopes/local_extra.nix"

    # packages.nix with user-installed packages
    @'
[
  "httpie"
  "jless"
]
'@ | Set-Content "$Script:FakeEnvDir/packages.nix"

    # stub the nx function (required for Register-ArgumentCompleter)
    function global:nx { }

    # override HOME so the completer reads our fake files
    $Script:OrigHome = $HOME
    Set-Variable -Name HOME -Value $Script:TestDir -Force -Scope Global
    $env:HOME = $Script:TestDir

    # source the aliases file to register the completer
    . "$Script:RepoRoot/.assets/config/pwsh_cfg/_aliases_nix.ps1"

    # helper: get completion texts for a given input line
    function global:Get-NxCompletions {
        param([string]$InputLine)
        $cursor = $InputLine.Length
        $result = [System.Management.Automation.CommandCompletion]::CompleteInput(
            $InputLine, $cursor, $null
        )
        $result.CompletionMatches | ForEach-Object { $_.CompletionText }
    }
}

AfterAll {
    Set-Variable -Name HOME -Value $Script:OrigHome -Force -Scope Global
    $env:HOME = $Script:OrigHome
    if (Test-Path $Script:TestDir) {
        Remove-Item -Recurse -Force $Script:TestDir
    }
    Remove-Item -Path Function:\nx -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Get-NxCompletions -ErrorAction SilentlyContinue
}

Describe 'nx top-level completions' {
    It 'completes all top-level commands' {
        $completions = Get-NxCompletions 'nx '
        $expected = @('search', 'install', 'remove', 'upgrade', 'rollback', 'pin',
            'list', 'scope', 'overlay', 'profile', 'setup', 'self',
            'doctor', 'prune', 'gc', 'version', 'help')
        foreach ($cmd in $expected) {
            $completions | Should -Contain $cmd
        }
    }

    It 'filters by prefix' {
        $completions = Get-NxCompletions 'nx s'
        $completions | Should -Contain 'search'
        $completions | Should -Contain 'scope'
        $completions | Should -Contain 'setup'
        $completions | Should -Contain 'self'
        $completions | Should -Not -Contain 'install'
    }
}

Describe 'nx scope completions' {
    It 'completes scope subcommands' {
        $completions = Get-NxCompletions 'nx scope '
        $expected = @('list', 'show', 'tree', 'add', 'edit', 'remove')
        foreach ($cmd in $expected) {
            $completions | Should -Contain $cmd
        }
    }

    It 'completes scope names for show' {
        $completions = Get-NxCompletions 'nx scope show '
        $completions | Should -Contain 'shell'
        $completions | Should -Contain 'python'
        $completions | Should -Contain 'mytools'
        $completions | Should -Contain 'extra'
    }

    It 'completes scope names for edit' {
        $completions = Get-NxCompletions 'nx scope edit '
        $completions | Should -Contain 'shell'
    }

    It 'completes scope names for remove' {
        $completions = Get-NxCompletions 'nx scope remove '
        $completions | Should -Contain 'python'
    }

    It 'strips local_ prefix from scope names' {
        $completions = Get-NxCompletions 'nx scope show '
        $completions | Should -Contain 'mytools'
        $completions | Should -Not -Contain 'local_mytools'
    }

    It 'discovers local scopes not in config.nix' {
        $completions = Get-NxCompletions 'nx scope show '
        $completions | Should -Contain 'extra'
    }
}

Describe 'nx pin completions' {
    It 'completes pin subcommands' {
        $completions = Get-NxCompletions 'nx pin '
        $expected = @('set', 'remove', 'show', 'help')
        foreach ($cmd in $expected) {
            $completions | Should -Contain $cmd
        }
    }
}

Describe 'nx profile completions' {
    It 'completes profile subcommands' {
        $completions = Get-NxCompletions 'nx profile '
        $expected = @('doctor', 'regenerate', 'uninstall', 'help')
        foreach ($cmd in $expected) {
            $completions | Should -Contain $cmd
        }
    }
}

Describe 'nx self completions' {
    It 'completes self subcommands' {
        $completions = Get-NxCompletions 'nx self '
        $expected = @('update', 'path', 'help')
        foreach ($cmd in $expected) {
            $completions | Should -Contain $cmd
        }
    }

    It 'completes --force for self update' {
        $completions = Get-NxCompletions 'nx self update '
        $completions | Should -Contain '--force'
    }
}

Describe 'nx setup completions' {
    It 'completes setup flags at position 2' {
        $completions = Get-NxCompletions 'nx setup '
        $completions | Should -Contain '--shell'
        $completions | Should -Contain '--python'
        $completions | Should -Contain '--upgrade'
        $completions | Should -Contain '--all'
        $completions | Should -Contain '--help'
    }

    It 'completes setup flags at position 3+' {
        $completions = Get-NxCompletions 'nx setup --shell '
        $completions | Should -Contain '--python'
        $completions | Should -Contain '--upgrade'
    }

    It 'includes all scope and meta flags' {
        $completions = Get-NxCompletions 'nx setup '
        $expected = @('--az', '--bun', '--conda', '--docker', '--gcloud',
            '--k8s-base', '--k8s-dev', '--k8s-ext', '--nodejs', '--pwsh',
            '--python', '--rice', '--shell', '--terraform', '--zsh',
            '--all', '--upgrade', '--allow-unfree', '--unattended',
            '--update-modules', '--omp-theme', '--starship-theme',
            '--remove', '--help')
        foreach ($flag in $expected) {
            $completions | Should -Contain $flag
        }
    }

    It 'filters flags by prefix' {
        $completions = Get-NxCompletions 'nx setup --k'
        $completions | Should -Contain '--k8s-base'
        $completions | Should -Contain '--k8s-dev'
        $completions | Should -Contain '--k8s-ext'
        $completions | Should -Not -Contain '--shell'
    }
}

Describe 'nx remove completions' {
    It 'completes package names for remove' {
        $completions = Get-NxCompletions 'nx remove '
        $completions | Should -Contain 'httpie'
        $completions | Should -Contain 'jless'
    }

    It 'completes package names for uninstall alias' {
        $completions = Get-NxCompletions 'nx uninstall '
        $completions | Should -Contain 'httpie'
    }

    It 'completes multiple packages' {
        $completions = Get-NxCompletions 'nx remove httpie '
        $completions | Should -Contain 'jless'
    }
}

Describe 'nx completions with missing files' {
    BeforeAll {
        $Script:SavedCfg = Get-Content "$Script:FakeEnvDir/config.nix"
        $Script:SavedPkg = Get-Content "$Script:FakeEnvDir/packages.nix"
    }

    It 'returns empty scope names when config.nix is missing' {
        $cfgPath = "$Script:FakeEnvDir/config.nix"
        Remove-Item $cfgPath
        try {
            $completions = Get-NxCompletions 'nx scope show '
            $completions | Should -Contain 'extra'
            $completions | Should -Not -Contain 'shell'
        } finally {
            $Script:SavedCfg | Set-Content $cfgPath
        }
    }

    It 'does not complete package names when packages.nix is missing' {
        $pkgPath = "$Script:FakeEnvDir/packages.nix"
        Remove-Item $pkgPath
        try {
            $completions = Get-NxCompletions 'nx remove '
            $completions | Should -Not -Contain 'httpie'
            $completions | Should -Not -Contain 'jless'
        } finally {
            $Script:SavedPkg | Set-Content $pkgPath
        }
    }

    It 'still completes top-level commands when env dir is empty' {
        $scopesDir = "$Script:FakeEnvDir/scopes"
        $cfgPath = "$Script:FakeEnvDir/config.nix"
        $pkgPath = "$Script:FakeEnvDir/packages.nix"
        Remove-Item $cfgPath
        Remove-Item $pkgPath
        Remove-Item -Recurse $scopesDir
        try {
            $completions = Get-NxCompletions 'nx '
            $completions | Should -Contain 'setup'
            $completions | Should -Contain 'self'
            $completions | Should -Contain 'scope'
        } finally {
            New-Item -ItemType Directory -Path $scopesDir -Force | Out-Null
            '' | Set-Content "$scopesDir/local_extra.nix"
            $Script:SavedCfg | Set-Content $cfgPath
            $Script:SavedPkg | Set-Content $pkgPath
        }
    }
}
