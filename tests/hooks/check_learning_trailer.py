"""
Pre-commit hook (commit-msg stage): nudge for Codified-Learning trailer.

Fires only when the staged diff touches high-leverage paths AND the commit
message lacks both a `Codified-Learning:` trailer and a `# no-learning` skip
token. Exits 1 with multi-line guidance in that case; exits 0 otherwise.

The "warn" framing (vs check-changelog's hard requirement on every runtime
change) is achieved by keeping the high-leverage path set deliberately
narrow - most commits never trigger this hook, so when it does fire the
contributor knows it's because they touched something where a generalization
is genuinely worth capturing.

# :example
python3 -m tests.hooks.check_learning_trailer .git/COMMIT_EDITMSG
"""

import os
import re
import subprocess
import sys
from pathlib import Path

# Tests override via env var to point at a temp git repo without copying the
# hook script. Matches the NX_LIB_DIR pattern documented in ARCHITECTURE.md.
REPO_ROOT = Path(
    os.environ.get("CHECK_LEARNING_REPO_ROOT") or Path(__file__).resolve().parents[2]
)

# Narrow set: load-bearing files where a fix usually teaches a generalization.
HIGH_LEVERAGE_RE = re.compile(
    r"^(\.assets/lib/nx_.*\.sh|nix/lib/phases/.*\.sh|tests/hooks/.*\.py)$"
)

TRAILER_RE = re.compile(
    r"^Codified-Learning(?:\([a-zA-Z0-9_-]+\))?:\s+\S", re.MULTILINE
)
SKIP_TOKEN_RE = re.compile(r"(?:^|\s)# no-learning(?:$|\s)", re.MULTILINE)


def _staged_files() -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only"],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    if result.returncode != 0:
        # Fail-closed: an unexpected git failure (bad cwd, broken repo, missing
        # .git) must not silently bypass the nudge on high-leverage changes.
        sys.stderr.write(
            f"check_learning_trailer: git diff failed (exit {result.returncode}): "
            f"{result.stderr.strip()}\n"
        )
        raise SystemExit(result.returncode)
    return [f for f in result.stdout.splitlines() if f]


def _read_commit_msg(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def main(argv: list[str]) -> int:
    """Nudge for a Codified-Learning trailer on high-leverage commits."""
    if not argv:
        # pre-commit always passes the commit-msg path; if missing, no-op.
        return 0

    commit_msg = _read_commit_msg(Path(argv[0]))
    if SKIP_TOKEN_RE.search(commit_msg) or TRAILER_RE.search(commit_msg):
        return 0

    hits = [f for f in _staged_files() if HIGH_LEVERAGE_RE.match(f)]
    if not hits:
        return 0

    print(
        "\n\033[33;1mCodified-Learning nudge:\033[0m this commit touches "
        "high-leverage files but has no `Codified-Learning:` trailer.",
        file=sys.stderr,
    )
    print("\nFiles that triggered the nudge:", file=sys.stderr)
    for f in hits[:10]:
        print(f"  - {f}", file=sys.stderr)
    if len(hits) > 10:
        print(f"  - ... and {len(hits) - 10} more", file=sys.stderr)

    print(
        "\nAdd a trailer to your commit message body, for example:\n\n"
        "    Codified-Learning: <one-line generalization the change teaches>\n\n"
        "After merge, `codify_learnings.yml` will append a numbered entry to\n"
        "`design/lessons.md`. See `CONTRIBUTING.md` for the full convention.\n\n"
        "If this commit genuinely teaches no generalization (trivial refactor,\n"
        "dependency bump, typo fix), add `# no-learning` anywhere in the body\n"
        "to opt out.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
