"""
Run bats tests for changed files.

Scans tests/bats/*.bats for `source` directives to build a mapping of which
source files are covered by which test files. When any covered source file
(or a .bats file itself) is staged, runs the relevant tests.

Multi-file runs parallelize across 4 workers, capture each child's TAP
output, and print a final summary: total passed / failed / skipped, and
when there are failures, a per-file list of failing test names. Capturing
also de-interleaves the parallel output - each file's bats lines print as
one block when the file finishes, instead of the prior `xargs -P` salad.
Single-file runs stream directly without buffering or summary.

# :example
python3 -m tests.hooks.run_bats
# :run with explicit file list (as pre-commit passes them)
python3 -m tests.hooks.run_bats .assets/lib/scopes.sh tests/bats/test_scopes.bats
"""

import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BATS_DIR = REPO_ROOT / "tests" / "bats"


def build_source_map() -> dict[str, list[Path]]:
    """Parse .bats files and return {relative_source_path: [bats_files]}."""
    source_to_tests: dict[str, list[Path]] = {}

    if not BATS_DIR.is_dir():
        return source_to_tests

    # match: source "path" or source 'path' with optional $BATS_TEST_DIRNAME/ prefix
    source_re = re.compile(
        r'^\s*source\s+["\']'
        r"(?:\$BATS_TEST_DIRNAME/)?"
        r'(.+?)["\']',
    )

    for bats_file in sorted(BATS_DIR.glob("*.bats")):
        bats_rel = bats_file.relative_to(REPO_ROOT).as_posix()

        # the .bats file itself is always in scope
        source_to_tests.setdefault(bats_rel, []).append(bats_file)

        for line in bats_file.read_text().splitlines():
            m = source_re.match(line)
            if not m:
                continue

            raw_path = m.group(1)
            # resolve relative to the bats file directory
            resolved = (BATS_DIR / raw_path).resolve()
            try:
                rel = resolved.relative_to(REPO_ROOT).as_posix()
            except ValueError:
                continue

            source_to_tests.setdefault(rel, []).append(bats_file)

            # also watch the sibling .json if the source is scopes.sh
            if rel.endswith("scopes.sh"):
                json_rel = rel.replace("scopes.sh", "scopes.json")
                source_to_tests.setdefault(json_rel, []).append(bats_file)

    return source_to_tests


def main(argv: list[str] | None = None) -> int:
    """Run bats tests covering the source files passed (or all changed)."""
    if not shutil.which("bats"):
        print("bats not found, skipping tests", file=sys.stderr)
        return 0

    # files passed by pre-commit (or CLI)
    changed_files = set(argv or [])

    source_map = build_source_map()
    if not source_map:
        return 0

    # collect bats files to run
    to_run: set[Path] = set()
    for changed in changed_files:
        # normalize to posix-style relative path
        normalized = Path(changed).as_posix()
        if normalized in source_map:
            to_run.update(source_map[normalized])

    if not to_run:
        return 0

    # Strip env vars known to make bats children hang on hostile environments:
    # - HTTP_PROXY / HTTPS_PROXY (corporate proxy unreachable)
    # - GIT_TERMINAL_PROMPT=1 (forces git to prompt for missing creds)
    # - NIX_ENV_TLS_PROBE_URL (would trigger MITM probe code paths in some tests)
    # - NIX_ENV_OVERLAY_DIR (could point at an unreadable corp share)
    # - GH_TOKEN / GITHUB_TOKEN (bad token can stall `gh` even with our
    #   NX_DOCTOR_SKIP_NETWORK guard if other tests shell out to gh)

    env = {**os.environ}
    for var in (
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "no_proxy",
        "all_proxy",
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "NIX_ENV_TLS_PROBE_URL",
        "NIX_ENV_OVERLAY_DIR",
        "GIT_TERMINAL_PROMPT",
    ):
        env.pop(var, None)
    # Defense-in-depth: block any code path that might still want to talk to GH.
    env["NX_DOCTOR_SKIP_NETWORK"] = "1"
    # Tell git to never prompt (returns non-zero immediately on missing creds).
    env["GIT_TERMINAL_PROMPT"] = "0"

    # Best-effort wall-clock timeout per bats invocation. timeout(1) ships
    # with GNU coreutils (Linux/WSL); macOS userland lacks it but brewed
    # coreutils installs `gtimeout`. When neither is present, run unbounded -
    # the timeout is a hang-prevention safety net, not a hard requirement,
    # and pre-commit users can Ctrl-C if a real hang appears.
    #
    # 120s ceiling. test_nx_doctor.bats runs ~40s standalone and tipped
    # over the prior 60s ceiling under `xargs -P 4` parallel CPU contention
    # (other heavy files in the same wave: test_nix_setup ~30s,
    # test_nx_commands ~27s). 120s keeps the hang-prevention purpose - any
    # bats file legitimately running >2 minutes has a real bug - while
    # accommodating parallel-load slowdown without false-positive timeouts.
    timeout_prefix: list[str] = []
    if shutil.which("timeout"):
        timeout_prefix = ["timeout", "120"]
    elif shutil.which("gtimeout"):
        timeout_prefix = ["gtimeout", "120"]

    sorted_files = sorted(str(f) for f in to_run)
    if len(sorted_files) <= 1:
        # Single-file: stream stdout/stderr directly, no buffering or summary.
        # Pre-commit users running on one .bats file just want the bats output.
        return subprocess.run(
            timeout_prefix + ["bats"] + sorted_files, env=env
        ).returncode

    # Multi-file: parallelize across 4 workers (Python ThreadPoolExecutor;
    # bats's native -j needs GNU parallel, not bootstrapped here). Capture
    # each child's stdout so we can parse TAP for the summary AND emit each
    # file's output as one block - prior `xargs -P` interleaving made the
    # output unreadable. Cap at 4: tests do heavy mktemp/io and disks
    # thrash above that.
    results: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        futures = [
            ex.submit(_run_one_bats, f, env, timeout_prefix) for f in sorted_files
        ]
        for fut in concurrent.futures.as_completed(futures):
            results.append(fut.result())

    results.sort(key=lambda r: r["file"])
    _print_summary(results)
    return max((r["rc"] for r in results), default=0)


