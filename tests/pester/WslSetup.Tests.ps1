#Requires -Modules Pester
# Integration tests for wsl/wsl_setup.ps1 orchestration logic.
# Mocks wsl.exe and Windows-only functions to verify the correct sequence
# of provisioning calls for each scope.

BeforeAll {
    $Script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # allow the script to run on Linux (bypasses $IsLinux guard)
    $env:WSL_SETUP_TESTING = '1'
    # provide Windows-like env vars for SSH path computation (line 448)
    $env:HOMEDRIVE = 'C:'
    $env:HOMEPATH = '\Users\testuser'

    # import modules so the real functions exist (we will mock them)
    Import-Module "$Script:RepoRoot/modules/do-common" -Force
    Import-Module "$Script:RepoRoot/modules/utils-install" -Force
    Import-Module "$Script:RepoRoot/modules/utils-setup" -Force

    # helper: build a check_distro JSON response
    function New-CheckDistro {
        param(
            [string]$User = 'testuser',
            [int]$Uid = 1000,
            [hashtable]$Flags = @{}
        )
        $defaults = @{
            user = $User; uid = $Uid; def_uid = $Uid
            az = $false; bun = $false; conda = $false; gcloud = $false
            git_user = $true; git_email = $true; gtkd = $false
            k8s_base = $false; k8s_dev = $false; k8s_ext = $false
            nix = $false; oh_my_posh = $false
            python = $false; pwsh = $false; shell = $false
            ssh_key = $true; systemd = $true; terraform = $false
            wsl_boot = $true; wslg = $false; zsh = $false
        }
        foreach ($key in $Flags.Keys) { $defaults[$key] = $Flags[$key] }
        $defaults | ConvertTo-Json -Compress
    }

    # collector for wsl.exe invocations
    $global:WslTestCalls = [System.Collections.Generic.List[string[]]]::new()

    # define wsl.exe stub so Pester can mock it on Linux (where it does not exist)
    if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) {
        function global:wsl.exe { }
    }

    # default check_distro response (overridden per test)
    $global:WslTestCheckDistroJson = New-CheckDistro
}

AfterAll {
    $env:WSL_SETUP_TESTING = $null
    $env:HOMEDRIVE = $null
    $env:HOMEPATH = $null
    Remove-Variable -Name WslTestCalls, WslTestCheckDistroJson -Scope Global -ErrorAction SilentlyContinue
}

