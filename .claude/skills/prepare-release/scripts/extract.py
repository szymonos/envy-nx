#!/usr/bin/env python3
"""
Extract CHANGELOG sections + git context for the /changelog-update skill.

Avoids the agent having to Read the full CHANGELOG.md (often 100+ KB). Emits
only the sections needed to compose a new release: the [Unreleased] body, the
target version's existing block (if any), the latest git tag, and a compact
git log + diff stat since that tag.

Usage:
    .claude/skills/changelog-update/scripts/extract.py --version 1.7.3
    python3 .claude/skills/changelog-update/scripts/extract.py --version 1.7.3
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SECTION_HEADER_RE = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\S+))?\s*$")


def parse_sections(text: str) -> dict[str, str]:
    """
    Map ``## [<id>]`` section ids to their body.

    Body is the lines between this header and the next ``##`` header.
    """
    sections: dict[str, list[str]] = {}
    current_id: str | None = None
    for line in text.splitlines():
        m = SECTION_HEADER_RE.match(line)
        if m:
            current_id = m.group(1)
            sections.setdefault(current_id, [])
        elif current_id is not None:
            sections[current_id].append(line)
    return {sid: "\n".join(lines).strip() for sid, lines in sections.items()}


def run_git(args: list[str]) -> str:
    """
    Run a git command from the current directory.

    Returns stdout (stripped) or empty string on failure.
    """
    try:
        result = subprocess.run(
            ["git", *args], capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError, FileNotFoundError:
        return ""


def main() -> int:
    """Parse args, read the CHANGELOG, emit chunks for /prepare-release."""
    parser = argparse.ArgumentParser(
        description="Extract CHANGELOG sections + git context for /changelog-update"
    )
    parser.add_argument(
        "--version", required=True, help="Target release version, e.g. 1.7.3"
    )
    parser.add_argument(
        "--changelog",
        default="CHANGELOG.md",
        help="Path to CHANGELOG.md (default: ./CHANGELOG.md)",
    )
    args = parser.parse_args()

    changelog_path = Path(args.changelog)
    if not changelog_path.is_file():
        print(f"ERROR: {changelog_path} not found", file=sys.stderr)
        return 1

    sections = parse_sections(changelog_path.read_text())
    unreleased = sections.get("Unreleased", "")
    existing = sections.get(args.version, "")

    last_tag = run_git(["describe", "--tags", "--abbrev=0"])
    commits = run_git(["log", "--oneline", f"{last_tag}..HEAD"]) if last_tag else ""
    diff_stat = run_git(["diff", "--stat", f"{last_tag}..HEAD"]) if last_tag else ""

    chunks = [
        ("LAST_TAG", last_tag or "[none]"),
        ("UNRELEASED", unreleased or "[empty]"),
        (f"EXISTING_{args.version}", existing or "[empty]"),
        ("COMMITS", commits or "[none]"),
        ("DIFF_STAT", diff_stat or "[none]"),
    ]
    for header, body in chunks:
        print(f"=== {header} ===")
        print(body)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
