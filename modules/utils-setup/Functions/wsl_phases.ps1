<#
.SYNOPSIS
Run check_distro.sh inside a WSL distro and return the parsed result.
.DESCRIPTION
Throws on JSON parse failure (orchestrator catches and exits). When the
distro defaults to root with a non-root profile available, prompts the user
to set up the profile interactively (matching the pre-refactor behavior),
then re-runs the check. When the distro is root-only with no profile, sets
DistroRecord.error and returns $null - caller treats $null as
"skip this distro and continue with the next".
.PARAMETER Distro
Name of the WSL distro to check.
.PARAMETER DistroRecord
Per-distro provenance hashtable. Mutated: phase = 'base-setup' on success,
error populated on the failure paths.
#>
function Invoke-WslDistroCheck {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [hashtable]$DistroRecord
    )

    $checkArgs = [string[]]@('-d', $Distro, '--exec', '.assets/check/check_distro.sh')
    $parseFailMsg = [string]::Join("`n",
        '',
        'The WSL seems to be not responding correctly. Run the script again!',
        'If the problem persists, run the wsl/wsl_restart.ps1 script as administrator and try again.'
    )

    $chkStr = wsl.exe @checkArgs
    try {
        $chk = $chkStr | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Show-LogContext $_
        Show-LogContext "Failed to check the distro '$Distro'." -Level WARNING
        Write-Host $parseFailMsg
        $DistroRecord.error = 'distro check failed'
        throw "distro check failed for '$Distro'"
    }

    if ($chk.uid -eq 0) {
        if ($chk.def_uid -ge 1000) {
            Write-Host "`nSetting up user profile in WSL distro. Type 'exit' when finished to proceed with WSL setup!`n" -ForegroundColor Yellow
            # interactive shell - Invoke-WslExe inherits stdin/stdout for typing + prompts
            Invoke-WslExe --distribution $Distro
            $chkStr = wsl.exe @checkArgs
            try {
                $chk = $chkStr | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } catch {
                Show-LogContext $_
                Show-LogContext "Failed to check the distro '$Distro'." -Level WARNING
                Write-Host $parseFailMsg
                $DistroRecord.error = 'distro check failed'
                throw "distro check failed for '$Distro' (after user setup)"
            }
        } else {
            $rootMsg = [string]::Join("`n",
                "`n`e[93;1mWARNING: The '$Distro' WSL distro is set to use the root user.`e[0m`n",
                'This setup requires the non-root user to be configured as the default one.',
                "`e[97;1mRun the script again after creating a non-root user profile.`e[0m"
            )
            Write-Host $rootMsg
            $DistroRecord.error = 'distro uses root user'
            return $null
        }
    }

    $DistroRecord.phase = 'base-setup'
    return $chk
}

