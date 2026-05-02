"""
Run bats tests for changed files.

Scans tests/bats/*.bats for `source` directives to build a mapping of which
source files are covered by which test files. When any covered source file
(or a .bats file itself) is staged, runs the relevant tests.

# :example
python3 -m tests.hooks.run_bats
# :run with explicit file list (as pre-commit passes them)
python3 -m tests.hooks.run_bats .assets/lib/scopes.sh tests/bats/test_scopes.bats
"""

import os
import re
import shutil
import subprocess
import sys
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
    timeout_prefix: list[str] = []
    if shutil.which("timeout"):
        timeout_prefix = ["timeout", "60"]
    elif shutil.which("gtimeout"):
        timeout_prefix = ["gtimeout", "60"]

    sorted_files = sorted(str(f) for f in to_run)
    if len(sorted_files) <= 1:
        return subprocess.run(
            timeout_prefix + ["bats"] + sorted_files, env=env
        ).returncode

    # Multiple files: parallelize one bats process per file. bats's native
    # -j needs GNU parallel which isn't bootstrapped by this repo; xargs -P
    # gives ~2-3x wall-time win without the dependency. Capped at 4 - tests
    # do lots of mktemp/io and disks thrash above that.
    #
    # If a timeout binary is available, each child bats gets `timeout 60`;
    # otherwise children run unbounded. Per-file progress markers go to
    # stderr so users running outside prek see which file is slow.
    if timeout_prefix:
        timeout_invoke = f'{timeout_prefix[0]} {timeout_prefix[1]} bats "$1"'
        timeout_note = (
            '[ $rc -eq 124 ] && echo ">>> [bats] TIMEOUT after 60s: $1" >&2; '
        )
    else:
        timeout_invoke = 'bats "$1"'
        timeout_note = ""
    sh_cmd = (
        'echo ">>> [bats] starting $1" >&2; '
        f"{timeout_invoke}; rc=$?; "
        f"{timeout_note}"
        'echo ">>> [bats] done    $1 (rc=$rc)" >&2; '
        "exit $rc"
    )
    proc = subprocess.run(
        ["xargs", "-0", "-P", "4", "-n", "1", "sh", "-c", sh_cmd, "_"],
        input="\0".join(sorted_files).encode(),
        env=env,
    )
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
