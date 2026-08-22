#!/usr/bin/env -S uv run python3
"""
Validate skill files against the Claude Skills spec.

Targets `.claude/skills/*/SKILL.md` and `.github/skills/*/SKILL.md`. The spec
is published by Anthropic but the format is loaded by multiple agent runtimes
(Claude Code, GitHub Copilot CLI, etc.), so these constraints apply regardless
of which tool consumes the skill. Spec reference:

  - https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview

Rules (failing any prints an error and exits 1):

  Frontmatter:
    * The file must start with a YAML frontmatter block delimited by `---`.
    * The frontmatter must parse as YAML and be a mapping.

  `name`:
    * Required, non-empty string.
    * Maximum 64 characters.
    * Must match `^[a-z0-9-]+$` (lowercase letters, digits, hyphens only).
    * Cannot contain XML tags.
    * Cannot contain the reserved words "anthropic" or "claude".

  `description`:
    * Required, non-empty string.
    * Maximum 1024 characters.
    * Cannot contain XML tags.

Why this hook exists: agent runtimes differ in how strictly they enforce the
spec. Claude Code is lenient about over-cap descriptions and loads the skill
anyway; GitHub Copilot CLI strictly validates and silently drops the skill
directory from its registry (e.g., `~/.copilot/skills/`) on sync. Catching
violations at commit time prevents that asymmetric, silent-failure regression
(see design/lessons.md L-011).

Usage:
    # Pre-commit invokes the script directly (entry: tests/hooks/check_skills.py,
    # language: script), relying on the `#!/usr/bin/env -S uv run python3`
    # shebang to resolve the PyYAML dep from the project venv. This is why
    # `repo_checks.yml` sets uv up before prek runs: the CI runner has no uv
    # and no system PyYAML, so without it the hook dies in the shebang.
    tests/hooks/check_skills.py .claude/skills/foo/SKILL.md ...
    tests/hooks/check_skills.py                  # scan every SKILL.md in repo

    # Manual debugging from a venv where PyYAML is already importable:
    python3 -m hooks.check_skills [files ...]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

NAME_MAX = 64
DESCRIPTION_MAX = 1024
NAME_PATTERN = re.compile(r"^[a-z0-9-]+$")
XML_TAG_PATTERN = re.compile(r"<\/?[A-Za-z][^>]*>")
RESERVED_NAME_WORDS = ("anthropic", "claude")


def extract_frontmatter(text: str) -> tuple[str | None, str | None]:
    """
    Return (yaml_block, error_message). Exactly one is None.

    The frontmatter block is the text between the first two `---` fences,
    matching what `---`-delimited YAML frontmatter parsers (mkdocs, hugo,
    jekyll, Obsidian) accept. A fence is a line that is exactly `---`, so a
    body horizontal rule (`----`) or a `---`-prefixed sentence is not mistaken
    for the closing fence.

    Line numbers in any downstream YAML error refer to the returned block,
    i.e. line 1 is the first line after the opening fence.
    """
    lines = text.split("\n")
    if lines[0].rstrip("\r") != "---":
        return None, "missing YAML frontmatter (file must start with '---')"
    for idx in range(1, len(lines)):
        if lines[idx].rstrip("\r") == "---":
            return "\n".join(lines[1:idx]), None
    return None, "missing closing '---' fence for YAML frontmatter"


def parse_frontmatter(yaml_block: str) -> tuple[dict[str, object] | None, str | None]:
    """Parse the YAML frontmatter block; reject anything that isn't a mapping."""
    try:
        data = yaml.safe_load(yaml_block)
    except yaml.YAMLError as exc:
        return None, f"YAML parse error in frontmatter: {exc}"
    if data is None:
        return None, "frontmatter is empty"
    if not isinstance(data, dict):
        return None, f"frontmatter must be a YAML mapping, got {type(data).__name__}"
    return data, None


