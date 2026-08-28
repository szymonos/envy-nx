#Requires -Modules Pester

BeforeAll {
    . $PSScriptRoot/../../.assets/setup/setup_az_login.ps1
}

Describe 'Set-AzPowerShellWamConfig' {
    BeforeEach {
        $testDir = Join-Path $TestDrive ([guid]::NewGuid())
        $configPath = Join-Path $testDir 'PSConfig.json'
    }

    It 'creates the Linux WAM override without requiring Az.Accounts' {
        Set-AzPowerShellWamConfig -Path $configPath | Should -BeTrue

        $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $config.Az.EnableLoginByWam | Should -BeFalse
    }

    It 'preserves unrelated user configuration while disabling WAM' {
        New-Item $testDir -ItemType Directory | Out-Null
        @'
{
  "Az": {
    "DefaultSubscriptionForLogin": "subscription-id"
  },
  "Contoso": {
    "Setting": 42
  }
}
'@ | Set-Content $configPath

        Set-AzPowerShellWamConfig -Path $configPath | Should -BeTrue

        $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $config.Az.EnableLoginByWam | Should -BeFalse
        $config.Az.DefaultSubscriptionForLogin | Should -Be 'subscription-id'
        $config.Contoso.Setting | Should -Be 42
    }

    It 'merges existing keys case-insensitively without creating duplicates' {
        New-Item $testDir -ItemType Directory | Out-Null
        '{"az":{"enableloginbywam":true,"OtherSetting":"kept"}}' | Set-Content $configPath

        Set-AzPowerShellWamConfig -Path $configPath | Should -BeTrue

        $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $azKeys = @($config.Keys | Where-Object { $_ -ieq 'Az' })
        $wamKeys = @($config[$azKeys[0]].Keys | Where-Object { $_ -ieq 'EnableLoginByWam' })
        $azKeys | Should -HaveCount 1
        $wamKeys | Should -HaveCount 1
        $config[$azKeys[0]][$wamKeys[0]] | Should -BeFalse
        $config[$azKeys[0]].OtherSetting | Should -Be 'kept'
    }

    It 'repairs an empty config file' {
        New-Item $testDir -ItemType Directory | Out-Null
        [IO.File]::WriteAllText($configPath, '')

        Set-AzPowerShellWamConfig -Path $configPath | Should -BeTrue

        $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $config.Az.EnableLoginByWam | Should -BeFalse
    }

    It 'accepts a filename-only config path' {
        New-Item $testDir -ItemType Directory | Out-Null
        Push-Location $testDir
        try {
            Set-AzPowerShellWamConfig -Path 'PSConfig.json' | Should -BeTrue
            (Get-Content PSConfig.json -Raw | ConvertFrom-Json).Az.EnableLoginByWam | Should -BeFalse
        } finally {
            Pop-Location
        }
    }

    It 'does not rewrite a config that already disables WAM' {
        New-Item $testDir -ItemType Directory | Out-Null
        '{"Az":{"EnableLoginByWam":false}}' | Set-Content $configPath
        $before = (Get-Item $configPath).LastWriteTimeUtc

        Set-AzPowerShellWamConfig -Path $configPath | Should -BeFalse
        (Get-Item $configPath).LastWriteTimeUtc | Should -Be $before
    }

    It 'rejects malformed JSON without replacing the file' {
        New-Item $testDir -ItemType Directory | Out-Null
        $original = '{not-json'
        Set-Content $configPath $original

        { Set-AzPowerShellWamConfig -Path $configPath -ErrorAction Stop } | Should -Throw
        (Get-Content $configPath -Raw).Trim() | Should -Be $original
    }
}

Describe 'Test-MsalBrowserAuthNeedsDisplay' {
    It 'enables DISPLAY when a genuine wslview is the only opener' {
        Test-MsalBrowserAuthNeedsDisplay -IsLinuxPlatform $true -HasEarlierOpener $false -HasWslview $true |
            Should -BeTrue
    }

    It 'does not enable DISPLAY when an earlier MSAL opener exists' {
        Test-MsalBrowserAuthNeedsDisplay -IsLinuxPlatform $true -HasEarlierOpener $true -HasWslview $true |
            Should -BeFalse
    }

    It 'does not enable DISPLAY without any viable opener' {
        Test-MsalBrowserAuthNeedsDisplay -IsLinuxPlatform $true -HasEarlierOpener $false -HasWslview $false |
            Should -BeFalse
    }
}

Describe 'Set-MsalBrowserAuthProfileRegion' {
    BeforeEach {
        $content = [System.Collections.Generic.List[string]]::new()
        $content.Add('Write-Host "user profile"')
    }

    It 'adds a guarded DISPLAY value for headless sessions' {
        Set-MsalBrowserAuthProfileRegion -Content $content -Enabled $true | Should -BeTrue

        $content | Should -Contain 'if ($IsLinux -and -not $env:DISPLAY) {'
        $content | Should -Contain "    `$env:DISPLAY = ':0'"
    }

    It 'is idempotent when the managed region is current' {
        Set-MsalBrowserAuthProfileRegion -Content $content -Enabled $true | Should -BeTrue
        $before = $content -join "`n"

        Set-MsalBrowserAuthProfileRegion -Content $content -Enabled $true | Should -BeFalse
        ($content -join "`n") | Should -BeExactly $before
    }

    It 'removes the managed region when a real opener becomes available' {
        Set-MsalBrowserAuthProfileRegion -Content $content -Enabled $true | Out-Null

        Set-MsalBrowserAuthProfileRegion -Content $content -Enabled $false | Should -BeTrue
        $content | Should -Be @('Write-Host "user profile"')
    }

    It 'accepts a named closing marker when removing the managed region' {
        $content.Add('#region msal-browser-auth')
        $content.Add('$env:DISPLAY = ":0"')
        $content.Add('#endregion msal-browser-auth')

        Set-MsalBrowserAuthProfileRegion -Content $content -Enabled $false | Should -BeTrue
        $content | Should -Be @('Write-Host "user profile"')
    }

    It 'rejects an unterminated managed region without changing the profile' {
        $content.Add('#region msal-browser-auth')
        $content.Add('$env:DISPLAY = ":0"')
        $before = $content -join "`n"

        { Set-MsalBrowserAuthProfileRegion -Content $content -Enabled $true -ErrorAction Stop } | Should -Throw
        ($content -join "`n") | Should -BeExactly $before
    }
}
