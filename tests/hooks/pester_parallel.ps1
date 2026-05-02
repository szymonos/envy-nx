<#
.SYNOPSIS
Run Pester tests in parallel across files via ForEach-Object -Parallel.

.DESCRIPTION
File-level parallelism inside one pwsh session: each runspace runs
Invoke-Pester on one file, results aggregated at the end. Avoids paying
~3s pwsh startup per file (the dominant cost when launching pwsh per-file
from a Make target). ThrottleLimit defaults to 4 to match the bats hook.

Used by the `test-unit` Makefile target. The single-pwsh hook
(tests/hooks/run_pester.py) inlines the same logic for changed-file runs.

.PARAMETER Path
Directory containing *.Tests.ps1 files. Defaults to tests/pester/.

.PARAMETER ThrottleLimit
Maximum parallel runspaces. Defaults to 4.

.EXAMPLE
pwsh -nop -File tests/hooks/pester_parallel.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = 'tests/pester/',
    [int]$ThrottleLimit = 4
)

$ErrorActionPreference = 'Stop'

$files = Get-ChildItem (Join-Path $Path '*.Tests.ps1')
if (-not $files) {
    Write-Host "No Pester test files found in $Path"
    exit 0
}

# ConcurrentBag for thread-safe result collection across runspaces.
# `ForEach-Object -Parallel`'s pipeline output is internally thread-safe,
# but ConcurrentBag is the explicit / more defensive idiom: results are
# accumulated via a known-safe collection rather than relying on pipeline
# stream synchronization. Cost is trivial; the Add() call is lock-free.
$bag = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
# Separate bag for runspace crashes. Without this, an Invoke-Pester
# exception (e.g. malformed config, missing module) would leave the
# corresponding file with no entry in $bag, the FailedCount sum would
# stay 0, and the helper would report success despite a dead worker.
$errBag = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

$files | ForEach-Object -Parallel {
    $localBag = $using:bag
    $localErrBag = $using:errBag
    $file = $_.FullName
    try {
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = $file
        $cfg.Run.PassThru = $true
        $cfg.Output.Verbosity = 'None'
        $localBag.Add((Invoke-Pester -Configuration $cfg))
    } catch {
        $localErrBag.Add("${file}: $_")
    }
} -ThrottleLimit $ThrottleLimit

$results = $bag.ToArray()
$errors = $errBag.ToArray()
$total = ($results | Measure-Object -Property TotalCount -Sum).Sum
$failed = ($results | Measure-Object -Property FailedCount -Sum).Sum
$passed = ($results | Measure-Object -Property PassedCount -Sum).Sum

if ($errors.Count -gt 0) {
    Write-Host "`e[31mPester: $($errors.Count) runspace(s) crashed before returning a result:`e[0m"
    foreach ($err in $errors) { Write-Host "  $err" }
    exit 1
}
if ($failed -gt 0) {
    Write-Host "`e[31mPester: $failed failed out of $total tests`e[0m"
    exit 1
} else {
    Write-Host "`e[32mPester: $passed/$total tests passed`e[0m"
}
