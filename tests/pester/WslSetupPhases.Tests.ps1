#Requires -Modules Pester
# Unit tests for the wsl phase functions in modules/utils-setup/Functions/wsl_phases.ps1,
# wsl_install.ps1 and wsl_provenance.ps1. Each function is exercised with a synthetic
# check_distro hashtable; wsl.exe is mocked at the utils-setup module scope so no real
# WSL invocations happen even on Windows runners.

BeforeAll {
    $Script:RepoRoot = (Resolve-Path -Path "$PSScriptRoot/../..").Path
    Import-Module -Name "$Script:RepoRoot/modules/do-common" -Force
    Import-Module -Name "$Script:RepoRoot/modules/utils-setup" -Force

    # define stubs on Linux/macOS so Pester `Mock` has something to bind to
    if (-not (Get-Command -Name 'wsl.exe' -ErrorAction SilentlyContinue)) {
        function global:wsl.exe { }
    }
    if (-not (Get-Command -Name 'Get-Service' -ErrorAction SilentlyContinue)) {
        function global:Get-Service { }
    }

    # builds the same shape returned by `wsl.exe ... check_distro.sh | ConvertFrom-Json -AsHashtable`
    function New-CheckDistroHashtable {
        [CmdletBinding()]
        param (
            [string]$User = 'testuser',
            [int]$Uid = 1000,
            [hashtable]$Flags = @{}
        )

        $defaults = @{
            user       = $User
            uid        = $Uid
            def_uid    = $Uid
            az         = $false
            bun        = $false
            conda      = $false
            gcloud     = $false
            git_user   = $true
            git_email  = $true
            gtkd       = $false
            k8s_base   = $false
            k8s_dev    = $false
            k8s_ext    = $false
            nix        = $false
            oh_my_posh = $false
            python     = $false
            pwsh       = $false
            shell      = $false
            ssh_key    = $true
            systemd    = $true
            terraform  = $false
            wsl_boot   = $true
            wslg       = $false
            zsh        = $false
        }
        foreach ($key in $Flags.Keys) {
            $defaults[$key] = $Flags[$key]
        }
        return $defaults
    }

    function New-DistroRecord {
        [CmdletBinding()]
        param (
            [string]$Mode = 'install'
        )

        return @{
            phase  = 'distro-check'
            scopes = @()
            mode   = $Mode
            error  = ''
        }
    }
}