<#
.SYNOPSIS
Run the WSL distro base setup: network check, SSL certificates, system
upgrade, nix bootstrap, autoexec installation, wsl.conf boot configuration.
.DESCRIPTION
Throws on persistent DNS or SSL failure (orchestrator catches and exits 1,
matching pre-refactor behavior). Returns a PSCustomObject with the
*effective* FixNetwork/AddCertificate values so the orchestrator can
update its $PSBoundParameters - both flags can be auto-promoted to true
when the corresponding probe initially failed.
.PARAMETER Distro
Name of the WSL distro.
.PARAMETER Check
Parsed check_distro.sh result (reads def_uid).
.PARAMETER FixNetwork
True if -FixNetwork was passed by the user (or auto-promoted by an earlier
probe). When false and the DNS probe fails, the function auto-promotes
the value, runs wsl_network_fix.ps1, and re-probes.
.PARAMETER AddCertificate
True if -AddCertificate was passed by the user (or auto-promoted earlier).
Same auto-promotion semantics as FixNetwork.
.PARAMETER DistroRecord
Per-distro provenance hashtable. Mutated: error populated on DNS/SSL
failure.
#>
function Invoke-WslBaseSetup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [hashtable]$Check,

        [bool]$FixNetwork,

        [bool]$AddCertificate,

        [Parameter(Mandatory)]
        [hashtable]$DistroRecord
    )

    # *fix WSL networking
    $dnsCheckArgs = [string[]]@('--distribution', $Distro, '--exec', '.assets/check/check_dns.sh')
    $dnsOk = wsl.exe @dnsCheckArgs
    if (-not $FixNetwork -and $dnsOk -eq 'false') {
        $FixNetwork = $true
    }
    if ($FixNetwork) {
        Show-LogContext 'fixing network'
        wsl/wsl_network_fix.ps1 $Distro | Out-Default
        $dnsOk = wsl.exe @dnsCheckArgs
    }
    if ($dnsOk -eq 'false') {
        $DistroRecord.error = 'DNS resolution failed'
        Show-LogContext 'DNS resolution failed. Cannot resolve github.com from WSL. Script execution halted.' -Level ERROR
        throw 'DNS resolution failed'
    }

    # *install certificates
    $sslCheckArgs = [string[]]@('--distribution', $Distro, '--user', 'root', '--exec', '.assets/check/check_ssl.sh')
    $sslOk = wsl.exe @sslCheckArgs
    if (-not $AddCertificate -and $sslOk -ne 'true') {
        $AddCertificate = $true
    }
    if ($AddCertificate) {
        Show-LogContext 'adding certificates in chain'
        wsl/wsl_certs_add.ps1 $Distro | Out-Default
        $sslOk = wsl.exe @sslCheckArgs
    }
    if ($sslOk -eq 'false') {
        $DistroRecord.error = 'SSL certificate verification failed'
        Show-LogContext 'SSL certificate problem: self-signed certificate in certificate chain. Script execution halted.' -Level ERROR
        throw 'SSL certificate verification failed'
    }

    # *install packages
    Show-LogContext 'updating system'
    $provisionScripts = [string[]]@(
        '.assets/fix/fix_no_file.sh',
        '.assets/fix/fix_secure_path.sh',
        '.assets/provision/upgrade_system.sh',
        '.assets/provision/install_base.sh',
        '.assets/provision/install_nix.sh'
    )
    foreach ($provisionScript in $provisionScripts) {
        Invoke-WslExe --distribution $Distro --user root --exec $provisionScript
    }

    # *boot setup
    Invoke-WslExe --distribution $Distro --user root install -m 0755 .assets/setup/autoexec.sh /etc
    # Compose the [boot] command. Prefix with `systemctl start
    # user-runtime-dir@<def_uid>.service` to materialize /run/user/<def_uid> at
    # WSL boot. WSL's bash entry doesn't fire pam_systemd, so logind never
    # spawns the user runtime dir on its own; on Fedora and other distros that
    # ship pam_systemd only in PAM stacks WSL doesn't traverse, anything that
    # needs XDG_RUNTIME_DIR (fnm, dbus user-session, ...) breaks on every shell
    # start. Guarded with `command -v systemctl` so non-systemd boots no-op,
    # and stderr piped to /dev/null so the line is silent on distros where the
    # unit isn't applicable. Always re-written so existing wsl.conf gets the
    # new prefix on the next setup run.
    $bootCmdValue = "command -v systemctl >/dev/null 2>&1 && systemctl start user-runtime-dir@$($Check.def_uid).service 2>/dev/null; [ -x /etc/autoexec.sh ] && /etc/autoexec.sh || true"
    $bootConf = [ordered]@{
        boot = @{ command = "`"$bootCmdValue`"" }
    }
    Set-WslConf -Distro $Distro -ConfDict $bootConf | Out-Default

    return [pscustomobject]@{
        FixNetwork     = $FixNetwork
        AddCertificate = $AddCertificate
    }
}

<#
.SYNOPSIS
Pre-populate the GitHub CLI config inside a WSL distro from supplied lines.
.DESCRIPTION
Writes ~/.config/gh/hosts.yml inside the distro using a heredoc with a
GHEOF marker. No-op when GhConfig is empty / null or doesn't contain a
github.com reference (matching the pre-refactor `-match 'github\.com'` guard).
.PARAMETER Distro
Name of the WSL distro.
.PARAMETER GhConfig
Lines from a hosts.yml file (typically pulled from another distro's
~/.config/gh/hosts.yml). When empty/null/non-github, the function returns
without invoking wsl.exe.
#>
function Sync-WslGitHubConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$GhConfig
    )

    if (-not $GhConfig -or -not ($GhConfig -match 'github\.com')) {
        return
    }

    Show-LogContext 'pre-populating GitHub CLI config'
    $cmnd = [string]::Join("`n",
        'mkdir -p $HOME/.config/gh',
        "cat > `$HOME/.config/gh/hosts.yml << 'GHEOF'",
        ($GhConfig -join "`n"),
        'GHEOF'
    )
    wsl.exe --distribution $Distro --exec bash -c $cmnd
}