def validate_name(value: object) -> list[str]:
    """Check `name` field against Claude Skills spec rules."""
    errors: list[str] = []
    if value is None:
        return ["missing required field 'name'"]
    if not isinstance(value, str):
        return [f"'name' must be a string, got {type(value).__name__}"]
    if not value:
        return ["'name' must be non-empty"]
    if len(value) > NAME_MAX:
        errors.append(f"'name' is {len(value)} chars, max allowed is {NAME_MAX}")
    if not NAME_PATTERN.match(value):
        errors.append(
            f"'name' {value!r} must match [a-z0-9-]+ "
            "(lowercase letters, digits, hyphens only)"
        )
    if XML_TAG_PATTERN.search(value):
        errors.append(f"'name' {value!r} contains an XML tag")
    lower = value.lower()
    for word in RESERVED_NAME_WORDS:
        if word in lower:
            errors.append(f"'name' {value!r} contains reserved word {word!r}")
    return errors


def validate_description(value: object) -> list[str]:
    """Check `description` field against Claude Skills spec rules."""
    if value is None:
        return ["missing required field 'description'"]
    if not isinstance(value, str):
        return [f"'description' must be a string, got {type(value).__name__}"]
    if not value.strip():
        return ["'description' must be non-empty"]
    errors: list[str] = []
    if len(value) > DESCRIPTION_MAX:
        errors.append(
            f"'description' is {len(value)} chars, max allowed is {DESCRIPTION_MAX}"
        )
    if XML_TAG_PATTERN.search(value):
        errors.append("'description' contains an XML tag")
    return errors


def check_file(skill_file: Path) -> list[str]:
    """Validate a single SKILL.md; return a list of error messages (empty = OK)."""
    try:
        text = skill_file.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"could not read file: {exc}"]

    yaml_block, fm_error = extract_frontmatter(text)
    if fm_error is not None:
        return [fm_error]
    assert yaml_block is not None

    data, parse_error = parse_frontmatter(yaml_block)
    if parse_error is not None:
        return [parse_error]
    assert data is not None

    return validate_name(data.get("name")) + validate_description(
        data.get("description")
    )


SKILL_ROOTS = (Path(".claude") / "skills", Path(".github") / "skills")


def _under_skill_root(path: Path) -> bool:
    """
    True if *path* is `<skills root>/<skill dir>/SKILL.md`.

    A substring test (`".claude/skills/" in str(path)`) accepts any path that
    merely contains the fragment, so require the real shape: the two components
    above the file have to be a skills root. Paths inside the repo are anchored
    at the repo root too, which rejects a nested `docs/.claude/skills/...`,
    while an absolute path from outside the repo still validates on shape alone
    so a skill elsewhere on disk can be checked by hand.
    """
    parts = path.parts
    if len(parts) < 4 or parts[-1] != "SKILL.md":
        return False
    if Path(*parts[-4:-2]) not in SKILL_ROOTS:
        return False
    try:
        relative = path.resolve().relative_to(Path.cwd().resolve())
    except (OSError, ValueError):
        return True
    return relative.parent.parent in SKILL_ROOTS


def discover_skill_files(repo_root: Path) -> list[Path]:
    """Find every SKILL.md under any recognized skills root in the repo."""
    found: list[Path] = []
    for root in SKILL_ROOTS:
        skills_root = repo_root / root
        if not skills_root.is_dir():
            continue
        found.extend(p for p in skills_root.glob("*/SKILL.md") if p.is_file())
    return sorted(found)


def main(argv: list[str]) -> int:
    """Validate frontmatter of every passed (or discovered) SKILL.md."""
    if argv:
        targets = [Path(p) for p in argv]
    else:
        targets = discover_skill_files(Path.cwd())

    skill_files = [
        p
        for p in targets
        if p.is_file() and p.name == "SKILL.md" and _under_skill_root(p)
    ]
    if not skill_files:
        return 0

    failed = 0
    for skill_file in skill_files:
        errors = check_file(skill_file)
        if errors:
            failed += 1
            print(f"{skill_file}:", file=sys.stderr)
            for err in errors:
                print(f"  {err}", file=sys.stderr)

    if failed:
        print(
            f"\n{failed} SKILL.md file(s) failed Claude Skills spec validation.\n"
            "See https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
