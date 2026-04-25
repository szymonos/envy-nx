"""
Pre-commit hook: require CHANGELOG.md update when runtime files change.

Fails if any staged file matches a runtime path pattern but CHANGELOG.md
has no content under the ## [Unreleased] heading.

# :example
python3 -m tests.hooks.check_changelog nix/setup.sh
"""

import re
import sys
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


def main(argv: list[str]) -> int:
    runtime_files = [f for f in argv if any(f.startswith(p) for p in RUNTIME_PATTERNS)]
    if not runtime_files:
        return 0

    if has_unreleased_content(CHANGELOG):
        return 0

    print(
        "ERROR: runtime files changed but CHANGELOG.md has no entries "
        "under ## [Unreleased].",
        file=sys.stderr,
    )
    print("  Changed runtime files:", file=sys.stderr)
    for f in runtime_files[:10]:
        print(f"    {f}", file=sys.stderr)
    if len(runtime_files) > 10:
        print(f"    ... and {len(runtime_files) - 10} more", file=sys.stderr)
    print(
        "\nAdd a CHANGELOG entry or use the skip-changelog label to bypass.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