Describe 'Resolve-WslDistroScopes' {
    Context 'WSL2 happy path' {
        It 'augments scope set from check fields and resolves dependencies' {
            $check = New-CheckDistroHashtable -Flags @{ az = $true; pwsh = $true }
            $rec = New-DistroRecord
            $sorted = Resolve-WslDistroScopes `
                -Scope @() `
                -Check $check `
                -WslVersion 2 `
                -DistroRecord $rec
            $sorted | Should -Contain 'az'
            $sorted | Should -Contain 'pwsh'
            # az -> python (from scopes.json dependency_rules)
            $sorted | Should -Contain 'python'
            # pwsh -> shell
            $sorted | Should -Contain 'shell'
            $rec.scopes | Should -Be $sorted
        }

        It 'OmpTheme on WSL2 implicitly adds oh_my_posh' {
            $check = New-CheckDistroHashtable
            $rec = New-DistroRecord
            $sorted = Resolve-WslDistroScopes `
                -Scope @('shell') `
                -Check $check `
                -WslVersion 2 `
                -OmpTheme 'nerd' `
                -DistroRecord $rec
            $sorted | Should -Contain 'oh_my_posh'
            $sorted | Should -Contain 'shell'
        }

        It 'merges -Scope with check-detected scopes' {
            $check = New-CheckDistroHashtable -Flags @{ shell = $true }
            $rec = New-DistroRecord
            $sorted = Resolve-WslDistroScopes `
                -Scope @('terraform') `
                -Check $check `
                -WslVersion 2 `
                -DistroRecord $rec
            $sorted | Should -Contain 'shell'
            $sorted | Should -Contain 'terraform'
        }

        It 'returns sorted list following the install order' {
            $check = New-CheckDistroHashtable -Flags @{ shell = $true; python = $true; az = $true }
            $rec = New-DistroRecord
            $sorted = Resolve-WslDistroScopes `
                -Scope @() `
                -Check $check `
                -WslVersion 2 `
                -DistroRecord $rec
            # install_order in scopes.json: python (4) < az (6) < shell (13)
            $pythonIdx = [array]::IndexOf($sorted, 'python')
            $azIdx = [array]::IndexOf($sorted, 'az')
            $shellIdx = [array]::IndexOf($sorted, 'shell')
            $pythonIdx | Should -BeGreaterOrEqual 0
            $azIdx | Should -BeGreaterThan $pythonIdx
            $shellIdx | Should -BeGreaterThan $azIdx
        }
    }

    Context 'WSL1 strips incompatible scopes' {
        It 'removes distrobox/docker/k8s_ext/oh_my_posh on WSL1' {
            $check = New-CheckDistroHashtable
            $rec = New-DistroRecord
            $sorted = Resolve-WslDistroScopes `
                -Scope @('docker', 'distrobox', 'k8s_ext', 'shell') `
                -Check $check `
                -WslVersion 1 `
                -DistroRecord $rec
            $sorted | Should -Not -Contain 'docker'
            $sorted | Should -Not -Contain 'distrobox'
            $sorted | Should -Not -Contain 'k8s_ext'
            $sorted | Should -Contain 'shell'
        }

        It 'OmpTheme is ignored on WSL1' {
            $check = New-CheckDistroHashtable
            $rec = New-DistroRecord
            $sorted = Resolve-WslDistroScopes `
                -Scope @('shell') `
                -Check $check `
                -WslVersion 1 `
                -OmpTheme 'nerd' `
                -DistroRecord $rec
            $sorted | Should -Not -Contain 'oh_my_posh'
            $sorted | Should -Contain 'shell'
        }
    }

    Context 'edge cases' {
        It 'accepts $null -Scope when only check-detected scopes apply' {
            $check = New-CheckDistroHashtable -Flags @{ shell = $true }
            $rec = New-DistroRecord
            $sorted = Resolve-WslDistroScopes `
                -Scope $null `
                -Check $check `
                -WslVersion 2 `
                -DistroRecord $rec
            $sorted | Should -Contain 'shell'
        }
    }
}