<#
.SYNOPSIS
Sync the id_ed25519 SSH key pair between Windows ~/.ssh and a WSL distro.
.DESCRIPTION
Three transfer scenarios:
- Windows has the pair, WSL doesn't        -> copy Windows -> WSL via `install`
- Neither side has it                       -> generate inside WSL via setup_ssh.sh, then copy WSL -> Windows
- WSL has it, Windows doesn't              -> copy WSL -> Windows (no generation)
- Both sides have it                        -> no-op
.PARAMETER Distro
Name of the WSL distro.
.PARAMETER HasWslKey
True when check_distro.sh reported ssh_key=true (key already in WSL).
#>
function Sync-WslSshKeys {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [bool]$HasWslKey
    )

    $sshKey = 'id_ed25519'
    $sshDir = [System.IO.Path]::Combine($HOME, '.ssh')
    $winKey = [System.IO.Path]::Combine($sshDir, $sshKey)
    $winKeyPub = [System.IO.Path]::Combine($sshDir, "$sshKey.pub")
    $sshWinPath = "/mnt/$($env:HOMEDRIVE.Replace(':', '').ToLower())$($env:HOMEPATH.Replace('\', '/'))/.ssh"

    $winKeyExists = (Test-Path -Path $winKey) -and (Test-Path -Path $winKeyPub)

    if (-not $HasWslKey -and $winKeyExists) {
        # Windows -> WSL
        $cmnd = [string]::Join("`n",
            'mkdir -p $HOME/.ssh',
            "install -m 0600 '$sshWinPath/$sshKey' `$HOME/.ssh",
            "install -m 0644 '$sshWinPath/$sshKey.pub' `$HOME/.ssh"
        )
        wsl.exe --distribution $Distro --exec sh -c $cmnd
        return
    }

    if (-not $winKeyExists) {
        # WSL -> Windows (with optional generation when WSL also lacks the key)
        if (Test-Path -Path $sshDir) {
            Remove-Item -Path $winKey, $winKeyPub -ErrorAction SilentlyContinue
        } else {
            New-Item -Path $sshDir -ItemType Directory | Out-Null
        }
        $copyCmnd = [string]::Join("`n",
            '# copy SSH key to Windows',
            "cp `"`$HOME/.ssh/$sshKey`" $sshWinPath/$sshKey",
            "cp `"`$HOME/.ssh/$sshKey.pub`" $sshWinPath/$sshKey.pub"
        )
        $cmnd = if (-not $HasWslKey) {
            [string]::Join("`n",
                '# generate SSH key if missing',
                '.assets/setup/setup_ssh.sh',
                $copyCmnd
            )
        } else {
            $copyCmnd
        }
        wsl.exe --distribution $Distro --exec sh -c $cmnd
    }
}

