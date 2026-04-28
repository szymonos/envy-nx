"""
Check shell_cfg shell scripts for zsh compatibility.

shell_cfg files (.assets/config/shell_cfg/*.sh) are sourced in both .bashrc
and .zshrc.  This hook catches patterns that break or behave incorrectly
in zsh:

- Bare function definitions (`name() {`) - zsh expands aliases during
  parsing, so `function name() {` is required to suppress expansion.
- Numeric array subscripts - zsh arrays are 1-based (bash is 0-based).
- Bash-only variables/builtins (BASH_SOURCE, compgen, COMP_WORDS, etc.)
  that must be inside a `[ -n "$BASH_VERSION" ]` guard.

Optionally runs `zsh -n` (syntax check) when zsh is available.

# :example
python3 -m tests.hooks.check_zsh_compat .assets/config/shell_cfg/aliases_git.sh
python3 -m tests.hooks.check_zsh_compat
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

# ---------------------------------------------------------------------------
# Checked file patterns (shell_cfg files sourced in both bash and zsh)
# ---------------------------------------------------------------------------
SHELL_CFG_PATTERNS: tuple[str, ...] = (".assets/config/shell_cfg/*.sh",)

# ---------------------------------------------------------------------------
# Rules: each is (compiled regex, human description, guarded)
#   guarded=False  → always flag (code should be rewritten)
#   guarded=True   → skip when inside a BASH_VERSION guard block
# ---------------------------------------------------------------------------


class Rule(NamedTuple):
    pattern: re.Pattern[str]
    description: str
    guarded: bool = False


RULES: tuple[Rule, ...] = (
    # -- always flag (rewrite needed) ---------------------------------------
    Rule(
        re.compile(r"^\s*(?!function\s)[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{"),
        "bare function definition - use `function name() {` "
        "to prevent zsh alias expansion conflicts",
    ),
    Rule(
        re.compile(r"\$\{?[a-zA-Z_]\w*\[\s*[0-9]"),
        "numeric array subscript - zsh arrays are 1-based; "
        "avoid indexed arrays or guard with BASH_VERSION",
        guarded=True,
    ),
    # -- guarded (need BASH_VERSION check) ----------------------------------
    Rule(
        re.compile(r"\bBASH_SOURCE\b"),
        "BASH_SOURCE does not exist in zsh - "
        'guard with [ -n "$BASH_VERSION" ] or add fallback',
        guarded=True,
    ),
    Rule(
        re.compile(r"\bBASH_REMATCH\b"),
        "BASH_REMATCH does not exist in zsh (use $match) - "
        'guard with [ -n "$BASH_VERSION" ]',
        guarded=True,
    ),
    Rule(
        re.compile(r"\bcompgen\b"),
        'compgen is a bash-only builtin - guard with [ -n "$BASH_VERSION" ]',
        guarded=True,
    ),
    Rule(
        re.compile(r"\bcomplete\s+-[FW]"),
        'complete is a bash-only builtin - guard with [ -n "$BASH_VERSION" ]',
        guarded=True,
    ),
    Rule(
        re.compile(r"\b(COMP_WORDS|COMP_CWORD|COMPREPLY)\b"),
        'bash-only completion variable - guard with [ -n "$BASH_VERSION" ]',
        guarded=True,
    ),
)

# ---------------------------------------------------------------------------
# Guard detection patterns
# ---------------------------------------------------------------------------
_RE_IF = re.compile(r"^\s*(if|elif)\b")
_RE_IF_BASH = re.compile(r"BASH_VERSION")
_RE_FI = re.compile(r"^\s*fi\b")


def _resolve_shell_cfg_files(repo_root: Path) -> set[Path]:
    """Resolve glob patterns to actual files under repo_root."""
    files: set[Path] = set()
    for pattern in SHELL_CFG_PATTERNS:
        for match in repo_root.glob(pattern):
            if match.is_file():
                files.add(match)
    return files


def check_file(filepath: Path) -> list[str]:
    """Check a single file for zsh compatibility violations."""
    problems: list[str] = []
    try:
        lines = filepath.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return problems

    in_colon_heredoc = False
    if_nesting = 0
    bash_guard_depth = 0

    for lineno, line in enumerate(lines, start=1):
        stripped = line.lstrip()

        # track : '...' comment blocks (used for runnable examples)
        if not in_colon_heredoc and stripped.startswith(": '"):
            in_colon_heredoc = True
            continue
        if in_colon_heredoc:
            if stripped.rstrip() == "'":
                in_colon_heredoc = False
            continue

        # skip comments and lines with inline suppression
        if stripped.startswith("#"):
            continue
        if "# zsh-ok" in line:
            continue

        # track if/fi nesting for BASH_VERSION guard detection
        if _RE_IF.match(stripped):
            if_nesting += 1
            if _RE_IF_BASH.search(stripped):
                bash_guard_depth = if_nesting
        elif _RE_FI.match(stripped):
            if if_nesting == bash_guard_depth:
                bash_guard_depth = 0
            if_nesting -= 1

        in_guard = bash_guard_depth > 0

        for rule in RULES:
            if rule.guarded and in_guard:
                continue
            if rule.pattern.search(line):
                rel = filepath.as_posix()
                problems.append(f"{rel}:{lineno}: {rule.description}")
    return problems


def _zsh_syntax_check(filepath: Path) -> list[str]:
    """Run zsh -n syntax check on a file. Returns problems or empty list."""
    try:
        result = subprocess.run(
            ["zsh", "-n", str(filepath)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            rel = filepath.as_posix()
            return [f"{rel}: zsh -n: {result.stderr.strip()}"]
    except (FileNotFoundError, subprocess.TimeoutExpired):  # fmt: skip
        pass
    return []


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parents[2]
    cfg_files = _resolve_shell_cfg_files(repo_root)

    if not cfg_files:
        return 0

    # if filenames passed, filter to shell_cfg only; otherwise check all
    if argv:
        targets = [Path(f).resolve() for f in argv if Path(f).resolve() in cfg_files]
    else:
        targets = sorted(cfg_files)

    if not targets:
        return 0

    problems: list[str] = []
    has_zsh = shutil.which("zsh") is not None

    for filepath in targets:
        # make paths relative for readable output
        try:
            rel = filepath.relative_to(repo_root)
        except ValueError:
            rel = filepath
        check_path = rel if rel.exists() else filepath
        problems.extend(check_file(check_path))
        if has_zsh:
            problems.extend(_zsh_syntax_check(check_path))

    if problems:
        print("Zsh compatibility violations:", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print(
            f"\n{len(problems)} violation(s) found. "
            "See CONTRIBUTING.md for shell_cfg zsh compatibility rules.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