Describe 'Invoke-WslBaseSetup' {
    BeforeEach {
        $script:dnsResponses = [System.Collections.Generic.Queue[string]]::new()
        $script:sslResponses = [System.Collections.Generic.Queue[string]]::new()
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $argStr = $args -join ' '
            if ($argStr -match 'check_dns\.sh') {
                return $script:dnsResponses.Count -gt 0 ? $script:dnsResponses.Dequeue() : 'true'
            }
            if ($argStr -match 'check_ssl\.sh') {
                return $script:sslResponses.Count -gt 0 ? $script:sslResponses.Dequeue() : 'true'
            }
            return ''
        }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
        Mock -CommandName 'Set-WslConf' -ModuleName 'utils-setup' -MockWith { }
        # the wsl/wsl_*.ps1 scripts are referenced as commands; stub them
        function global:wsl/wsl_network_fix.ps1 { }
        function global:wsl/wsl_certs_add.ps1 { }
    }

    It 'happy path returns FixNetwork/AddCertificate as supplied' {
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        $result = Invoke-WslBaseSetup `
            -Distro 'Ubuntu' `
            -Check $check `
            -FixNetwork $false `
            -AddCertificate $false `
            -DistroRecord $rec
        $result.FixNetwork | Should -Be $false
        $result.AddCertificate | Should -Be $false
        $rec.error | Should -Be ''
    }

    It 'auto-promotes FixNetwork on initial DNS probe failure when fix succeeds' {
        $script:dnsResponses.Enqueue('false')   # initial probe fails
        $script:dnsResponses.Enqueue('true')    # post-fix probe succeeds
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        $result = Invoke-WslBaseSetup `
            -Distro 'Ubuntu' `
            -Check $check `
            -FixNetwork $false `
            -AddCertificate $true `
            -DistroRecord $rec
        $result.FixNetwork | Should -Be $true
        $rec.error | Should -Be ''
    }

    It 'throws on persistent DNS failure and populates DistroRecord.error' {
        $script:dnsResponses.Enqueue('false')
        $script:dnsResponses.Enqueue('false')
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        { Invoke-WslBaseSetup `
                -Distro 'Ubuntu' `
                -Check $check `
                -FixNetwork $false `
                -AddCertificate $true `
                -DistroRecord $rec } |
            Should -Throw 'DNS resolution failed'
        $rec.error | Should -Be 'DNS resolution failed'
    }

    It 'throws on persistent SSL failure and populates DistroRecord.error' {
        $script:sslResponses.Enqueue('false')
        $script:sslResponses.Enqueue('false')
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        { Invoke-WslBaseSetup `
                -Distro 'Ubuntu' `
                -Check $check `
                -FixNetwork $true `
                -AddCertificate $false `
                -DistroRecord $rec } |
            Should -Throw 'SSL certificate verification failed'
        $rec.error | Should -Be 'SSL certificate verification failed'
    }

    It 'always calls Set-WslConf so existing wsl.conf picks up the runtime-dir prefix' {
        # Both wsl_boot states should call Set-WslConf -- the gate was dropped
        # because we want existing distros to get the new boot.command on the
        # next setup run, not just fresh installs.
        foreach ($wslBoot in @($true, $false)) {
            $check = New-CheckDistroHashtable -Flags @{ wsl_boot = $wslBoot }
            $rec = New-DistroRecord
            Invoke-WslBaseSetup `
                -Distro 'Ubuntu' `
                -Check $check `
                -FixNetwork $true `
                -AddCertificate $true `
                -DistroRecord $rec
        }
        Should -Invoke -CommandName 'Set-WslConf' -ModuleName 'utils-setup' -Times 2
    }

    It 'composes boot.command with user-runtime-dir@<def_uid>.service start' {
        $script:capturedConf = $null
        Mock -CommandName 'Set-WslConf' -ModuleName 'utils-setup' -MockWith {
            $script:capturedConf = $ConfDict
        }
        $check = New-CheckDistroHashtable -Uid 1000 -Flags @{ def_uid = 1000 }
        $rec = New-DistroRecord
        Invoke-WslBaseSetup `
            -Distro 'Ubuntu' `
            -Check $check `
            -FixNetwork $true `
            -AddCertificate $true `
            -DistroRecord $rec

        $script:capturedConf | Should -Not -BeNullOrEmpty
        $cmd = $script:capturedConf.boot.command
        $cmd | Should -Match 'systemctl start user-runtime-dir@1000\.service'
        $cmd | Should -Match 'command -v systemctl'
        $cmd | Should -Match 'autoexec\.sh'
    }
}

Describe 'Sync-WslGitHubConfig' {
    BeforeEach {
        $script:wslInvoked = $false
        $script:wslArgs = $null
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:wslInvoked = $true
            $script:wslArgs = $args
        }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
    }

    It 'is a no-op when GhConfig is null' {
        Sync-WslGitHubConfig -Distro 'Ubuntu' -GhConfig $null
        $script:wslInvoked | Should -Be $false
    }

    It 'is a no-op when GhConfig is empty' {
        Sync-WslGitHubConfig -Distro 'Ubuntu' -GhConfig @()
        $script:wslInvoked | Should -Be $false
    }

    It 'is a no-op when GhConfig has no github.com reference' {
        Sync-WslGitHubConfig -Distro 'Ubuntu' -GhConfig @('something else', 'no match here')
        $script:wslInvoked | Should -Be $false
    }

    It 'invokes wsl.exe with bash heredoc when GhConfig is valid' {
        $config = [string[]]@('github.com:', '  user: alice', '  oauth_token: tok')
        Sync-WslGitHubConfig -Distro 'Ubuntu' -GhConfig $config
        $script:wslInvoked | Should -Be $true
        $argStr = $script:wslArgs -join ' '
        $argStr | Should -Match '--distribution Ubuntu'
        $argStr | Should -Match 'GHEOF'
        $argStr | Should -Match 'github.com:'
    }
}

