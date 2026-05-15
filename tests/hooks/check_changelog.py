"""
Pre-commit hook: validate CHANGELOG.md structure and require updates.

1. ## [Unreleased] must be the first ## heading.
2. Tagged headings must use pure semver: ## [<major>.<minor>.<patch>] - YYYY-MM-DD
   (no "v" prefix - the release pipeline breaks on it).
3. Dates must be valid calendar dates in reverse chronological order.
4. If any staged file matches a runtime path pattern, CHANGELOG.md must have
   content under ## [Unreleased].

`### Section` mis-ordering inside a release is auto-fixed in place: the hook
reorders to the canonical SECTION_ORDER (Added -> Changed -> Fixed -> Removed
-> Security -> Deprecated), writes the file back, and exits non-zero so the
caller knows to re-stage. Notifying every time + asking the agent to retype
the same edit costs orders of magnitude more than just doing the swap. The
auto-fix refuses to run when the same `### Section` appears twice inside a
release, because that is a deleted-`## [version]`-header symptom and merging
the two would hide the actual cause; that case is reported as an error.

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

SECTION_ORDER = ("Added", "Changed", "Fixed", "Removed", "Security", "Deprecated")


def _parse_date(date_str: str) -> date | None:
    try:
        return date.fromisoformat(date_str)
    except ValueError:
        return None


def _validate_section_order(
    lines: list[str], h2_headings: list[tuple[int, str]]
) -> list[str]:
    """
    Check ### section order and detect duplicate sections within each release.

    The duplicate check exists because an Edit that drops a `## [version]`
    header silently merges two release sections, producing two `### Added`
    (etc.) under the surviving release. The order-only check would surface
    that as a confusing "Added must come before Changed" message; reporting
    the duplicate directly points at the actual root cause.
    """
    errors: list[str] = []
    order_index = {name: i for i, name in enumerate(SECTION_ORDER)}

    for idx, (h2_lineno, h2_line) in enumerate(h2_headings):
        end = h2_headings[idx + 1][0] if idx + 1 < len(h2_headings) else len(lines) + 1
        release = re.sub(r"^## \[(.+?)\].*", r"\1", h2_line)
        last_order = -1
        seen: dict[str, int] = {}
        for lineno in range(h2_lineno + 1, end):
            if lineno - 1 >= len(lines):
                break
            line = lines[lineno - 1]
            m = re.match(r"^### (\w+)", line)
            if not m:
                continue
            section = m.group(1)
            if section not in order_index:
                continue
            if section in seen:
                errors.append(
                    f"  line {lineno}: [{release}] duplicate '### {section}' "
                    f"(first at line {seen[section]}); a `## [version]` header "
                    f"may have been deleted between them"
                )
                # don't also flag the order violation that the duplicate causes
                continue
            seen[section] = lineno
            cur = order_index[section]
            if cur < last_order:
                prev_name = SECTION_ORDER[last_order]
                errors.append(
                    f"  line {lineno}: [{release}] '### {section}' must come "
                    f"before '### {prev_name}'"
                )
            last_order = cur

    return errors


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

    # ### sections within each release must follow: Added, Changed, Fixed
    errors.extend(_validate_section_order(lines, h2_headings))

    return errors


def has_unreleased_content(changelog: Path) -> bool:
    """Return True if CHANGELOG has any non-blank lines under ## [Unreleased]."""
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


def _reorder_release_block(block: list[str]) -> tuple[list[str], bool]:
    """
    Reorder ### sections within a single ## [...] release block to SECTION_ORDER.

    block[0] is the ## heading line; block[1:] is its body up to (but not
    including) the next ## heading. Sections not in SECTION_ORDER are kept
    in original order, after the known sections. If the same known section
    appears more than once, refuse to reorder - that is the
    "deleted ## [version] header" symptom and merging would hide the cause.

    Section bodies' trailing blank lines are owned by the BLOCK as a whole
    (the visual gap before the next `##` heading), not by whichever section
    happens to be last. Normalize each section to no trailing blanks, rejoin
    with a single blank separator, and re-append the block's original
    trailing blank count at the end. Without this, swapping the last and
    first sections would lose the inter-section blank line.

    Returns (new_block, changed).
    """
    h3_indices = [i for i, line in enumerate(block) if line.startswith("### ")]
    if len(h3_indices) < 2:
        return block, False

    # Block-level trailing blank lines (visual gap before next ##/EOF).
    trailing_blanks = 0
    for line in reversed(block):
        if line.strip() == "":
            trailing_blanks += 1
        else:
            break
    body_end = len(block) - trailing_blanks

    header_and_intro = block[: h3_indices[0]]

    sections: list[tuple[str, list[str]]] = []
    for idx, h3_start in enumerate(h3_indices):
        h3_end = h3_indices[idx + 1] if idx + 1 < len(h3_indices) else body_end
        m = re.match(r"^### (\w+)", block[h3_start])
        if not m:
            return block, False  # unparseable; refuse to fix
        section_lines = list(block[h3_start:h3_end])
        # Strip per-section trailing blanks; re-added by the joiner below.
        while section_lines and section_lines[-1].strip() == "":
            section_lines.pop()
        sections.append((m.group(1), section_lines))

    order_index = {name: i for i, name in enumerate(SECTION_ORDER)}
    known_names = [n for n, _ in sections if n in order_index]
    if len(known_names) != len(set(known_names)):
        return block, False  # duplicate; defer to validate_headings error

    known = [(n, body) for n, body in sections if n in order_index]
    unknown = [(n, body) for n, body in sections if n not in order_index]
    known_sorted = sorted(known, key=lambda x: order_index[x[0]])

    original_order = [n for n, _ in sections]
    new_order = [n for n, _ in known_sorted] + [n for n, _ in unknown]
    if original_order == new_order:
        return block, False

    out = list(header_and_intro)
    final = known_sorted + unknown
    for i, (_, body) in enumerate(final):
        out.extend(body)
        if i < len(final) - 1:
            out.append("")  # one blank line between sections
    out.extend([""] * trailing_blanks)
    return out, True


def reorder_sections(changelog: Path) -> bool:
    """
    Reorder ### sections inside every ## release in CHANGELOG.

    Returns True if the file was modified on disk.
    """
    if not changelog.exists():
        return False
    original = changelog.read_text()
    lines = original.splitlines()

    h2_indices = [i for i, line in enumerate(lines) if line.startswith("## ")]
    if not h2_indices:
        return False

    out: list[str] = list(lines[: h2_indices[0]])
    changed = False
    for idx, start in enumerate(h2_indices):
        end = h2_indices[idx + 1] if idx + 1 < len(h2_indices) else len(lines)
        new_block, block_changed = _reorder_release_block(lines[start:end])
        if block_changed:
            changed = True
        out.extend(new_block)

    if not changed:
        return False

    new_content = "\n".join(out)
    if original.endswith("\n"):
        new_content += "\n"
    changelog.write_text(new_content)
    return True


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
    """Validate CHANGELOG heading structure and Unreleased coverage."""
    rc = 0

    # auto-fix section ordering before validating - the order check then only
    # surfaces what the auto-fix legitimately can't repair (duplicates, etc.)
    if reorder_sections(CHANGELOG):
        print(
            "Auto-fixed CHANGELOG.md section order to "
            "Added -> Changed -> Fixed -> Removed -> Security -> Deprecated. "
            "Re-stage and re-run.",
            file=sys.stderr,
        )
        rc = 1

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
                    "\nAdd a CHANGELOG entry or use the skip-changelog label "
                    "to bypass.",
                    file=sys.stderr,
                )
                rc = 1

    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