# TAP line patterns. bats emits standard TAP:
#   ok N <name>                     -> passed
#   ok N <name> # skip <reason>     -> passed + skipped
#   not ok N <name>                 -> failed (followed by indented `# ...` lines)
_TAP_OK_LINE = re.compile(
    r"^ok\s+\d+\s+(.+?)(?:\s+#\s+(skip|todo)\b.*)?$", re.IGNORECASE
)
_TAP_NOT_OK_LINE = re.compile(r"^not ok\s+\d+\s+(.+)$")


def _parse_tap(stdout: str) -> tuple[int, int, int, list[str]]:
    """Parse bats TAP output. Returns (passed, failed, skipped, [failing_names])."""
    passed = 0
    failed = 0
    skipped = 0
    failing: list[str] = []
    for line in stdout.splitlines():
        m = _TAP_NOT_OK_LINE.match(line)
        if m:
            failed += 1
            failing.append(m.group(1).strip())
            continue
        m = _TAP_OK_LINE.match(line)
        if m:
            passed += 1
            if m.group(2):
                skipped += 1
    return passed, failed, skipped, failing


def _run_one_bats(bats_file: str, env: dict, timeout_prefix: list[str]) -> dict:
    """
    Run one bats file under capture, parse TAP, stream the captured output.

    The captured chunk is emitted to stdout/stderr after completion so
    parallel runs don't interleave. Per-file `starting`/`done` markers
    print to stderr as they happen.
    """
    print(f">>> [bats] starting {bats_file}", file=sys.stderr, flush=True)
    cmd = timeout_prefix + ["bats", bats_file]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
    elapsed = time.perf_counter() - t0

    passed, failed, skipped, failing = _parse_tap(proc.stdout)
    timed_out = proc.returncode == 124
    if timed_out and not failing:
        secs = timeout_prefix[1] if timeout_prefix else "?"
        failing.append(f"<TIMEOUT after {secs}s; bats killed mid-run>")

    # Emit captured output as one block now (avoids interleaving across
    # parallel workers). bats stdout is the TAP stream; stderr carries
    # `setup`/`teardown` warnings and bats' own diagnostics.
    sys.stdout.write(proc.stdout)
    sys.stdout.flush()
    if proc.stderr:
        sys.stderr.write(proc.stderr)
        sys.stderr.flush()

    suffix = ""
    if timed_out:
        secs = timeout_prefix[1] if timeout_prefix else "?"
        suffix = f" TIMEOUT after {secs}s"
    summary = (
        f"(rc={proc.returncode}, passed={passed}, failed={failed}, {elapsed:.1f}s)"
    )
    print(
        f">>> [bats] done    {bats_file} {summary}{suffix}",
        file=sys.stderr,
        flush=True,
    )

    return {
        "file": bats_file,
        "rc": proc.returncode,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "failing": failing,
        "elapsed": elapsed,
    }


def _print_summary(results: list[dict]) -> None:
    """Print aggregate counts plus per-file failing test names if any."""
    total_passed = sum(r["passed"] for r in results)
    total_failed = sum(r["failed"] for r in results)
    total_skipped = sum(r["skipped"] for r in results)
    total_files = len(results)
    # Sum of per-file wall times (NOT wall-clock end-to-end; the 4-way
    # parallelism makes the real elapsed roughly total / N_workers). Both
    # numbers are useful: total tells you "test code is heavy", real wall
    # would tell you "ok in CI". Keep total - it's what users care about
    # when a single file is slow.
    total_elapsed = sum(r["elapsed"] for r in results)

    print("", file=sys.stderr)
    skipped_note = f" ({total_skipped} skipped)" if total_skipped else ""
    print(
        f">>> [bats] SUMMARY: {total_passed} passed, {total_failed} failed"
        f"{skipped_note} across {total_files} file(s) in {total_elapsed:.1f}s "
        f"(sum of per-file wall times)",
        file=sys.stderr,
        flush=True,
    )

    failed_results = [r for r in results if r["failed"] > 0 or r["rc"] != 0]
    if failed_results:
        print(">>> [bats] failures:", file=sys.stderr)
        for r in failed_results:
            print(f"  {r['file']} (rc={r['rc']}):", file=sys.stderr)
            if r["failing"]:
                for name in r["failing"]:
                    print(f"    - {name}", file=sys.stderr)
            else:
                # rc != 0 with no parsed failures: bats crashed before TAP
                # plan, or output was non-TAP. Surface so user looks at the
                # captured stdout above.
                print(
                    "    - (no failing test name parsed; check captured output above)",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