Describe 'Sync-WslSshKeys' {
    BeforeEach {
        $env:HOMEDRIVE = 'C:'
        $env:HOMEPATH = '\Users\testuser'
        $script:wslInvoked = $false
        $script:wslArgs = $null
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:wslInvoked = $true
            $script:wslArgs = $args
        }
        Mock -CommandName 'Test-Path' -ModuleName 'utils-setup' -MockWith { return $script:winKeyExists }
        Mock -CommandName 'Remove-Item' -ModuleName 'utils-setup' -MockWith { }
        Mock -CommandName 'New-Item' -ModuleName 'utils-setup' -MockWith { }
    }

    It 'copies Windows -> WSL when WSL has no key but Windows has' {
        $script:winKeyExists = $true
        Sync-WslSshKeys -Distro 'Ubuntu' -HasWslKey $false
        $script:wslInvoked | Should -Be $true
        ($script:wslArgs -join ' ') | Should -Match "install -m 0600"
    }

    It 'generates inside WSL then copies to Windows when both sides lack the key' {
        $script:winKeyExists = $false
        Sync-WslSshKeys -Distro 'Ubuntu' -HasWslKey $false
        $script:wslInvoked | Should -Be $true
        $argStr = $script:wslArgs -join ' '
        $argStr | Should -Match 'setup_ssh.sh'
        # The script must also copy the generated key BACK to the Windows
        # /mnt/<drive>/<homepath>/.ssh path - covers the second half of the
        # test name, which silently passed before this assertion was added.
        $winSshPath = "/mnt/$($env:HOMEDRIVE.Replace(':', '').ToLower())$($env:HOMEPATH.Replace('\', '/'))/.ssh"
        $argStr | Should -Match ([regex]::Escape("cp `"`$HOME/.ssh/id_ed25519`" $winSshPath/id_ed25519"))
        $argStr | Should -Match ([regex]::Escape("cp `"`$HOME/.ssh/id_ed25519.pub`" $winSshPath/id_ed25519.pub"))
    }

    It 'is a no-op when both sides already have the key' {
        $script:winKeyExists = $true
        Sync-WslSshKeys -Distro 'Ubuntu' -HasWslKey $true
        $script:wslInvoked | Should -Be $false
    }
}

Describe 'Install-WslScopes' {
    BeforeEach {
        $script:wslSucceeded = $true
        $script:wslCalls = [System.Collections.Generic.List[string[]]]::new()
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:wslCalls.Add([string[]]$args)
            # simulate wsl.exe's $LASTEXITCODE behavior: 0 on success, non-zero on failure
            $global:LASTEXITCODE = $script:wslSucceeded ? 0 : 1
        }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
        Mock -CommandName 'Test-Path' -ModuleName 'utils-setup' -MockWith { return $false }
        function global:wsl/wsl_systemd.ps1 { }
    }

    It 'happy path returns Success=$true with same SshKeyFp/PwshEnvSet when no keys present' {
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        $result = Install-WslScopes `
            -Distro 'Ubuntu' `
            -Scopes @('shell') `
            -Check $check `
            -WslVersion 2 `
            -SshKeyFp '' `
            -PwshEnvSet $true `
            -OmpTheme '' `
            -SkipModulesUpdate $false `
            -DistroRecord $rec
        $result.Success | Should -Be $true
        $result.SshKeyFp | Should -Be ''
        $result.PwshEnvSet | Should -Be $true
        $rec.error | Should -Be ''
    }

    It 'maps scopes to nix flags and forwards --omp-theme' {
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        Install-WslScopes `
            -Distro 'Ubuntu' `
            -Scopes @('shell', 'python', 'docker') `
            -Check $check `
            -WslVersion 2 `
            -SshKeyFp '' `
            -PwshEnvSet $true `
            -OmpTheme 'nerd' `
            -SkipModulesUpdate $false `
            -DistroRecord $rec
        $nixCall = $script:wslCalls.Where({ ($_ -join ' ') -match 'nix/setup\.sh' }) | Select-Object -First 1
        $nixArgStr = $nixCall -join ' '
        $nixArgStr | Should -Match '--shell'
        $nixArgStr | Should -Match '--python'
        $nixArgStr | Should -Not -Match '--docker'    # docker handled by system-wide install
        $nixArgStr | Should -Match '--omp-theme'
        $nixArgStr | Should -Match 'nerd'
        $nixArgStr | Should -Match '--unattended'
        $nixArgStr | Should -Match '--skip-repo-update'
    }

    It 'omits --update-modules when SkipModulesUpdate is true' {
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        Install-WslScopes `
            -Distro 'Ubuntu' `
            -Scopes @('shell') `
            -Check $check `
            -WslVersion 2 `
            -SshKeyFp '' `
            -PwshEnvSet $true `
            -OmpTheme '' `
            -SkipModulesUpdate $true `
            -DistroRecord $rec
        $nixCall = $script:wslCalls.Where({ ($_ -join ' ') -match 'nix/setup\.sh' }) | Select-Object -First 1
        ($nixCall -join ' ') | Should -Not -Match '--update-modules'
    }

    It 'skips docker install on WSL1' {
        $rec = New-DistroRecord
        $check = New-CheckDistroHashtable
        Install-WslScopes `
            -Distro 'Ubuntu' `
            -Scopes @('docker', 'shell') `
            -Check $check `
            -WslVersion 1 `
            -SshKeyFp '' `
            -PwshEnvSet $true `
            -OmpTheme '' `
            -SkipModulesUpdate $false `
            -DistroRecord $rec
        $dockerCall = $script:wslCalls.Where({ ($_ -join ' ') -match 'install_docker\.sh' })
        $dockerCall.Count | Should -Be 0
    }
}

