function Set-AzPowerShellWamConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $configDir = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path $configDir -PathType Container)) {
        New-Item $configDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    if (Test-Path $Path -PathType Leaf) {
        $rawConfig = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($rawConfig)) {
            $config = [ordered]@{}
        } else {
            $config = $rawConfig | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($config -isnot [System.Collections.IDictionary]) {
                throw "Az PowerShell config '$Path' must contain a JSON object."
            }
        }
    } else {
        $config = [ordered]@{}
    }

    $azKeys = @($config.Keys | Where-Object { $_ -ieq 'Az' })
    if ($azKeys.Count -gt 1) {
        throw "Az PowerShell config '$Path' contains duplicate case-insensitive 'Az' properties."
    }
    if ($azKeys.Count -eq 1) {
        $azKey = $azKeys[0]
        if ($config[$azKey] -isnot [System.Collections.IDictionary]) {
            throw "Az PowerShell config '$Path' property 'Az' must contain a JSON object."
        }
    } else {
        $azKey = 'Az'
        $config[$azKey] = [ordered]@{}
    }

    $azConfig = $config[$azKey]
    $wamKeys = @($azConfig.Keys | Where-Object { $_ -ieq 'EnableLoginByWam' })
    if ($wamKeys.Count -gt 1) {
        throw "Az PowerShell config '$Path' contains duplicate case-insensitive 'EnableLoginByWam' properties."
    }
    $wamKey = $wamKeys.Count -eq 1 ? $wamKeys[0] : 'EnableLoginByWam'
    if ($wamKeys.Count -eq 1 -and $azConfig[$wamKey] -is [bool] -and -not $azConfig[$wamKey]) {
        return $false
    }

    $azConfig[$wamKey] = $false
    $json = $config | ConvertTo-Json -Depth 100
    $tempPath = Join-Path $configDir ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid()).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, "$json`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tempPath, $Path, $true)
    } finally {
        if (Test-Path $tempPath -PathType Leaf) {
            Remove-Item $tempPath -Force
        }
    }
    return $true
}

function Test-MsalBrowserAuthNeedsDisplay {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [bool]$IsLinuxPlatform,

        [Parameter(Mandatory)]
        [bool]$HasEarlierOpener,

        [Parameter(Mandatory)]
        [bool]$HasWslview
    )

    return $IsLinuxPlatform -and -not $HasEarlierOpener -and $HasWslview
}

function Set-MsalBrowserAuthProfileRegion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$Content,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    $regionName = 'msal-browser-auth'
    $desired = [string[]]@(
        "#region $regionName"
        'if ($IsLinux -and -not $env:DISPLAY) {'
        "    `$env:DISPLAY = ':0'"
        '}'
        '#endregion'
    )
    $ranges = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Content.Count; $i++) {
        if ($Content[$i] -notmatch "^\s*#region\s+$([regex]::Escape($regionName))\s*$") {
            continue
        }
        $endPattern = "^\s*#endregion(?:\s+$([regex]::Escape($regionName)))?\s*$"
        $end = $Content.FindIndex($i + 1, { param($line) $line -match $endPattern })
        if ($end -lt 0) {
            throw "PowerShell profile region '$regionName' has no closing #endregion."
        }
        $ranges.Add([pscustomobject]@{ Start = $i; End = $end })
        $i = $end
    }

    if ($Enabled -and $ranges.Count -eq 1) {
        $range = $ranges[0]
        $existing = $Content.GetRange($range.Start, $range.End - $range.Start + 1)
        if ($existing.Count -eq $desired.Count -and -not (Compare-Object $existing $desired -SyncWindow 0)) {
            return $false
        }
    } elseif (-not $Enabled -and $ranges.Count -eq 0) {
        return $false
    }

    for ($i = $ranges.Count - 1; $i -ge 0; $i--) {
        $start = $ranges[$i].Start
        $count = $ranges[$i].End - $start + 1
        if ($start -gt 0 -and [string]::IsNullOrWhiteSpace($Content[$start - 1])) {
            $start--
            $count++
        }
        [void]$Content.RemoveRange($start, $count)
    }

    if ($Enabled) {
        if ($Content.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Content[$Content.Count - 1])) {
            [void]$Content.Add('')
        }
        [void]$Content.AddRange($desired)
    }
    return $true
}