Describe 'wsl_setup.ps1 orchestration' {
    BeforeEach {
        $global:WslTestCalls.Clear()

        # shared wsl.exe mock body - registered both at script scope (for direct
        # script-body calls) and inside the utils-setup module scope (for calls
        # made from extracted phase functions like Invoke-WslDistroCheck)
        $wslMockBody = {
            $global:WslTestCalls.Add([string[]]$args)
            $argStr = $args -join ' '
            # return appropriate responses based on the script being called
            if ($argStr -match 'check_distro\.sh') {
                return $global:WslTestCheckDistroJson
            }
            if ($argStr -match 'check_dns\.sh') {
                return 'true'
            }
            if ($argStr -match 'check_ssl\.sh') {
                return 'true'
            }
            if ($argStr -match 'hosts\.yml') {
                return 'github.com'
            }
            if ($argStr -match 'command -v pwsh') {
                return 'true'
            }
            # provision/install scripts: return a fake version string
            if ($argStr -match 'install_\w+\.sh') {
                return 'v1.0.0'
            }
            return ''
        }
        Mock -CommandName 'wsl.exe' -MockWith $wslMockBody
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith $wslMockBody

        # mock Windows-only functions
        Mock Get-WslDistro {
            [PSCustomObject]@{ Default = $true; Name = 'Ubuntu'; State = 'Running'; Version = 2 }
        }
        Mock Get-WslDistro -ParameterFilter { $FromRegistry } {
            [PSCustomObject]@{
                Name = 'Ubuntu'; DefaultUid = 1000; Version = 2
                Flags = 15; BasePath = 'C:\fake'; Default = $true
            }
        }
        Mock Set-WslConf {}
        Mock Update-GitRepository { return 1 }
        Mock Invoke-GhRepoClone { return 2 }
        Mock Test-IsAdmin { return $false }

        # mock filesystem operations that would create side-effect dirs
        Mock New-Item {}
        Mock Remove-Item {}

        # prevent the script from re-importing modules (which overwrites our mocks)
        Mock Import-Module {}
    }

    BeforeAll {
        # helper: extract the script path from recorded wsl.exe calls
        function Get-WslScripts {
            $global:WslTestCalls | ForEach-Object {
                $joined = $_ -join ' '
                if ($joined -match '(?:--exec\s+)(\S+\.(?:sh|ps1))') {
                    $Matches[1]
                }
            } | Where-Object { $_ }
        }
    }

    Context 'Nix mode with shell and python scopes' {
        It 'calls nix/setup.sh instead of individual install scripts' {
            $global:WslTestCheckDistroJson = New-CheckDistro

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('shell', 'python') -SkipRepoUpdate 6>$null

            $scripts = Get-WslScripts
            # should use nix path
            $scripts | Should -Contain '.assets/provision/install_base.sh'
            $scripts | Should -Contain '.assets/provision/install_nix.sh'
            $scripts | Should -Contain 'nix/setup.sh'
            # should NOT call individual shell/python install scripts
            $scripts | Should -Not -Contain '.assets/provision/install_fzf.sh'
            $scripts | Should -Not -Contain '.assets/provision/install_uv.sh'
            $scripts | Should -Not -Contain '.assets/setup/setup_python.sh'
        }

        It 'passes correct flags to nix/setup.sh' {
            $global:WslTestCheckDistroJson = New-CheckDistro

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('shell', 'python') -SkipRepoUpdate 6>$null

            $nixCall = $global:WslTestCalls | Where-Object { ($_ -join ' ') -match 'nix/setup\.sh' } | Select-Object -First 1
            $nixArgs = $nixCall -join ' '
            $nixArgs | Should -Match '--shell'
            $nixArgs | Should -Match '--python'
            $nixArgs | Should -Match '--unattended'
            $nixArgs | Should -Match '--skip-repo-update'
        }
    }

    Context 'Nix mode with docker falls back to traditional install' {
        It 'installs docker traditionally even in Nix mode' {
            $global:WslTestCheckDistroJson = New-CheckDistro -Flags @{ systemd = $true }

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('shell', 'docker') -SkipRepoUpdate 6>$null

            $scripts = Get-WslScripts
            $scripts | Should -Contain 'nix/setup.sh'
            $scripts | Should -Contain '.assets/provision/install_docker.sh'
        }
    }

    Context 'Nix path is always used' {
        It 'uses Nix path for all distros' {
            $global:WslTestCheckDistroJson = New-CheckDistro

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('shell') -SkipRepoUpdate 6>$null

            $scripts = Get-WslScripts
            $scripts | Should -Contain '.assets/provision/install_base.sh'
            $scripts | Should -Contain '.assets/provision/install_nix.sh'
            $scripts | Should -Contain 'nix/setup.sh'
            $scripts | Should -Not -Contain '.assets/provision/install_fzf.sh'
        }
    }

    Context 'Nix mode with OmpTheme' {
        It 'passes --omp-theme to nix/setup.sh' {
            $global:WslTestCheckDistroJson = New-CheckDistro

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('shell') -OmpTheme 'nerd' -SkipRepoUpdate 6>$null

            $nixCall = $global:WslTestCalls | Where-Object { ($_ -join ' ') -match 'nix/setup\.sh' } | Select-Object -First 1
            $nixArgs = $nixCall -join ' '
            $nixArgs | Should -Match '--omp-theme'
            $nixArgs | Should -Match 'nerd'
        }
    }

    Context 'Zsh scope installs system-wide before nix' {
        It 'calls install_zsh.sh and passes --zsh to nix/setup.sh' {
            $global:WslTestCheckDistroJson = New-CheckDistro

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('shell', 'zsh') -SkipRepoUpdate 6>$null

            $scripts = Get-WslScripts
            $scripts | Should -Contain '.assets/provision/install_zsh.sh'
            $scripts | Should -Contain 'nix/setup.sh'
            $nixCall = $global:WslTestCalls | Where-Object { ($_ -join ' ') -match 'nix/setup\.sh' } | Select-Object -First 1
            $nixArgs = $nixCall -join ' '
            $nixArgs | Should -Match '--zsh'
        }
    }

    Context 'Pwsh scope passes --pwsh to nix args for system-prefer detection' {
        It 'passes --pwsh to nix/setup.sh (nix/setup.sh skips if system pwsh exists)' {
            $global:WslTestCheckDistroJson = New-CheckDistro

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('shell', 'pwsh') -SkipRepoUpdate 6>$null

            $nixCall = $global:WslTestCalls | Where-Object { ($_ -join ' ') -match 'nix/setup\.sh' } | Select-Object -First 1
            $nixArgs = $nixCall -join ' '
            $nixArgs | Should -Match '--pwsh'
        }
    }

    Context 'WSL1 distro removes incompatible scopes' {
        BeforeEach {
            # initial Get-WslDistro returns Version=2 to skip the interactive WSL1 prompt
            # but -FromRegistry returns Version=1 which is used for scope filtering in process{}
            Mock Get-WslDistro {
                [PSCustomObject]@{ Default = $true; Name = 'Ubuntu'; State = 'Running'; Version = 2 }
            }
            Mock Get-WslDistro -ParameterFilter { $FromRegistry } {
                [PSCustomObject]@{
                    Name = 'Ubuntu'; DefaultUid = 1000; Version = 1
                    Flags = 15; BasePath = 'C:\fake'; Default = $true
                }
            }
        }

        It 'does not install docker or k8s_ext on WSL1' {
            $global:WslTestCheckDistroJson = New-CheckDistro

            & "$Script:RepoRoot/wsl/wsl_setup.ps1" -Distro 'Ubuntu' -Scope @('docker', 'shell') -SkipRepoUpdate 6>$null

            $scripts = Get-WslScripts
            $scripts | Should -Not -Contain '.assets/provision/install_docker.sh'
            # shell should still be installed (via nix)
            $scripts | Should -Contain 'nix/setup.sh'
        }
    }

    Context 'DNS failure halts execution' {
        It 'exits with non-zero when DNS check fails' {
            # Subprocess required because wsl_setup.ps1's DNS check calls
            # `exit 1` and would terminate the test runner. Mock setup is
            # extracted into _helpers/Invoke-WslSetupScenario.ps1 so future
            # subprocess scenarios can reuse the same harness without
            # reinventing the heredoc-with-escapes dance. Dot-source via
            # `-Command` (rather than `-File`) so the script's function
            # overrides land in the child's global scope and shadow the
            # imported module functions for wsl_setup.ps1's calls.
            $helper = Join-Path $Script:RepoRoot 'tests/pester/_helpers/Invoke-WslSetupScenario.ps1'
            $null = pwsh -NoProfile -Command ". '$helper' -RepoRoot '$($Script:RepoRoot)' -DnsResult 'false'"
            $LASTEXITCODE | Should -Not -Be 0
        }
    }

}
