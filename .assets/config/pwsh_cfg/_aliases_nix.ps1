#region common aliases
function cd.. { Set-Location ../ }
function .. { Set-Location ../ }
function ... { Set-Location ../../ }
function .... { Set-Location ../../../ }
function la { Get-ChildItem @args -Force }

Set-Alias -Name c -Value Clear-Host
Set-Alias -Name type -Value Get-Command
#endregion

#region platform aliases
if ($IsLinux) {
    if ($env:DISTRO_FAMILY -eq 'alpine') {
        function bsh { & /usr/bin/env -i ash --noprofile --norc }
        function ls { & /usr/bin/env ls -h --color=auto --group-directories-first @args }
    } else {
        function bsh { & /usr/bin/env -i bash --noprofile --norc }
        function ip { $input | & /usr/bin/env ip --color=auto @args }
        function ls { & /usr/bin/env ls -h --color=auto --group-directories-first --time-style=long-iso @args }
    }
} elseif ($IsMacOS) {
    function bsh { & /usr/bin/env -i bash --noprofile --norc }
}
function grep { $input | & /usr/bin/env grep --ignore-case --color=auto @args }
function less { $input | & /usr/bin/env less -FRXc @args }
function mkdir { & /usr/bin/env mkdir -pv @args }
function mv { & /usr/bin/env mv -iv @args }
function nano { & /usr/bin/env nano -W @args }
function tree { & /usr/bin/env tree -C @args }
function wget { & /usr/bin/env wget -c @args }

Set-Alias -Name rd -Value rmdir
Set-Alias -Name vi -Value vim
#endregion

#region dev tool aliases
$_nb = "$HOME/.nix-profile/bin"

if (Test-Path "$_nb/eza" -PathType Leaf) {
    function eza { & /usr/bin/env eza -g --color=auto --time-style=long-iso --group-directories-first --color-scale=all --git-repos @args }
    function l { eza -1 @args }
    function lsa { eza -a @args }
    function ll { eza -lah @args }
    function lt { eza -Th @args }
    function lta { eza -aTh --git-ignore @args }
    function ltd { eza -DTh @args }
    function ltad { eza -aDTh --git-ignore @args }
    function llt { eza -lTh @args }
    function llta { eza -laTh --git-ignore @args }
} else {
    function l { ls -1 @args }
    function lsa { ls -a @args }
    function ll { ls -lah @args }
}
if (Test-Path "$_nb/rg" -PathType Leaf) {
    function rg { $input | & /usr/bin/env rg --ignore-case @args }
}
if (Test-Path "$_nb/bat" -PathType Leaf) {
    function batp { $input | & /usr/bin/env bat -pP @args }
}
if (Test-Path "$_nb/fastfetch" -PathType Leaf) {
    Set-Alias -Name ff -Value fastfetch
}
if (Test-Path "$_nb/pwsh" -PathType Leaf) {
    function p { & /usr/bin/env pwsh -NoProfileLoadTime @args }
}
if (Test-Path "$_nb/kubectx" -PathType Leaf) {
    Set-Alias -Name kc -Value kubectx
}
if (Test-Path "$_nb/kubens" -PathType Leaf) {
    Set-Alias -Name kn -Value kubens
}
if (Test-Path "$_nb/kubecolor" -PathType Leaf) {
    Set-Alias -Name kubectl -Value kubecolor
}

Remove-Variable _nb
#endregion

#region PowerShell profile management helpers
function _NxShortPath([string]$Path) {
    $Path.Replace([Environment]::GetFolderPath('UserProfile'), '~')
}

function _NxProfileHelp {
    Write-Host @"
Usage: nx profile <command>

Commands:
  doctor          Check PowerShell profile health
  regenerate      Regenerate managed regions in PowerShell profile
  uninstall       Remove managed regions from PowerShell profile
  help            Show this help
"@
}

