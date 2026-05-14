#!/usr/bin/env -S uv run python3
"""
test_stats.py - count current bats/Pester suites and report drift in docs.

Stat callouts in docs (`docs/standards.md` total counters, `docs/index.md`
quick-facts table, `ARCHITECTURE.md` test-coverage paragraphs, etc.) go stale
the moment a test file is added or an `It` block lands. The /prepare-release
skill calls this helper in Phase 1.7 to detect drift before the CHANGELOG is
composed - so any necessary doc edits land in the same release.

Subcommands
-----------
scan
    Emit JSON of authoritative current counts:
    {
      "bats":   {"files": <int>, "cases": <int>},
      "pester": {"files": <int>, "tests": <int>},
      "total":  {"files": <int>, "cases": <int>}
    }

audit
    Grep the curated `STAT_LOCATIONS` table for the recorded callouts and
    report any whose extracted number disagrees with the live count. Output:
    list of {file, line, snippet, expected, actual, kind} for the agent to
    Edit. Returns exit 1 if any drift is found, 0 otherwise.

Both subcommands run from the repo root (resolved via `git rev-parse
--show-toplevel`).

Usage
-----
    .claude/skills/prepare-release/scripts/test_stats.py scan
    .claude/skills/prepare-release/scripts/test_stats.py audit
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# ---- Authoritative source: count from the actual test files ----------------

BATS_TEST_RE = re.compile(r"^@test\s")
PESTER_IT_RE = re.compile(r"^\s+It\s")


def repo_root() -> Path:
    """Return the repo root via git, falling back to CWD."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(out.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return Path.cwd()


def count_lines(path: Path, pattern: re.Pattern) -> int:
    """Count lines in `path` matching `pattern`. 0 on any IO error."""
    try:
        return sum(1 for line in path.read_text().splitlines() if pattern.match(line))
    except OSError:
        return 0


def gather_counts(root: Path) -> dict[str, dict[str, int]]:
    """Scan tests/bats and tests/pester; return current counts."""
    bats_files = sorted((root / "tests" / "bats").glob("*.bats"))
    pester_files = sorted((root / "tests" / "pester").glob("*.Tests.ps1"))

    bats_cases = sum(count_lines(p, BATS_TEST_RE) for p in bats_files)
    pester_tests = sum(count_lines(p, PESTER_IT_RE) for p in pester_files)

    return {
        "bats": {"files": len(bats_files), "cases": bats_cases},
        "pester": {"files": len(pester_files), "tests": pester_tests},
        "total": {
            "files": len(bats_files) + len(pester_files),
            "cases": bats_cases + pester_tests,
        },
    }


# ---- Curated stat-callout table -------------------------------------------
#
# Each entry: (file, regex-with-one-numeric-capture-group, kind).
# `kind` references a key in the counts dict; the audit compares the captured
# integer against `counts[kind_path]`. Add new locations here as docs grow -
# the skill body reminds the agent to do this when it touches a doc with stats.
#
# `kind_path` uses dotted notation matching the gather_counts shape:
#   "bats.files", "bats.cases", "pester.files", "pester.tests",
#   "total.files", "total.cases"

STAT_LOCATIONS: list[tuple[str, str, str]] = [
    # docs/standards.md - the dedicated quality-and-testing dashboard.
    ("docs/standards.md", r"\|\s*Unit test files\s*\|\s*(\d+)\s*\(", "total.files"),
    (
        "docs/standards.md",
        r"\|\s*Unit test files\s*\|\s*\d+\s*\((\d+)\s*bats",
        "bats.files",
    ),
    (
        "docs/standards.md",
        r"\|\s*Unit test files\s*\|\s*\d+\s*\(\d+\s*bats\s*\+\s*(\d+)\s*Pester",
        "pester.files",
    ),
    (
        "docs/standards.md",
        r"\|\s*Individual test cases\s*\|\s*(\d+)\s*\(",
        "total.cases",
    ),
    (
        "docs/standards.md",
        r"\|\s*Individual test cases\s*\|\s*\d+\s*\((\d+)\s*bats",
        "bats.cases",
    ),
    (
        "docs/standards.md",
        r"\|\s*Individual test cases\s*\|\s*\d+\s*\(\d+\s*bats\s*\+\s*(\d+)\s*Pester",
        "pester.tests",
    ),
    ("docs/standards.md", r"^(\d+)\s+bats files cover", "bats.files"),
    ("docs/standards.md", r"^(\d+)\s+Pester files mirror", "pester.files"),
    # docs/index.md - landing-page quick-facts table.
    (
        "docs/index.md",
        r"Bats \(bash\) and Pester \(PowerShell\) suites across (\d+) test files",
        "total.files",
    ),
    # ARCHITECTURE.md - test-infra section header counts.
    ("ARCHITECTURE.md", r"^(\d+)\s+Pester files;", "pester.files"),
    # Add more entries as new stat callouts land. Run audit to confirm regex
    # matches by eye before relying on it.
]


def audit(root: Path, counts: dict[str, dict[str, int]]) -> list[dict[str, object]]:
    """Compare each STAT_LOCATIONS callout against live counts; return drift list."""
    drift: list[dict[str, object]] = []
    for rel, pattern, kind_path in STAT_LOCATIONS:
        path = root / rel
        if not path.is_file():
            continue
        kind_parts = kind_path.split(".")
        try:
            actual = counts[kind_parts[0]][kind_parts[1]]
        except (KeyError, IndexError):
            continue
        regex = re.compile(pattern, re.MULTILINE)
        text = path.read_text()
        for match in regex.finditer(text):
            captured = int(match.group(1))
            if captured == actual:
                continue
            line_no = text.count("\n", 0, match.start()) + 1
            line_text = text.splitlines()[line_no - 1].strip()
            drift.append(
                {
                    "file": rel,
                    "line": line_no,
                    "snippet": line_text,
                    "expected": actual,
                    "actual": captured,
                    "kind": kind_path,
                }
            )
    return drift


def main() -> int:
    """Parse args, dispatch to scan or audit."""
    parser = argparse.ArgumentParser(
        description="Audit bats/Pester counts vs stat callouts in docs"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan", help="emit JSON of current counts")
    sub.add_parser("audit", help="report stat-callout drift in known docs")
    args = parser.parse_args()

    root = repo_root()
    counts = gather_counts(root)

    if args.cmd == "scan":
        print(json.dumps(counts, indent=2))
        return 0

    if args.cmd == "audit":
        drift = audit(root, counts)
        if not drift:
            print(json.dumps({"counts": counts, "drift": []}, indent=2))
            return 0
        print(json.dumps({"counts": counts, "drift": drift}, indent=2))
        return 1

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
