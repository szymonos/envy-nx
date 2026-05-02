"""
Forbid `read ... </dev/tty` in shell scripts unless paired with a `# tty-ok`
suppression marker.

Why: `read -r reply </dev/tty` opens the SESSION's controlling terminal
directly, bypassing stdin redirects entirely. So `bash $SCRIPT </dev/null`
does NOT make /dev/tty unavailable - if the caller has a controlling tty
(interactive shell, prek under a terminal), the script blocks forever
waiting for input. The pattern silently passes in headless environments
(CI, no-tty containers) and silently hangs in interactive ones, which is
why it keeps getting reintroduced. See ARCHITECTURE.md §7.9.

Allowed forms:
  - `read -r reply </dev/tty  # tty-ok`        (acknowledged + guarded)
  - Inline comment anywhere on the same line as the `# tty-ok` marker

For every `read ... </dev/tty` line you add, you should also have one of:
  - An `--unattended` flag or env var that bypasses the prompt entirely
  - An `[ -t 0 ] || { ...; exit 0; }` guard earlier in the same code path
The `# tty-ok` marker is a self-attestation that you've handled
non-interactive callers correctly.

# :example
python3 -m tests.hooks.check_no_tty_read
# :run on specific files (as pre-commit passes them)
python3 -m tests.hooks.check_no_tty_read .assets/lib/foo.sh nix/configure/bar.sh
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# `read [opts...] varname [varname...] </dev/tty`
# Anchored on `read`; tolerates -r, -p "...", -t N, etc. before the redirect.
TTY_READ_RE = re.compile(r"\bread\b[^#\n]*</dev/tty\b")
SUPPRESS_MARKER = "# tty-ok"

# Files in scope: any shell script under the source dirs that could be sourced
# or executed at runtime. Tests are excluded - bats fixtures legitimately need
# to construct rc files that mention /dev/tty in string literals etc.
SCOPED_DIRS = (".assets/", "nix/", "wsl/", "modules/")


def _in_scope(path: Path) -> bool:
    rel = path.resolve().relative_to(REPO_ROOT).as_posix()
    if not any(rel.startswith(d) for d in SCOPED_DIRS):
        return False
    return path.suffix in {".sh", ".zsh", ".bash"}


def _scan(path: Path) -> list[tuple[int, str]]:
    """Return a list of (lineno, line_content) for unsuppressed offenders."""
    offenders: list[tuple[int, str]] = []
    try:
        # errors='replace' avoids UnicodeDecodeError on stray binary bytes
        # (rare in shell scripts but possible). Single OSError catch handles
        # missing/unreadable files; we silently skip those.
        text = path.read_text(errors="replace")
    except OSError:
        return offenders
    for i, line in enumerate(text.splitlines(), start=1):
        if not TTY_READ_RE.search(line):
            continue
        if SUPPRESS_MARKER in line:
            continue
        offenders.append((i, line.rstrip()))
    return offenders


def main(argv: list[str] | None = None) -> int:
    args = argv or []
    if args:
        # pre-commit invocation: only check files passed in
        files = [Path(p) for p in args if _in_scope(Path(p)) and Path(p).is_file()]
    else:
        # standalone invocation: scan all in-scope files in the repo
        files = []
        for d in SCOPED_DIRS:
            base = REPO_ROOT / d.rstrip("/")
            if base.is_dir():
                files.extend(p for p in base.rglob("*") if _in_scope(p))

    failures: list[tuple[Path, int, str]] = []
    for f in files:
        for lineno, line in _scan(f):
            failures.append((f, lineno, line))

    if not failures:
        return 0

    print(
        "Forbidden pattern: `read ... </dev/tty` without `# tty-ok` marker.",
        file=sys.stderr,
    )
    print(
        "This pattern bypasses stdin redirects and hangs in interactive shells.\n"
        "See ARCHITECTURE.md §7.9 for the full explanation and preferred fixes.\n",
        file=sys.stderr,
    )
    for path, lineno, line in failures:
        rel = path.resolve().relative_to(REPO_ROOT).as_posix()
        print(f"  {rel}:{lineno}: {line.strip()}", file=sys.stderr)

    print(
        "\nFixes (in order of preference):\n"
        "  1. Add an --unattended flag or env var bypassing the prompt entirely.\n"
        "  2. Guard with `[ -t 0 ] || { echo 'non-interactive'; exit 0; }` earlier\n"
        "     in the code path - then mark the read line with `# tty-ok`.\n"
        "  3. If the read is genuinely safe in your context (rare), append\n"
        "     `# tty-ok` to the read line as a self-attestation.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