<#
.SYNOPSIS
Install scope-specific packages: docker (WSL2 system-wide), zsh (system-wide),
nix/setup.sh (user-scope, all listed scopes), distrobox (WSL2 system-wide),
pwsh (Windows User-scope env vars on first install).
.DESCRIPTION
Returns a [pscustomobject] with Success ($true if nix/setup.sh exited 0),
SshKeyFp (captured after the first successful nix/setup.sh, may be empty),
and PwshEnvSet (false after first pwsh setup so subsequent distros skip
the env-var write).
.PARAMETER Distro
Name of the WSL distro.
.PARAMETER Scopes
Sorted, dependency-resolved scope list from Resolve-WslDistroScopes.
.PARAMETER Check
Parsed check_distro.sh result (reads systemd, user).
.PARAMETER WslVersion
1 or 2. docker / distrobox are WSL2-only.
.PARAMETER SshKeyFp
Current SSH key fingerprint - empty before first successful setup, used to
populate $env:NX_SSH_KEY_FP/$env:WSLENV before nix/setup.sh runs.
.PARAMETER PwshEnvSet
True if the Windows User-scope env vars haven't been written yet.
.PARAMETER OmpTheme
Optional --omp-theme value forwarded to nix/setup.sh.
.PARAMETER SkipModulesUpdate
True if -SkipModulesUpdate was passed (suppresses --update-modules).
.PARAMETER DistroRecord
Per-distro provenance hashtable. Mutated: error populated if nix/setup.sh
fails.
#>
function Install-WslScopes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Scopes,

        [Parameter(Mandatory)]
        [hashtable]$Check,

        [Parameter(Mandatory)]
        [int]$WslVersion,

        [string]$SshKeyFp,

        [Parameter(Mandatory)]
        [bool]$PwshEnvSet,

        [string]$OmpTheme,

        [bool]$SkipModulesUpdate,

        [Parameter(Mandatory)]
        [hashtable]$DistroRecord
    )

    # -- docker: WSL2-only system-wide systemd + traditional install --
    if ('docker' -in $Scopes -and $WslVersion -eq 2) {
        Show-LogContext 'installing docker'
        if (-not $Check.systemd) {
            wsl/wsl_systemd.ps1 $Distro -Systemd 'true' | Out-Default
            Invoke-WslExe --shutdown
        }
        Invoke-WslExe --distribution $Distro --user root --exec .assets/provision/install_docker.sh $Check.user
    }

    # -- zsh: system-wide install (login shell requires /etc/shells entry) --
    if ('zsh' -in $Scopes) {
        Show-LogContext 'installing zsh system-wide'
        Invoke-WslExe --distribution $Distro --user root --exec .assets/provision/install_zsh.sh
    }

    # -- build nix/setup.sh argument list (splatted into wsl.exe call) --
    # --skip-repo-update: wsl_setup.ps1 already refreshed the repo via
    # Update-GitRepository at script start; the nix path's auto-refresh
    # would be a wasted ls-remote round-trip on the WSL side
    $nixArgs = [System.Collections.Generic.List[string]]::new(
        [string[]]@('--unattended', '--skip-repo-update', '--quiet-summary')
    )
    if (-not $SkipModulesUpdate) {
        $nixArgs.Add('--update-modules')
    }
    # map scopes to nix flags (exclude distrobox/docker - installed system-wide;
    # oh_my_posh/starship - handled via --omp-theme/--starship-theme)
    $nixSkipScopes = [string[]]@('distrobox', 'docker', 'oh_my_posh', 'starship')
    foreach ($sc in $Scopes) {
        if ($sc -notin $nixSkipScopes) {
            $nixArgs.Add("--$($sc -replace '_', '-')")
        }
    }
    if ($OmpTheme) {
        $nixArgs.AddRange([string[]]@('--omp-theme', $OmpTheme))
    }

    # -- run nix setup (packages + configure scripts + profiles) --
    Show-LogContext 'running nix setup'
    if ($SshKeyFp -and $env:NX_SSH_KEY_FP -ne $SshKeyFp) {
        $env:WSLENV = "${env:WSLENV}:NX_SSH_KEY_FP/u"
        $env:NX_SSH_KEY_FP = $SshKeyFp
    }
    Invoke-WslExe --distribution $Distro --exec nix/setup.sh @nixArgs
    if ($LASTEXITCODE -ne 0) {
        Show-LogContext 'nix/setup.sh failed' -Level ERROR
        $DistroRecord.error = 'nix/setup.sh failed'
        return [pscustomobject]@{
            Success    = $false
            SshKeyFp   = $SshKeyFp
            PwshEnvSet = $PwshEnvSet
        }
    }

    # capture SSH key fingerprint after first successful setup
    $winKeyPub = [System.IO.Path]::Combine($HOME, '.ssh', 'id_ed25519.pub')
    if (-not $SshKeyFp -and (Test-Path -Path $winKeyPub)) {
        $SshKeyFp = (Get-Content -Path $winKeyPub).Split(' ')[1]
    }

    # -- distrobox: WSL2-only system-wide --
    if ('distrobox' -in $Scopes -and $WslVersion -eq 2) {
        Show-LogContext 'installing distrobox'
        Invoke-WslExe --distribution $Distro --user root --exec .assets/provision/install_podman.sh
        Invoke-WslExe --distribution $Distro --user root --exec .assets/provision/install_distrobox.sh $Check.user
    }

    # -- pwsh: Windows User-scope env vars (one-shot per script run) --
    if ('pwsh' -in $Scopes -and $PwshEnvSet) {
        $pwshEnvVars = [ordered]@{
            POWERSHELL_TELEMETRY_OPTOUT = '1'
            POWERSHELL_UPDATECHECK      = 'Off'
        }
        foreach ($key in $pwshEnvVars.Keys) {
            if ([System.Environment]::GetEnvironmentVariable($key, 'User') -ne $pwshEnvVars[$key]) {
                [System.Environment]::SetEnvironmentVariable($key, $pwshEnvVars[$key], 'User')
            }
            $userWslEnv = [System.Environment]::GetEnvironmentVariable('WSLENV', 'User')
            if ($userWslEnv -notmatch "\b$key\b") {
                [System.Environment]::SetEnvironmentVariable(
                    'WSLENV',
                    "${userWslEnv}$($userWslEnv ? ':' : '')${key}/u",
                    'User'
                )
            }
        }
        $PwshEnvSet = $false
    }

    return [pscustomobject]@{
        Success    = $true
        SshKeyFp   = $SshKeyFp
        PwshEnvSet = $PwshEnvSet
    }
}