Describe 'Set-WslGtkTheme' {
    BeforeEach {
        $script:wslInvoked = $false
        $script:wslArgs = $null
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:wslInvoked = $true
            $script:wslArgs = $args
        }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
    }

    It 'is a no-op on WSL1' {
        $check = New-CheckDistroHashtable -Flags @{ wslg = $true }
        Set-WslGtkTheme -Distro 'Ubuntu' -Check $check -WslVersion 1 -GtkTheme 'dark'
        $script:wslInvoked | Should -Be $false
    }

    It 'is a no-op when wslg is false' {
        $check = New-CheckDistroHashtable -Flags @{ wslg = $false }
        Set-WslGtkTheme -Distro 'Ubuntu' -Check $check -WslVersion 2 -GtkTheme 'dark'
        $script:wslInvoked | Should -Be $false
    }

    It 'writes Adwaita:dark when GtkTheme=dark and gtkd=false' {
        $check = New-CheckDistroHashtable -Flags @{ wslg = $true; gtkd = $false }
        Set-WslGtkTheme -Distro 'Ubuntu' -Check $check -WslVersion 2 -GtkTheme 'dark'
        $script:wslInvoked | Should -Be $true
        ($script:wslArgs -join ' ') | Should -Match 'Adwaita:dark'
    }

    It 'writes Adwaita when GtkTheme=light and gtkd=true' {
        $check = New-CheckDistroHashtable -Flags @{ wslg = $true; gtkd = $true }
        Set-WslGtkTheme -Distro 'Ubuntu' -Check $check -WslVersion 2 -GtkTheme 'light'
        $script:wslInvoked | Should -Be $true
        ($script:wslArgs -join ' ') | Should -Match '"Adwaita"'
    }

    It 'is a no-op when GtkTheme matches the installed gtkd state' {
        # GtkTheme=light + gtkd=false -> off-diagonal -> no-op
        $check = New-CheckDistroHashtable -Flags @{ wslg = $true; gtkd = $false }
        Set-WslGtkTheme -Distro 'Ubuntu' -Check $check -WslVersion 2 -GtkTheme 'light'
        $script:wslInvoked | Should -Be $false
    }
}

Describe 'Set-WslGitConfig' {
    BeforeEach {
        $script:wslInvoked = $false
        $script:wslArgs = $null
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:wslInvoked = $true
            $script:wslArgs = $args
        }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
    }

    It 'is a no-op when both git_user and git_email are already configured' {
        $check = New-CheckDistroHashtable -Flags @{ git_user = $true; git_email = $true }
        Set-WslGitConfig -Distro 'Ubuntu' -Check $check
        $script:wslInvoked | Should -Be $false
    }
}