function _NxUpdateProfileRegion {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$RegionName,
        [string[]]$Content
    )
    $startTag = "#region $RegionName"
    $endTag = '#endregion'
    $startIdx = ($Lines | Select-String $startTag -SimpleMatch).LineNumber
    if ($startIdx) {
        $endIdx = ($Lines | Select-String $endTag -SimpleMatch |
            Where-Object LineNumber -GE $startIdx | Select-Object -First 1).LineNumber
        if ($endIdx) {
            $existing = $Lines[($startIdx - 1)..($endIdx - 1)] -join "`n"
            if ($existing -eq ($Content -join "`n")) {
                return $false
            }
            $removeFrom = $startIdx - 1
            while ($removeFrom -gt 0 -and [string]::IsNullOrWhiteSpace($Lines[$removeFrom - 1])) {
                $removeFrom--
            }
            $Lines.RemoveRange($removeFrom, $endIdx - $removeFrom)
            $Lines.Add('')
            $Lines.AddRange([string[]]$Content)
            return $true
        }
    }
    $Lines.Add('')
    $Lines.AddRange([string[]]$Content)
    return $true
}

function _NxRemoveProfileRegion {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$RegionName
    )
    $startTag = "#region $RegionName"
    $endTag = '#endregion'
    $startIdx = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].TrimEnd() -eq $startTag) { $startIdx = $i; break }
    }
    if ($null -eq $startIdx) { return $false }
    $endIdx = $null
    for ($i = $startIdx + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].TrimEnd() -eq $endTag) { $endIdx = $i; break }
    }
    if ($null -eq $endIdx) { return $false }
    $removeFrom = $startIdx
    while ($removeFrom -gt 0 -and [string]::IsNullOrWhiteSpace($Lines[$removeFrom - 1])) {
        $removeFrom--
    }
    $Lines.RemoveRange($removeFrom, $endIdx - $removeFrom + 1)
    return $true
}