<#
.SYNOPSIS
Set the GTK theme for WSLg apps via /etc/profile.d/gtk_theme.sh.
.DESCRIPTION
WSLg-specific (WSL2 + wslg=true). When the requested theme matches the
already-installed gtkd state, the function is a no-op. The pre-refactor
behavior is preserved exactly: light + gtkd=true -> Adwaita, dark +
gtkd=false -> Adwaita:dark; the two off-diagonal cases skip the write.
.PARAMETER Distro
Name of the WSL distro.
.PARAMETER Check
Parsed check_distro.sh result (reads wslg, gtkd).
.PARAMETER WslVersion
1 or 2. WSLg is WSL2-only; WSL1 is a no-op.
.PARAMETER GtkTheme
'light' or 'dark'.
#>
function Set-WslGtkTheme {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [hashtable]$Check,

        [Parameter(Mandatory)]
        [int]$WslVersion,

        [Parameter(Mandatory)]
        [ValidateSet('light', 'dark')]
        [string]$GtkTheme
    )

    if ($WslVersion -ne 2 -or -not $Check.wslg) {
        return
    }

    $themeValue = if ($GtkTheme -eq 'light') {
        $Check.gtkd ? '"Adwaita"' : $null
    } else {
        $Check.gtkd ? $null : '"Adwaita:dark"'
    }

    if (-not $themeValue) {
        return
    }

    Show-LogContext "setting `e[3m$GtkTheme`e[23m gtk theme"
    $cmnd = "echo 'export GTK_THEME=$themeValue' >/etc/profile.d/gtk_theme.sh"
    wsl.exe --distribution $Distro --user root -- bash -c $cmnd
}

<#
.SYNOPSIS
Configure git user.name / user.email inside a WSL distro.
.DESCRIPTION
Resolves missing values from the Windows host (Get-LocalUser, ADSI/LDAP,
HKCU IdentityCRL) and prompts the user via Read-Host when no source
yields a value. Writes the resolved values to git global on the Windows
host so subsequent distros pick them up without prompting. No-op when
both Check.git_user and Check.git_email are already true.
.PARAMETER Distro
Name of the WSL distro.
.PARAMETER Check
Parsed check_distro.sh result (reads git_user, git_email).
#>
function Set-WslGitConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [hashtable]$Check
    )

    if ($Check.git_user -and $Check.git_email) {
        return
    }

    $builder = [System.Text.StringBuilder]::new()
    $builder.AppendLine('. /etc/profile.d/nix.sh 2>/dev/null') | Out-Null

    if (-not $Check.git_user) {
        $user = git config --global --get user.name
        if (-not $user) {
            $user = try {
                Get-LocalUser -Name $env:USERNAME | Select-Object -ExpandProperty FullName
            } catch {
                try {
                    [string[]]$userArr = ([ADSI]"LDAP://$(WHOAMI /FQDN 2>$null)").displayName.Split(',').Trim()
                    if ($userArr.Count -gt 1) { [array]::Reverse($userArr) }
                    "$userArr"
                } catch {
                    ''
                }
            }
            while (-not $user) {
                $user = Read-Host -Prompt 'provide git user name'
            }
            git config --global user.name "$user"
        }
        # escape single quotes for the bash single-quoted context: end the
        # quoted string, emit an escaped quote, restart the quoted string.
        # Handles names like O'Connor without breaking the bash command.
        $userEsc = $user.Replace("'", "'\''")
        $builder.AppendLine("git config --global user.name '$userEsc'") | Out-Null
    }

    if (-not $Check.git_email) {
        $email = git config --global --get user.email
        if (-not $email) {
            $email = try {
                (Get-ChildItem -Path 'HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties').PSChildName
            } catch {
                try {
                    ([ADSI]"LDAP://$(WHOAMI /FQDN 2>$null)").mail
                } catch {
                    ''
                }
            }
            while ($email -notmatch '.+@.+') {
                $email = Read-Host -Prompt 'provide git user email'
            }
            git config --global user.email "$email"
        }
        $emailEsc = $email.Replace("'", "'\''")
        $builder.AppendLine("git config --global user.email '$emailEsc'") | Out-Null
    }

    $extraSettings = [string[]]@(
        'git config --global core.eol lf',
        'git config --global core.autocrlf input',
        'git config --global core.longpaths true',
        'git config --global push.autoSetupRemote true'
    )
    $extraSettings.ForEach({ $builder.AppendLine($_) | Out-Null })

    $cmnd = $builder.ToString().Trim() -replace "`r"
    Show-LogContext 'configuring git'
    wsl.exe --distribution $Distro --exec bash -c $cmnd
}