Describe 'Invoke-WslExe' {
    # Off-Windows the helper falls back to the PowerShell call operator
    # (`if (-not $IsWindows)`) so Pester `Mock` can intercept. The production
    # Process.Start path can't be exercised on Linux/macOS runners.

    It 'forwards arguments to wsl.exe verbatim' {
        $script:capturedArgs = $null
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:capturedArgs = $args
        }
        Invoke-WslExe --install --distribution Ubuntu --web-download
        ($script:capturedArgs -join ' ') | Should -Be '--install --distribution Ubuntu --web-download'
    }

    It 'returns nothing (output is consumed by Out-Default)' {
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith { 'wsl-stdout-line' }
        $result = Invoke-WslExe --status
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-WslGtkThemePreference' {
    It 'returns light when SystemUsesLightTheme = 1' {
        Mock -CommandName 'Get-ItemPropertyValue' -ModuleName 'utils-setup' -MockWith { return 1 }
        Resolve-WslGtkThemePreference | Should -Be 'light'
    }

    It 'returns dark when SystemUsesLightTheme = 0' {
        Mock -CommandName 'Get-ItemPropertyValue' -ModuleName 'utils-setup' -MockWith { return 0 }
        Resolve-WslGtkThemePreference | Should -Be 'dark'
    }

    It 'returns dark when registry value is missing' {
        Mock -CommandName 'Get-ItemPropertyValue' -ModuleName 'utils-setup' -MockWith { return $null }
        Resolve-WslGtkThemePreference | Should -Be 'dark'
    }
}

Describe 'Get-WslGhConfigFromDefault' {
    BeforeEach {
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
    }

    It 'returns empty array when target is the default distro' {
        $installed = @(
            [pscustomobject]@{ Name = 'Ubuntu'; Default = $true }
            [pscustomobject]@{ Name = 'Debian'; Default = $false }
        )
        $result = Get-WslGhConfigFromDefault -TargetDistro 'Ubuntu' -InstalledDistros $installed
        $result | Should -BeNullOrEmpty
    }

    It 'returns empty array when no default distro exists' {
        $installed = @(
            [pscustomobject]@{ Name = 'Ubuntu'; Default = $false }
        )
        $result = Get-WslGhConfigFromDefault -TargetDistro 'Debian' -InstalledDistros $installed
        $result | Should -BeNullOrEmpty
    }

    It 'reads hosts.yml from the default distro when target differs' {
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            return @('github.com:', '  user: alice')
        }
        $installed = @(
            [pscustomobject]@{ Name = 'Ubuntu'; Default = $true }
            [pscustomobject]@{ Name = 'Debian'; Default = $false }
        )
        $result = Get-WslGhConfigFromDefault -TargetDistro 'Debian' -InstalledDistros $installed
        $result | Should -Contain 'github.com:'
    }
}

Describe 'Install-WslDistroIfMissing' {
    BeforeEach {
        $script:wslInvoked = $false
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith { $script:wslInvoked = $true }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
        Mock -CommandName 'Get-Service' -ModuleName 'utils-setup' -MockWith {
            return [pscustomobject]@{ Name = 'WSLService'; Status = 'Running' }
        }
        Mock -CommandName 'Get-WslDistro' -ModuleName 'utils-setup' -MockWith {
            return @([pscustomobject]@{ Name = 'Ubuntu' })
        }
    }

    It 'returns input unchanged when distro is already installed' {
        $installed = @([pscustomobject]@{ Name = 'Ubuntu' })
        $result = Install-WslDistroIfMissing -Distro 'Ubuntu' -InstalledDistros $installed
        $result | Should -Be 'Ubuntu'
        $script:wslInvoked | Should -Be $false
    }

    It 'throws when the distro is not in the online list' {
        Mock -CommandName 'Get-WslDistro' -ModuleName 'utils-setup' -MockWith {
            return @([pscustomobject]@{ Name = 'Ubuntu' })
        }
        $installed = @([pscustomobject]@{ Name = 'OtherDistro' })
        { Install-WslDistroIfMissing -Distro 'NonExistent' -InstalledDistros $installed } |
            Should -Throw "*unknown distro 'NonExistent'*"
    }
}