function _NxProfileRegenerate {
    $nixBin = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.nix-profile/bin')
    $envDir = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.config/nix-env')

    # --- CurrentUserAllHosts profile ---
    $profilePath = $PROFILE.CurrentUserAllHosts
    $shortPath = _NxShortPath $profilePath
    Write-Host "`e[96mRegenerating $shortPath`e[0m"
    $profileDir = [IO.Path]::GetDirectoryName($profilePath)
    if (-not [IO.Directory]::Exists($profileDir)) {
        [IO.Directory]::CreateDirectory($profileDir) | Out-Null
    }
    $profileContent = [System.Collections.Generic.List[string]]::new()
    if ([IO.File]::Exists($profilePath)) {
        $profileContent.AddRange([IO.File]::ReadAllLines($profilePath))
    }

    # Migration: remove old region names (before nix: prefix convention)
    foreach ($oldRegion in @('base', 'nix', 'oh-my-posh', 'starship', 'uv', 'local-path')) {
        if (_NxRemoveProfileRegion -Lines $profileContent -RegionName $oldRegion) {
            Write-Host "`e[33m  migrated old region '$oldRegion'`e[0m"
        }
    }

    # -- nix:base - profile dot-source ---
    $baseRegion = [string[]]@(
        '#region nix:base'
        'if (Test-Path "$HOME/.config/nix-env/profile_base.ps1" -PathType Leaf) { . "$HOME/.config/nix-env/profile_base.ps1" }'
        '#endregion'
    )
    if (_NxUpdateProfileRegion -Lines $profileContent -RegionName 'nix:base' -Content $baseRegion) {
        Write-Host "`e[32m  updated nix:base`e[0m"
    }

    # -- nix:path - nix PATH ---
    # nix-installed pwsh has no /etc/profile.d/ integration (system pwsh does),
    # so two PowerShell user dirs never land on PATH on their own. Append both:
    #   - Scripts: where Install-PSResource -Type Script lands .ps1 files; needed
    #     for them to be invokable as commands.
    #   - Modules: PSResourceGet's "ScriptPATHWarning" check (incorrectly) probes
    #     this path on Linux. Adding it silences a noisy WARNING on every install.
    $nixRegion = [string[]]@(
        '#region nix:path'
        'foreach ($nixPath in @(''/nix/var/nix/profiles/default/bin'', [IO.Path]::Combine([Environment]::GetFolderPath(''UserProfile''), ''.nix-profile/bin''))) {'
        '    if ([IO.Directory]::Exists($nixPath) -and $nixPath -notin $env:PATH.Split([IO.Path]::PathSeparator)) {'
        '        [Environment]::SetEnvironmentVariable(''PATH'', [string]::Join([IO.Path]::PathSeparator, $nixPath, $env:PATH))'
        '    }'
        '}'
        'foreach ($psUserDir in @(''.local/share/powershell/Scripts'', ''.local/share/powershell/Modules'')) {'
        '    $abs = [IO.Path]::Combine([Environment]::GetFolderPath(''UserProfile''), $psUserDir)'
        '    if ([IO.Directory]::Exists($abs) -and $abs -notin $env:PATH.Split([IO.Path]::PathSeparator)) {'
        '        [Environment]::SetEnvironmentVariable(''PATH'', [string]::Join([IO.Path]::PathSeparator, $env:PATH, $abs))'
        '    }'
        '}'
        'if ($env:LD_LIBRARY_PATH) { $env:LD_LIBRARY_PATH = $null }'
        '#endregion'
    )
    if (_NxUpdateProfileRegion -Lines $profileContent -RegionName 'nix:path' -Content $nixRegion) {
        Write-Host "`e[32m  updated nix:path`e[0m"
    }

    # -- nix:certs - override NIX_SSL_CERT_FILE with merged CA bundle ---
    $caBundlePath = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.config/certs/ca-bundle.crt')
    if ([IO.File]::Exists($caBundlePath)) {
        $certsRegion = [string[]]@(
            '#region nix:certs'
            '$caBundlePath = [IO.Path]::Combine([Environment]::GetFolderPath(''UserProfile''), ''.config/certs/ca-bundle.crt'')'
            'if ([IO.File]::Exists($caBundlePath)) { $env:NIX_SSL_CERT_FILE = $caBundlePath }'
            '#endregion'
        )
        if (_NxUpdateProfileRegion -Lines $profileContent -RegionName 'nix:certs' -Content $certsRegion) {
            Write-Host "`e[32m  updated nix:certs`e[0m"
        }
    }

    # -- nix:starship - starship prompt ---
    $nixBinStarship = [IO.Path]::Combine($nixBin, 'starship')
    if ([IO.File]::Exists($nixBinStarship)) {
        $starshipRegion = [string[]]@(
            '#region nix:starship'
            'if (Test-Path "$HOME/.nix-profile/bin/starship" -PathType Leaf) { (& "$HOME/.nix-profile/bin/starship" init powershell) | Out-String | Invoke-Expression }'
            '#endregion'
        )
        if (_NxUpdateProfileRegion -Lines $profileContent -RegionName 'nix:starship' -Content $starshipRegion) {
            Write-Host "`e[32m  updated nix:starship`e[0m"
        }
    }

    # -- nix:oh-my-posh - oh-my-posh prompt ---
    $nixBinOmp = [IO.Path]::Combine($nixBin, 'oh-my-posh')
    $ompTheme = [IO.Path]::Combine($envDir, 'omp/theme.omp.json')
    if ([IO.File]::Exists($nixBinOmp) -and [IO.File]::Exists($ompTheme)) {
        $ompRegion = [string[]]@(
            '#region nix:oh-my-posh'
            'if (Test-Path "$HOME/.nix-profile/bin/oh-my-posh" -PathType Leaf) {'
            '    (& "$HOME/.nix-profile/bin/oh-my-posh" init pwsh --config "$HOME/.config/nix-env/omp/theme.omp.json") | Out-String | Invoke-Expression'
            '    [Environment]::SetEnvironmentVariable(''VIRTUAL_ENV_DISABLE_PROMPT'', $true)'
            '}'
            '#endregion'
        )
        if (_NxUpdateProfileRegion -Lines $profileContent -RegionName 'nix:oh-my-posh' -Content $ompRegion) {
            Write-Host "`e[32m  updated nix:oh-my-posh`e[0m"
        }
    }

    # -- nix:uv - uv / uvx completion ---
    $nixBinUv = [IO.Path]::Combine($nixBin, 'uv')
    if ([IO.File]::Exists($nixBinUv)) {
        $uvRegion = [string[]]@(
            '#region nix:uv'
            'if (Test-Path "$HOME/.nix-profile/bin/uv" -PathType Leaf) {'
            '    $env:UV_SYSTEM_CERTS = ''true'''
            '    (& "$HOME/.nix-profile/bin/uv" generate-shell-completion powershell) | Out-String | Invoke-Expression'
            '    (& "$HOME/.nix-profile/bin/uvx" --generate-shell-completion powershell) | Out-String | Invoke-Expression'
            '}'
            '#endregion'
        )
        if (_NxUpdateProfileRegion -Lines $profileContent -RegionName 'nix:uv' -Content $uvRegion) {
            Write-Host "`e[32m  updated nix:uv`e[0m"
        }
    }

    # -- nix:fnm - fnm node version manager ---
    # nix installs fnm; fnm owns the runtime. The eval line wires `fnm env` so
    # node/npm land on PATH and per-project `.nvmrc` switching activates on cd.
    $nixBinFnm = [IO.Path]::Combine($nixBin, 'fnm')
    if ([IO.File]::Exists($nixBinFnm)) {
        $fnmRegion = [string[]]@(
            '#region nix:fnm'
            'if (Test-Path "$HOME/.nix-profile/bin/fnm" -PathType Leaf) {'
            '    (& "$HOME/.nix-profile/bin/fnm" env --use-on-cd --shell power-shell) | Out-String | Invoke-Expression'
            '}'
            '#endregion'
        )
        if (_NxUpdateProfileRegion -Lines $profileContent -RegionName 'nix:fnm' -Content $fnmRegion) {
            Write-Host "`e[32m  updated nix:fnm`e[0m"
        }
    }

    # Save CurrentUserAllHosts profile
    [IO.File]::WriteAllText(
        $profilePath,
        "$(($profileContent -join "`n").Trim())`n"
    )

    # --- kubectl completion - CurrentUserCurrentHost ---
    $kubectlBin = [IO.Path]::Combine($nixBin, 'kubectl')
    if ([IO.File]::Exists($kubectlBin)) {
        $kubectlProfilePath = $PROFILE.CurrentUserCurrentHost
        $kubectlContent = [System.Collections.Generic.List[string]]::new()
        if ([IO.File]::Exists($kubectlProfilePath)) {
            $kubectlContent.AddRange([IO.File]::ReadAllLines($kubectlProfilePath))
        }
        $kubectlShortPath = _NxShortPath $kubectlProfilePath
        # migration: remove old region name
        if (_NxRemoveProfileRegion -Lines $kubectlContent -RegionName 'kubectl completer') {
            Write-Host "`e[33m  migrated old region 'kubectl completer'`e[0m"
        }
        $kubectlRegion = [string[]]@(
            '#region nix:kubectl'
            (& $kubectlBin completion powershell) -join "`n"
            ''
            '# setup autocompletion for the k alias'
            'Set-Alias -Name k -Value kubectl'
            "Register-ArgumentCompleter -CommandName 'k' -ScriptBlock `${__kubectlCompleterBlock}"
            ''
            '# setup autocompletion for kubecolor'
            'if (Test-Path "$HOME/.nix-profile/bin/kubecolor" -PathType Leaf) {'
            '    Set-Alias -Name kubectl -Value kubecolor'
            "    Register-ArgumentCompleter -CommandName 'kubecolor' -ScriptBlock `${__kubectlCompleterBlock}"
            '}'
            '#endregion'
        )
        if (_NxUpdateProfileRegion -Lines $kubectlContent -RegionName 'nix:kubectl' -Content $kubectlRegion) {
            Write-Host "`e[96mRegenerating $kubectlShortPath`e[0m"
            Write-Host "`e[32m  updated nix:kubectl`e[0m"
            [IO.File]::WriteAllText(
                $kubectlProfilePath,
                "$(($kubectlContent -join "`n").Trim())`n"
            )
        }
    }

    Write-Host "`e[32mProfile regeneration complete`e[0m"
}