<#
.SYNOPSIS
Compute the final, sorted, dependency-resolved scope list for a WSL distro.
.DESCRIPTION
Combines the user-supplied -Scope array with scopes auto-detected from the
distro check (az/bun/conda/gcloud/k8s_*/pwsh/python/shell/terraform), applies
the -OmpTheme implicit dependency on WSL2 only, resolves implicit
dependencies via Resolve-ScopeDeps, strips WSL1-incompatible scopes
(distrobox/docker/k8s_ext/oh_my_posh), and returns the result sorted by the
shared install order. Mutates DistroRecord.scopes with the resolved list.
.PARAMETER Scope
User-supplied scope array (typically the script's -Scope parameter). Null
and empty arrays are both accepted - the result still includes any scopes
auto-detected from the distro check.
.PARAMETER Check
Parsed check_distro.sh result hashtable.
.PARAMETER WslVersion
1 or 2. Drives WSL1 scope strip and the OmpTheme guard.
.PARAMETER OmpTheme
If non-empty on WSL2, augments scope set via Resolve-ScopeDeps. Ignored on
WSL1.
.PARAMETER DistroRecord
Per-distro provenance hashtable. Mutated: scopes field populated with the
resolved sorted list.
#>
function Resolve-WslDistroScopes {
    [CmdletBinding()]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Scope = @(),

        [Parameter(Mandatory)]
        [hashtable]$Check,

        [Parameter(Mandatory)]
        [int]$WslVersion,

        [string]$OmpTheme,

        [Parameter(Mandatory)]
        [hashtable]$DistroRecord
    )

    $scopeSet = [System.Collections.Generic.HashSet[string]]::new()
    [string[]]$inputScopes = $Scope ?? @()
    $inputScopes.ForEach({ $scopeSet.Add($_) | Out-Null })

    # *augment from distro check
    $autoScopeKeys = [string[]]@(
        'az', 'bun', 'conda', 'gcloud',
        'k8s_base', 'k8s_dev', 'k8s_ext',
        'pwsh', 'python', 'shell', 'terraform'
    )
    foreach ($key in $autoScopeKeys) {
        if ($Check.$key) {
            $scopeSet.Add($key) | Out-Null
        }
    }

    # *resolve implicit dependencies (omp resolution mirrors the inline ternary)
    $resolveOmp = if ($WslVersion -eq 2 -and ($Check.oh_my_posh -or $OmpTheme)) {
        $OmpTheme ? $OmpTheme : 'detect'
    } else {
        ''
    }
    Resolve-ScopeDeps -ScopeSet $scopeSet -OmpTheme $resolveOmp

    # *strip WSL1-incompatible scopes
    if ($WslVersion -eq 1) {
        $wsl1Strip = [string[]]@('distrobox', 'docker', 'k8s_ext', 'oh_my_posh')
        $wsl1Strip.ForEach({ $scopeSet.Remove($_) | Out-Null })
    }

    [string[]]$sorted = Get-SortedScopes -ScopeSet $scopeSet
    $DistroRecord.scopes = $sorted
    return $sorted
}
