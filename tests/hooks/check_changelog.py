"""
Pre-commit hook: validate CHANGELOG.md structure and require updates.

1. ## [Unreleased] must be the first ## heading.
2. Tagged headings must use pure semver: ## [<major>.<minor>.<patch>] - YYYY-MM-DD
   (no "v" prefix - the release pipeline breaks on it).
3. Dates must be valid calendar dates in reverse chronological order.
4. If any staged file matches a runtime path pattern, CHANGELOG.md must have
   content under ## [Unreleased].

# :example
python3 -m tests.hooks.check_changelog nix/setup.sh
"""

import re
import sys
from datetime import date
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CHANGELOG = REPO_ROOT / "CHANGELOG.md"

RUNTIME_PATTERNS = (
    "nix/",
    ".assets/lib/",
    ".assets/config/",
    ".assets/setup/",
    ".assets/provision/",
    "wsl/",
)

SEMVER_HEADING = re.compile(r"^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})\s*$")


def _parse_date(date_str: str) -> date | None:
    try:
        return date.fromisoformat(date_str)
    except ValueError:
        return None


def validate_headings(changelog: Path) -> list[str]:
    """Check that ## headings follow the required format."""
    if not changelog.exists():
        return []
    errors: list[str] = []
    lines = changelog.read_text().splitlines()
    h2_headings = [
        (i + 1, line) for i, line in enumerate(lines) if line.startswith("## ")
    ]

    if not h2_headings:
        return []

    # first ## must be [Unreleased]
    lineno, first = h2_headings[0]
    if not re.match(r"^## \[Unreleased\]\s*$", first):
        errors.append(
            f"  line {lineno}: first ## heading must be '## [Unreleased]', got: {first}"
        )

    # remaining ## headings must be pure semver with valid dates in descending order
    prev_date: date | None = None
    for lineno, line in h2_headings[1:]:
        if re.match(r"^## \[Unreleased\]", line):
            errors.append(f"  line {lineno}: duplicate [Unreleased] heading")
            continue
        m = SEMVER_HEADING.match(line)
        if not m:
            errors.append(
                f"  line {lineno}: invalid version heading: {line}\n"
                f"           expected: ## [<major>.<minor>.<patch>] - YYYY-MM-DD"
            )
            continue
        d = _parse_date(m.group(2))
        if d is None:
            errors.append(f"  line {lineno}: invalid date '{m.group(2)}' in: {line}")
            continue
        if prev_date is not None and d > prev_date:
            errors.append(
                f"  line {lineno}: date {d} is later than previous release {prev_date}"
            )
        prev_date = d

    return errors


def has_unreleased_content(changelog: Path) -> bool:
    if not changelog.exists():
        return False
    lines = changelog.read_text().splitlines()
    in_unreleased = False
    for line in lines:
        if re.match(r"^## \[Unreleased\]", line):
            in_unreleased = True
            continue
        if in_unreleased:
            if re.match(r"^## \[", line):
                break
            if line.strip():
                return True
    return False


def _staged_files() -> set[str]:
    import subprocess

    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only"],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    return set(result.stdout.splitlines())


def main(argv: list[str]) -> int:
    rc = 0

    # always validate heading structure when CHANGELOG.md is in scope
    heading_errors = validate_headings(CHANGELOG)
    if heading_errors:
        print("ERROR: CHANGELOG.md heading format violations:", file=sys.stderr)
        for err in heading_errors:
            print(err, file=sys.stderr)
        rc = 1

    # check unreleased content when runtime files are staged
    runtime_files = [f for f in argv if any(f.startswith(p) for p in RUNTIME_PATTERNS)]
    if runtime_files:
        staged = _staged_files()
        if any(f in staged for f in runtime_files):
            if not has_unreleased_content(CHANGELOG) and "CHANGELOG.md" not in staged:
                print(
                    "ERROR: runtime files changed but CHANGELOG.md has no entries "
                    "under ## [Unreleased].",
                    file=sys.stderr,
                )
                print("  Changed runtime files:", file=sys.stderr)
                for f in runtime_files[:10]:
                    print(f"    {f}", file=sys.stderr)
                if len(runtime_files) > 10:
                    print(
                        f"    ... and {len(runtime_files) - 10} more", file=sys.stderr
                    )
                print(
                    "\nAdd a CHANGELOG entry or use the skip-changelog label to bypass.",
                    file=sys.stderr,
                )
                rc = 1

    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