function _NxProfileDoctor {
    $ok = $true

    $profilePath = $PROFILE.CurrentUserAllHosts
    $shortPath = _NxShortPath $profilePath
    if (-not [IO.File]::Exists($profilePath)) {
        Write-Host "`e[33m[warn] no profile found at $shortPath`e[0m"
        return
    }
    Write-Host "`e[96mChecking $shortPath`e[0m"
    $content = [IO.File]::ReadAllText($profilePath)

    # Check for old region names that should have been migrated
    foreach ($oldRegion in @('base', 'nix', 'oh-my-posh', 'starship', 'uv', 'kubectl completer')) {
        if ($content -match "#region $([regex]::Escape($oldRegion))`r?`n") {
            Write-Host "`e[33m  [warn] old region '$oldRegion' found - run: nx profile migrate`e[0m"
            $ok = $false
        }
    }

    # Check for expected regions
    foreach ($region in @('nix:base', 'nix:path')) {
        if ($content -notmatch "#region $([regex]::Escape($region))`r?`n") {
            Write-Host "`e[33m  [warn] expected region '$region' not found - run: nx profile regenerate`e[0m"
            $ok = $false
        }
    }

    if ($ok) {
        Write-Host "`e[32m  [ok] profile looks healthy`e[0m"
    }
}

