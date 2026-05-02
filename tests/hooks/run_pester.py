#!/usr/bin/env python3
"""
Run Pester tests for changed PowerShell files.

Scans tests/pester/*.Tests.ps1 for dot-source directives to build a mapping
of which source files are covered by which test files. When any covered source
file (or a .Tests.ps1 file itself) is staged, runs the relevant tests.

# :example
python3 -m tests.hooks.run_pester
# :run with explicit file list (as pre-commit passes them)
python3 -m tests.hooks.run_pester modules/SetupUtils/Functions/common.ps1
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PESTER_DIR = REPO_ROOT / "tests" / "pester"


def build_source_map() -> dict[str, list[Path]]:
    """Parse .Tests.ps1 files and return {relative_source_path: [test_files]}."""
    source_to_tests: dict[str, list[Path]] = {}

    if not PESTER_DIR.is_dir():
        return source_to_tests

    # match: . $PSScriptRoot/../../path/to/file.ps1
    # or: . "$PSScriptRoot/../../path/to/file.ps1"
    source_re = re.compile(
        r"^\s*\.\s+"
        r'["\']?\$PSScriptRoot/'
        r"(.+?\.ps1)"
        r'["\']?\s*$',
    )

    for test_file in sorted(PESTER_DIR.glob("*.Tests.ps1")):
        test_rel = test_file.relative_to(REPO_ROOT).as_posix()

        # the test file itself is always in scope
        source_to_tests.setdefault(test_rel, []).append(test_file)

        for line in test_file.read_text().splitlines():
            m = source_re.match(line)
            if not m:
                continue

            raw_path = m.group(1)
            # resolve relative to the pester test directory
            resolved = (PESTER_DIR / raw_path).resolve()
            try:
                rel = resolved.relative_to(REPO_ROOT).as_posix()
            except ValueError:
                continue

            source_to_tests.setdefault(rel, []).append(test_file)

            # also watch scopes.json if source is scopes.ps1
            if rel.endswith("scopes.ps1"):
                json_rel = rel.rsplit("/", 1)[0] + "/../../../.assets/lib/scopes.json"
                json_resolved = (PESTER_DIR / json_rel).resolve()
                try:
                    json_rel_norm = json_resolved.relative_to(REPO_ROOT).as_posix()
                except ValueError:
                    continue
                source_to_tests.setdefault(json_rel_norm, []).append(test_file)

    # also map _aliases_nix.ps1 to NxHelpers.Tests.ps1
    nx_test = PESTER_DIR / "NxHelpers.Tests.ps1"
    if nx_test.exists():
        nx_source = ".assets/config/pwsh_cfg/_aliases_nix.ps1"
        source_to_tests.setdefault(nx_source, []).append(nx_test)

    return source_to_tests


def main(argv: list[str] | None = None) -> int:
    if not shutil.which("pwsh"):
        print("pwsh not found, skipping Pester tests", file=sys.stderr)
        return 0

    # files passed by pre-commit (or CLI)
    changed_files = set(argv or [])

    source_map = build_source_map()
    if not source_map:
        return 0

    # collect test files to run
    to_run: set[Path] = set()
    for changed in changed_files:
        normalized = Path(changed).as_posix()
        if normalized in source_map:
            to_run.update(source_map[normalized])

    if not to_run:
        return 0

    # build Pester invocation with specific test files
    test_paths = sorted(str(f) for f in to_run)
    if len(test_paths) <= 1:
        # Single file: don't bother with parallel runspaces - direct invocation
        # is faster than the ForEach-Object -Parallel setup overhead.
        paths_arg = ", ".join(f"'{p}'" for p in test_paths)
        pester_cmd = (
            "$cfg = New-PesterConfiguration; "
            f"$cfg.Run.Path = @({paths_arg}); "
            "$cfg.Run.Exit = $true; "
            "$cfg.Output.Verbosity = 'Detailed'; "
            "Invoke-Pester -Configuration $cfg"
        )
    else:
        # Multiple files: parallelize via ForEach-Object -Parallel inside one
        # pwsh session - avoids paying ~3s pwsh startup per file. Each runspace
        # runs Invoke-Pester on one file; results land in a ConcurrentBag for
        # thread-safe aggregation (ForEach-Object -Parallel's pipeline output
        # is documented as thread-safe but ConcurrentBag is the more defensive
        # idiom). ThrottleLimit 4 matches the bats hook's xargs -P 4.
        # `$errBag` captures runspace crashes (Invoke-Pester throws before
        # returning a result object). Without this, a worker death leaves
        # zero entries in `$bag`, FailedCount stays 0, and the hook reports
        # success despite the crash. Catch + record the file path so the
        # error message is actionable.
        paths_arg = ", ".join(f"'{p}'" for p in test_paths)
        pester_cmd = (
            f"$paths = @({paths_arg}); "
            "$bag = [System.Collections.Concurrent.ConcurrentBag[object]]::new(); "
            "$errBag = [System.Collections.Concurrent.ConcurrentBag[string]]::new(); "
            "$paths | ForEach-Object -Parallel { "
            "$localBag = $using:bag; "
            "$localErrBag = $using:errBag; "
            "$file = $_; "
            "try { "
            "$cfg = New-PesterConfiguration; "
            "$cfg.Run.Path = $file; "
            "$cfg.Run.PassThru = $true; "
            "$cfg.Output.Verbosity = 'Detailed'; "
            "$localBag.Add((Invoke-Pester -Configuration $cfg)) "
            '} catch { $localErrBag.Add("${file}: $_") } '
            "} -ThrottleLimit 4; "
            "$errs = $errBag.ToArray(); "
            "if ($errs.Count -gt 0) { "
            'Write-Host "`e[31m$($errs.Count) runspace(s) crashed:`e[0m"; '
            'foreach ($e in $errs) { Write-Host "  $e" }; '
            "exit 1 } "
            "$failed = ($bag.ToArray() | Measure-Object -Property FailedCount -Sum).Sum; "
            "if ($failed -gt 0) { exit 1 }"
        )

    pwsh = Path.home() / ".nix-profile" / "bin" / "pwsh"
    if not pwsh.exists():
        pwsh_path = shutil.which("pwsh") or "pwsh"
    else:
        pwsh_path = str(pwsh)

    env = {**__import__("os").environ}
    env.pop("LD_LIBRARY_PATH", None)

    result = subprocess.run([pwsh_path, "-nop", "-c", pester_cmd], env=env)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