Describe 'Invoke-WslDistroMigration' {
    BeforeEach {
        $script:wslCalls = [System.Collections.Generic.List[string[]]]::new()
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:wslCalls.Add([string[]]$args)
        }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
        Mock -CommandName 'Get-ItemProperty' -ModuleName 'utils-setup' -MockWith {
            return [pscustomobject]@{ DefaultVersion = 2 }
        }
    }

    It 'choice 2 (continue WSL1) returns input distro unchanged and skips wsl.exe' {
        Mock -CommandName 'Get-WslMigrationChoice' -ModuleName 'utils-setup' -MockWith { return 2 }
        $result = Invoke-WslDistroMigration -Distro 'Ubuntu' -WebDownload $false
        $result | Should -Be 'Ubuntu'
        $script:wslCalls.Count | Should -Be 0
    }

    It 'choice 0 (replace) unregisters and reinstalls the same distro' {
        Mock -CommandName 'Get-WslMigrationChoice' -ModuleName 'utils-setup' -MockWith { return 0 }
        $result = Invoke-WslDistroMigration -Distro 'Ubuntu' -WebDownload $false
        $result | Should -Be 'Ubuntu'
        $argStrings = $script:wslCalls | ForEach-Object { $_ -join ' ' }
        $argStrings | Should -Contain '--unregister Ubuntu'
        # the reinstall call - args are [--install --distribution Ubuntu --no-launch]
        $reinstallCall = $argStrings.Where({ $_ -match '--install' -and $_ -match '--no-launch' })
        $reinstallCall.Count | Should -Be 1
    }

    It 'forwards --web-download when WebDownload is true' {
        Mock -CommandName 'Get-WslMigrationChoice' -ModuleName 'utils-setup' -MockWith { return 0 }
        Invoke-WslDistroMigration -Distro 'Ubuntu' -WebDownload $true
        $argStrings = $script:wslCalls | ForEach-Object { $_ -join ' ' }
        $argStrings.Where({ $_ -match '--web-download' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-WslInstallVersion' {
    It 'returns a PSCustomObject with Version/SourceRef/Source fields' {
        # runs against the real repo - asserting shape only, not specific
        # values. (Don't assert Source == 'git' here: tarball / zip checkouts
        # and worktrees legitimately resolve to other values, so an exact
        # match would break in environments the function explicitly supports.)
        $version = Get-WslInstallVersion
        $version | Should -BeOfType [pscustomobject]
        $version.PSObject.Properties.Name | Should -Contain 'Version'
        $version.PSObject.Properties.Name | Should -Contain 'SourceRef'
        $version.PSObject.Properties.Name | Should -Contain 'Source'
    }
}

Describe 'Write-WslInstallRecord' {
    BeforeEach {
        $script:wslArgs = $null
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:wslArgs = $args
        }
    }

    It 'builds a bash heredoc with all expected _IR_* assignments' {
        $rec = New-DistroRecord
        $rec.scopes = [string[]]@('shell', 'python')
        $rec.phase = 'complete'
        $version = [pscustomobject]@{ Version = '1.5.1'; SourceRef = 'abc123'; Source = 'git' }
        Write-WslInstallRecord -Distro 'Ubuntu' -Record $rec -Version $version -IsSuccess $true
        $captured = $script:wslArgs -join ' '
        $captured | Should -Match '--distribution Ubuntu'
        $captured | Should -Match "_IR_VERSION='1.5.1'"
        $captured | Should -Match "_IR_SOURCE='git'"
        $captured | Should -Match "_IR_SOURCE_REF='abc123'"
        $captured | Should -Match "_IR_SCOPES='shell python'"
        $captured | Should -Match "_IR_PLATFORM='WSL'"
        $captured | Should -Match "write_install_record 'success' 'complete' ''"
    }

    It 'sets status=failed when IsSuccess is false' {
        $rec = New-DistroRecord
        $rec.error = 'something broke'
        $version = [pscustomobject]@{ Version = '1.5.1'; SourceRef = 'abc'; Source = 'git' }
        Write-WslInstallRecord -Distro 'Ubuntu' -Record $rec -Version $version -IsSuccess $false
        ($script:wslArgs -join ' ') | Should -Match "write_install_record 'failed'"
    }

    It 'swallows wsl.exe errors silently' {
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith { throw 'unreachable distro' }
        $rec = New-DistroRecord
        $version = [pscustomobject]@{ Version = '1.5.1'; SourceRef = 'abc'; Source = 'git' }
        { Write-WslInstallRecord -Distro 'Broken' -Record $rec -Version $version -IsSuccess $true } |
            Should -Not -Throw
    }
}

Describe 'Invoke-WslDistroCheck' {
    BeforeEach {
        # wsl.exe stub mocked inside the utils-setup module's scope so the function under test sees it
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith { return $script:wslOutput }
        Mock -CommandName 'Show-LogContext' -ModuleName 'utils-setup' -MockWith { }
        Mock -CommandName 'Write-Host' -ModuleName 'utils-setup' -MockWith { }
        $script:wslOutput = (New-CheckDistroHashtable | ConvertTo-Json -Compress)
    }

    It 'returns parsed hashtable on happy path and sets phase to base-setup' {
        $rec = New-DistroRecord
        $result = Invoke-WslDistroCheck -Distro 'Ubuntu' -DistroRecord $rec
        $result | Should -BeOfType [hashtable]
        $result.user | Should -Be 'testuser'
        $result.uid | Should -Be 1000
        $rec.phase | Should -Be 'base-setup'
        $rec.error | Should -Be ''
    }

    It 'throws on JSON parse failure and populates DistroRecord.error' {
        $script:wslOutput = 'not valid json {'
        $rec = New-DistroRecord
        { Invoke-WslDistroCheck -Distro 'Ubuntu' -DistroRecord $rec } |
            Should -Throw "*distro check failed for 'Ubuntu'*"
        $rec.error | Should -Be 'distro check failed'
    }

    It 'returns $null and marks DistroRecord.error when distro is root with no profile' {
        $script:wslOutput = (New-CheckDistroHashtable -User 'root' -Uid 0 -Flags @{ def_uid = 0 } |
                ConvertTo-Json -Compress)
        $rec = New-DistroRecord
        $result = Invoke-WslDistroCheck -Distro 'RootOnly' -DistroRecord $rec
        $result | Should -BeNullOrEmpty
        $rec.error | Should -Be 'distro uses root user'
    }

    It 're-runs check after interactive setup when uid=0 but def_uid >= 1000' {
        $script:callCount = 0
        Mock -CommandName 'wsl.exe' -ModuleName 'utils-setup' -MockWith {
            $script:callCount++
            # 1st call: --exec check_distro.sh -> root output
            # 2nd call: --distribution Ubuntu (interactive setup) -> non-empty stdout
            # 3rd call: --exec check_distro.sh -> non-root output
            switch ($script:callCount) {
                1 { return (New-CheckDistroHashtable -User 'root' -Uid 0 -Flags @{ def_uid = 1000 } |
                            ConvertTo-Json -Compress) }
                2 { return 'pretend-this-is-wsl-interactive-output-from-the-distro-shell' }
                default { return (New-CheckDistroHashtable | ConvertTo-Json -Compress) }
            }
        }
        $rec = New-DistroRecord
        $result = Invoke-WslDistroCheck -Distro 'Ubuntu' -DistroRecord $rec
        # regression: pre-fix, the uncaptured `wsl.exe --distribution $Distro` polluted
        # the function's pipeline output and made $result an array @('output...', <hashtable>)
        # rather than just the hashtable. Subsequent calls like Resolve-WslDistroScopes
        # -Check $result then failed with "Cannot convert System.Object[] to Hashtable".
        $result | Should -BeOfType [hashtable]
        $result -is [array] | Should -Be $false
        $result.uid | Should -Be 1000
        $script:callCount | Should -Be 3
        $rec.phase | Should -Be 'base-setup'
    }
}