#endregion

function _NxProfileUninstall {
    # Remove all nix-managed regions from the user's PowerShell profiles.
    # Mirrors the bash `nx profile uninstall` (which removes the managed
    # blocks from .bashrc / .zshrc) - same surface, different file format.
    $profilePath = $PROFILE.CurrentUserAllHosts
    $shortPath = _NxShortPath $profilePath
    if ([IO.File]::Exists($profilePath)) {
        Write-Host "`e[96mCleaning $shortPath`e[0m"
        $content = [System.Collections.Generic.List[string]]::new(
            [IO.File]::ReadAllLines($profilePath)
        )
        foreach ($region in @('nix:base', 'nix:path', 'nix:certs', 'nix:starship',
                'nix:oh-my-posh', 'nix:uv', 'nix:fnm', 'local-path')) {
            _NxRemoveProfileRegion -Lines $content -RegionName $region | Out-Null
        }
        [IO.File]::WriteAllText($profilePath, "$(($content -join "`n").Trim())`n")
        Write-Host "`e[32m  removed managed regions`e[0m"
    }
    $kubectlProfilePath = $PROFILE.CurrentUserCurrentHost
    $kubectlShortPath = _NxShortPath $kubectlProfilePath
    if ([IO.File]::Exists($kubectlProfilePath)) {
        $kContent = [System.Collections.Generic.List[string]]::new(
            [IO.File]::ReadAllLines($kubectlProfilePath)
        )
        if (_NxRemoveProfileRegion -Lines $kContent -RegionName 'nix:kubectl') {
            Write-Host "`e[96mCleaning $kubectlShortPath`e[0m"
            [IO.File]::WriteAllText($kubectlProfilePath, "$(($kContent -join "`n").Trim())`n")
            Write-Host "`e[32m  removed nix:kubectl`e[0m"
        }
    }
    Write-Host "`e[32mProfile regions removed`e[0m"
}

#region nix package management wrapper (apt/brew-like UX)
function nx {
    # Profile commands are handled natively in PowerShell
    if ($args.Count -ge 1 -and $args[0] -eq 'profile') {
        $subArgs = @()
        if ($args.Count -gt 1) { $subArgs = $args[1..($args.Count - 1)] }
        $subCmd = if ($subArgs.Count -gt 0) { $subArgs[0] } else { 'help' }
        switch ($subCmd) {
                                    #region nx:dispatch (regenerate: python3 -m tests.hooks.gen_nx_completions)
            'doctor' { _NxProfileDoctor }
            'regenerate' { _NxProfileRegenerate }
            'uninstall' { _NxProfileUninstall }
            'help' { _NxProfileHelp }
            #endregion nx:dispatch
            default { _NxProfileHelp }
        }
        return
    }

    $nxScript = $null
    foreach ($c in @(
        [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.assets/lib/nx.sh')),
        [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.config/nix-env/nx.sh')
    )) {
        if ([IO.File]::Exists($c)) { $nxScript = $c; break }
    }
    if (-not $nxScript) {
        Write-Host "`e[31mnx.sh not found`e[0m"
        return
    }
    & bash $nxScript @args
}

#region nx-completer (generated from .assets/lib/nx_surface.json - regenerate with: python3 -m tests.hooks.gen_nx_completions)
Register-ArgumentCompleter -CommandName nx -Native -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $tokens = $commandAst.CommandElements
    $pos = $tokens.Count
    if ($wordToComplete) { $pos-- }

    $completions = switch ($pos) {
        1 { 'search', 'install', 'add', 'remove', 'uninstall', 'upgrade', 'update', 'rollback', 'list', 'ls', 'scope', 'overlay', 'pin', 'profile', 'setup', 'self', 'doctor', 'prune', 'gc', 'clean', 'version', 'help' }
        2 {
            if ($tokens[1].Value -eq 'scope') { 'list', 'show', 'tree', 'add', 'edit', 'remove', 'rm' }
            elseif ($tokens[1].Value -eq 'overlay') { 'list', 'status' }
            elseif ($tokens[1].Value -eq 'pin') { 'set', 'remove', 'rm', 'show', 'help' }
            elseif ($tokens[1].Value -eq 'profile') { 'doctor', 'regenerate', 'uninstall', 'help' }
            elseif ($tokens[1].Value -eq 'self') { 'update', 'path', 'help' }
            elseif ($tokens[1].Value -eq 'setup') {
                '--az', '--bun', '--conda', '--docker', '--gcloud', '--k8s-base', '--k8s-dev', '--k8s-ext', '--nodejs', '--pwsh', '--python', '--rice', '--shell', '--terraform', '--zsh', '--all', '--upgrade', '--allow-unfree', '--unattended', '--skip-repo-update', '--update-modules', '--omp-theme', '--starship-theme', '--remove', '--help'
            }
            elseif ($tokens[1].Value -eq 'doctor') {
                '--strict', '--json'
            }
            elseif ($tokens[1].Value -in 'remove', 'uninstall') {
                $pkgFile = "$HOME/.config/nix-env/packages.nix"
                                if (Test-Path $pkgFile) {
                                    (Get-Content $pkgFile) | ForEach-Object { if ($_ -match '^\s*"([^"]+)"') { $Matches[1] } }
                                }
            }
        }
        default {
            if ($tokens[1].Value -eq 'self' -and $tokens[2].Value -eq 'update') { '--force' }
            elseif ($tokens[1].Value -eq 'setup') {
                '--az', '--bun', '--conda', '--docker', '--gcloud', '--k8s-base', '--k8s-dev', '--k8s-ext', '--nodejs', '--pwsh', '--python', '--rice', '--shell', '--terraform', '--zsh', '--all', '--upgrade', '--allow-unfree', '--unattended', '--skip-repo-update', '--update-modules', '--omp-theme', '--starship-theme', '--remove', '--help'
            }
            elseif ($tokens[1].Value -eq 'doctor') {
                '--strict', '--json'
            }
            elseif ($tokens[1].Value -eq 'scope' -and $tokens[2].Value -in 'show') {
                $envDir = "$HOME/.config/nix-env"
                                $cfgFile = "$envDir/config.nix"
                                $scopeNames = @()
                                if (Test-Path $cfgFile) {
                                    $inScopes = $false
                                    (Get-Content $cfgFile) | ForEach-Object {
                                        if ($_ -match 'scopes\s*=\s*\[') { $inScopes = $true }
                                        if ($inScopes -and $_ -match '^\s*"([^"]+)"') { $scopeNames += $Matches[1] -replace '^local_', '' }
                                        if ($inScopes -and $_ -match '\]') { $inScopes = $false }
                                    }
                                }
                                $scopesDir = "$envDir/scopes"
                                if (Test-Path $scopesDir) {
                                    Get-ChildItem "$scopesDir/local_*.nix" -ErrorAction SilentlyContinue | ForEach-Object {
                                        $n = $_.BaseName -replace '^local_', ''
                                        if ($n -notin $scopeNames) { $scopeNames += $n }
                                    }
                                }
                                $scopeNames
            }
            elseif ($tokens[1].Value -eq 'scope' -and $tokens[2].Value -in 'edit') {
                $envDir = "$HOME/.config/nix-env"
                                $cfgFile = "$envDir/config.nix"
                                $scopeNames = @()
                                if (Test-Path $cfgFile) {
                                    $inScopes = $false
                                    (Get-Content $cfgFile) | ForEach-Object {
                                        if ($_ -match 'scopes\s*=\s*\[') { $inScopes = $true }
                                        if ($inScopes -and $_ -match '^\s*"([^"]+)"') { $scopeNames += $Matches[1] -replace '^local_', '' }
                                        if ($inScopes -and $_ -match '\]') { $inScopes = $false }
                                    }
                                }
                                $scopesDir = "$envDir/scopes"
                                if (Test-Path $scopesDir) {
                                    Get-ChildItem "$scopesDir/local_*.nix" -ErrorAction SilentlyContinue | ForEach-Object {
                                        $n = $_.BaseName -replace '^local_', ''
                                        if ($n -notin $scopeNames) { $scopeNames += $n }
                                    }
                                }
                                $scopeNames
            }
            elseif ($tokens[1].Value -eq 'scope' -and $tokens[2].Value -in 'remove', 'rm') {
                $envDir = "$HOME/.config/nix-env"
                                $cfgFile = "$envDir/config.nix"
                                $scopeNames = @()
                                if (Test-Path $cfgFile) {
                                    $inScopes = $false
                                    (Get-Content $cfgFile) | ForEach-Object {
                                        if ($_ -match 'scopes\s*=\s*\[') { $inScopes = $true }
                                        if ($inScopes -and $_ -match '^\s*"([^"]+)"') { $scopeNames += $Matches[1] -replace '^local_', '' }
                                        if ($inScopes -and $_ -match '\]') { $inScopes = $false }
                                    }
                                }
                                $scopesDir = "$envDir/scopes"
                                if (Test-Path $scopesDir) {
                                    Get-ChildItem "$scopesDir/local_*.nix" -ErrorAction SilentlyContinue | ForEach-Object {
                                        $n = $_.BaseName -replace '^local_', ''
                                        if ($n -notin $scopeNames) { $scopeNames += $n }
                                    }
                                }
                                $scopeNames
            }
            elseif ($tokens[1].Value -in 'remove', 'uninstall') {
                $pkgFile = "$HOME/.config/nix-env/packages.nix"
                                if (Test-Path $pkgFile) {
                                    (Get-Content $pkgFile) | ForEach-Object { if ($_ -match '^\s*"([^"]+)"') { $Matches[1] } }
                                }
            }
        }
    }
    $completions | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
#endregion nx-completer
#endregion
