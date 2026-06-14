r"""
Forbid bare `mv` / `cp` in shell scripts sourced into the user's interactive shell.

A user's `~/.bashrc` or `~/.zshrc` may define `alias mv='mv -i'` (or `-iv`) and
`alias cp='cp -i'` - common defenses against accidental clobber. These aliases
also fire when a function defined in our libraries calls `mv`/`cp` from the
same shell session, because `nx.sh`, `nx_pkg.sh`, `nx_scope.sh`, etc. are
*sourced* into the interactive shell (not run as subprocesses).

Concrete symptom: `nx install <pkg>` reaches `_nx_write_pkgs`, which writes
to a tempfile and then `mv "$tmp" packages.nix`. With `alias mv='mv -i'`
sourced, that becomes `mv -i "$tmp" packages.nix` and prompts the user with
`overwrite packages.nix?`. In a non-tty context (script, hook), the prompt
silently returns no input - `mv` exits non-zero, packages.nix is NEVER
updated, and the subsequent `nix profile upgrade` runs against stale state.

The fix is to prefix builtin overlay-prone commands with `command` (which
bypasses both aliases and shell functions) at every call site in the
interactively-sourced files. This hook is the lint-time enforcement so the
fix doesn't have to be re-learned every time a new function is added.

Why not also `rm`? On both BSD and GNU `rm`, `-f` always wins over `-i`,
so `rm -f` is safe even under `alias rm='rm -i'`. All current `rm` call
sites in scope use `-f`. If a bare `rm` is ever added, ShellCheck SC2115
catches the unguarded-variable subcase and code review catches the rest.

Allowed forms:
  - `command mv ...`           (recommended)
  - `\\mv ...`                 (also bypasses aliases, less idiomatic)
  - bare `mv ...  # alias-ok`  (explicit suppression, requires justification)

Inside comments, single-quoted strings, function definitions (`mv() { ... }`),
and variable assignments (`local mv=...`) - all skipped automatically.

# :example
python3 -m tests.hooks.check_no_aliased_builtins
# :run on specific files (as pre-commit passes them)
python3 -m tests.hooks.check_no_aliased_builtins .assets/lib/nx.sh
"""

import re
import sys
from pathlib import Path

from tests.hooks._file_scopes import ALIASED_BUILTINS_FILES

REPO_ROOT = Path(__file__).resolve().parents[2]

# Targets:
#   mv  - prompts under `alias mv='mv -i'` even with subsequent `-f`
#         on BSD; safe-by-construction wrapper is `command mv`.
#   cp  - same: BSD `cp -if` still prompts (GNU "last flag wins" doesn't
#         apply uniformly to cp), so always require `command cp`.
COMMANDS = ("mv", "cp")

# Match a bare command at a command position - line start (optional indent),
# after `; `, after `&& `, after `|| `, after `| `, after `( `, after `{ `,
# or after `then`/`else`/`do`. Group 1 captures the optional escape prefix
# (`command ` or backslash); when group 1 is non-empty the call is already
# wrapped and the hook skips it. Group 2 captures the bare command name
# (one of COMMANDS).
# Negative lookahead `(?!\()` skips function definitions like `mv() {`.
# Negative lookahead `(?!=)` skips variable assignments like `local mv=...`.
_CMD_RE = re.compile(
    r"(?:^|[\s;&|(){]|\bthen\s|\belse\s|\bdo\s)"  # command-position prefix
    r"((?:command\s+|\\)?)"  # optional escape (group 1)
    rf"\b({'|'.join(COMMANDS)})\b"  # the command (group 2)
    r"(?!\s*\()"  # not a function def (mv() { ... })
    r"(?!=)"  # not an assignment (local mv=...)
)
_SQUOTED_RE = re.compile(r"'[^']*'")
SUPPRESS_MARKER = "# alias-ok"


def _mask_squoted(line: str) -> str:
    """Blank out single-quoted strings so regex matches don't fire inside literals."""
    return _SQUOTED_RE.sub(lambda m: "'" + " " * (len(m.group(0)) - 2) + "'", line)


def _scan(path: Path) -> list[tuple[int, str, str]]:
    """Return [(lineno, command, line_text)] of unprotected mv/cp calls."""
    offenders: list[tuple[int, str, str]] = []
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return offenders

    in_colon_heredoc = False  # the `: '...'` runnable-examples block
    for i, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.lstrip()

        # Skip the runnable-examples block at the top of executable scripts.
        if not in_colon_heredoc and stripped.startswith(": '"):
            in_colon_heredoc = True
            continue
        if in_colon_heredoc:
            if stripped.rstrip() == "'":
                in_colon_heredoc = False
            continue

        if stripped.startswith("#"):
            continue
        if SUPPRESS_MARKER in raw:
            continue

        masked = _mask_squoted(raw)
        for m in _CMD_RE.finditer(masked):
            prefix, cmd = m.group(1), m.group(2)
            if prefix:  # already prefixed with `command ` or `\`
                continue
            offenders.append((i, cmd, raw.rstrip()))
    return offenders


def main(argv: list[str] | None = None) -> int:
    """Scan files passed by pre-commit (or the whole tree when run standalone)."""
    args = argv or []
    if args:
        files = [Path(p) for p in args if Path(p).is_file()]
    else:
        # Standalone: scan the file list from _file_scopes.py - the same
        # source the pre-commit `files:` regex is derived from.
        files = [
            REPO_ROOT / p for p in ALIASED_BUILTINS_FILES if (REPO_ROOT / p).is_file()
        ]

    failures: list[tuple[Path, int, str, str]] = []
    for f in files:
        for lineno, cmd, line in _scan(f):
            failures.append((f, lineno, cmd, line))

    if not failures:
        return 0

    print(
        "Forbidden pattern: bare `mv` / `cp` in interactively-sourced shell files.",
        file=sys.stderr,
    )
    print(
        "A user's `alias mv='mv -i'` or `alias cp='cp -i'` (set in their rc file)\n"
        "fires when our sourced functions call mv/cp, prompting and hanging the\n"
        "operation. Use `command mv` / `command cp` to bypass aliases and functions.\n",
        file=sys.stderr,
    )
    for path, lineno, cmd, line in failures:
        try:
            rel = path.resolve().relative_to(REPO_ROOT).as_posix()
        except ValueError:
            rel = path.as_posix()
        print(f"  {rel}:{lineno}: bare `{cmd}`: {line.strip()}", file=sys.stderr)

    print(
        "\nFixes (in order of preference):\n"
        "  1. Prefix with `command`: `command mv $tmp $dst`.\n"
        "  2. If the call genuinely should honor user aliases (rare in libraries),\n"
        "     append `# alias-ok` to the line as an explicit self-attestation.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
