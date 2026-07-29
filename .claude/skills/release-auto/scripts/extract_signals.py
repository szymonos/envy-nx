#!/usr/bin/env -S uv run python3
"""
Bundled helpers for /release-auto.

Subcommands: signals, architecture, preflight-wip.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

LINT_FIX_RE = re.compile(
    r"(?:fix|fixup|fix up)\s*(?:lint|hook|linter|format|whitespace|trailing)",
    re.IGNORECASE,
)
CORRECTION_RE = re.compile(
    r"^(?:fix:|revert:|actually|no,|oops|wrong)",
    re.IGNORECASE,
)

ARCHITECTURE_SECTIONS = {
    "scope_system": (
        None,
        [".assets/lib/scopes.", ".assets/lib/nx_scope.sh", "nix/scopes/"],
    ),
    "nx_cli": (
        None,
        [".assets/lib/nx", ".assets/config/shell_cfg/completions."],
    ),
    "phase_orchestration": (
        None,
        ["nix/lib/phases/", "nix/setup.sh"],
    ),
    "hook_inventory": (
        None,
        [".pre-commit-config.yaml", "tests/hooks/"],
    ),
    "config_templates": (
        None,
        [".assets/config/"],
    ),
}


def _run(cmd: list[str], **kwargs: object) -> str:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    except FileNotFoundError:
        # Executable not on PATH - treat as a soft failure so callers get "" and
        # can surface a clean error rather than a traceback (e.g. git missing).
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def _emit(payload: dict[str, object], code: int = 0) -> int:
    """Emit a JSON payload to stdout (indent=2) and return the exit code."""
    json.dump(payload, sys.stdout, indent=2)
    print()
    return code


def _commits_since(base: str) -> list[dict[str, str]]:
    log = _run(["git", "log", "--format=%H|%s", f"{base}..HEAD"])
    if not log:
        return []
    commits = []
    for line in log.splitlines():
        if "|" not in line:
            continue
        sha, subject = line.split("|", 1)
        commits.append({"sha": sha.strip(), "subject": subject.strip()})
    return commits


def _files_in_commit(sha: str) -> list[str]:
    out = _run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", sha])
    return [f for f in out.splitlines() if f] if out else []


def _changed_files_since(base: str) -> list[str]:
    out = _run(["git", "diff", "--name-only", f"{base}..HEAD"])
    return [f for f in out.splitlines() if f] if out else []


def _next_lesson_id(lessons_path: Path) -> int:
    if not lessons_path.exists():
        return 1
    text = lessons_path.read_text(encoding="utf-8", errors="replace")
    ids = [int(m.group(1)) for m in re.finditer(r"^## L-(\d{3})", text, re.MULTILINE)]
    return (max(ids) + 1) if ids else 1


def _existing_lessons(lessons_path: Path) -> list[str]:
    if not lessons_path.exists():
        return []
    text = lessons_path.read_text(encoding="utf-8", errors="replace")
    return re.findall(r"^## L-\d{3} - .+$", text, re.MULTILINE)


def cmd_signals(args: argparse.Namespace) -> int:
    """Extract learning signals from WIP history."""
    base = args.base or _run(["git", "merge-base", "main", "HEAD"])
    if not base:
        return _emit({"error": "Could not determine merge-base"}, code=1)

    lessons_path = Path(args.lessons or "design/lessons.md")

    commits = _commits_since(base)
    if not commits:
        json.dump(
            {
                "signals": [],
                "next_lesson_id": _next_lesson_id(lessons_path),
                "existing_entries": _existing_lessons(lessons_path),
                "lessons_exists": lessons_path.exists(),
            },
            sys.stdout,
            indent=2,
        )
        print()
        return 0

    file_counts: dict[str, int] = {}
    for c in commits:
        for f in _files_in_commit(c["sha"]):
            file_counts[f] = file_counts.get(f, 0) + 1

    signals = []

    repeated = [
        {"file": f, "commit_count": n}
        for f, n in sorted(file_counts.items(), key=lambda x: -x[1])
        if n >= 3
    ]
    if repeated:
        signals.append({"type": "repeated_edits", "items": repeated})

    lint_fixes = [
        {"sha": c["sha"][:7], "subject": c["subject"]}
        for c in commits
        if LINT_FIX_RE.search(c["subject"])
    ]
    if lint_fixes:
        signals.append({"type": "lint_fixes", "items": lint_fixes})

    corrections = [
        {"sha": c["sha"][:7], "subject": c["subject"]}
        for c in commits
        if CORRECTION_RE.match(c["subject"])
    ]
    if corrections:
        signals.append({"type": "corrections", "items": corrections})

    next_id = _next_lesson_id(lessons_path)
    existing = _existing_lessons(lessons_path)

    result = {
        "signals": signals,
        "next_lesson_id": next_id,
        "existing_entries": existing,
        "lessons_exists": lessons_path.exists(),
    }

    json.dump(result, sys.stdout, indent=2)
    print()
    return 0


def cmd_preflight_wip(args: argparse.Namespace) -> int:
    """
    Self-applying WIP guard: print 'created-wip' or 'skip' and act accordingly.

    By default (no flag), this subcommand BOTH decides AND acts: if a WIP commit
    is needed, it runs `git add -A && git commit --no-verify -m "WIP for review"`
    itself, then prints 'created-wip' on stdout. If the tree is already clean or
    the branch is at parity with the base, it prints 'skip'. The agent's job is
    one line: run the command. No stdout parsing, no conditional follow-up
    commands - that manual follow-up was the failure mode this design eliminates
    (an agent that reasoned its way past the commit and reviewed nothing).

    `--dry-run` restores the old behavior: print 'create-wip' or 'skip' but do
    not commit. Useful for tests and for callers that want to inspect first.

    Guards against the failure mode where /second-opinion silently reports
    "no findings" because git diff <base>..HEAD is empty - either because
    the branch is at parity with the base and all work is in the dirty
    tree, OR because the dirty tree contains review-relevant changes that
    aren't visible to the committed diff. Either way, the fix is one
    throwaway WIP commit; Phase 4's soft-reset dissolves it.

    Uses git status --porcelain (not git diff --quiet HEAD) so untracked
    files trip the guard too - a brand-new file on a fresh branch is
    invisible to git diff.
    """
    base = args.base
    if not base:
        # Default: merge-base with main. Same target the signals/architecture
        # subcommands use when --base is omitted.
        base = _run(["git", "merge-base", "main", "HEAD"])
    if not base:
        print("could not resolve base; pass --base <last-tag>", file=sys.stderr)
        return 1
    base_sha = _run(["git", "rev-parse", base])
    head = _run(["git", "rev-parse", "HEAD"])
    porcelain = _run(["git", "status", "--porcelain", "--untracked-files=all"])
    if not base_sha or not head:
        print("git rev-parse failed", file=sys.stderr)
        return 1
    dirty = bool(porcelain)
    at_parity = base_sha == head
    if not dirty and at_parity:
        print("skip")
        print(
            "branch clean and at parity with base - nothing to review",
            file=sys.stderr,
        )
        return 0
    if not dirty:
        print("skip")
        print(
            "working tree clean - existing commits ARE the review scope",
            file=sys.stderr,
        )
        return 0
    reason = (
        "branch at parity with base AND working tree dirty"
        if at_parity
        else "branch has commits ahead of base AND working tree dirty - "
        "WIP needed so /second-opinion sees committed + uncommitted together"
    )
    if args.dry_run:
        print("create-wip")
        print(reason, file=sys.stderr)
        return 0
    add_rc = subprocess.run(
        ["git", "add", "-A"], capture_output=True, text=True, check=False
    )
    if add_rc.returncode != 0:
        print(f"git add -A failed: {add_rc.stderr.strip()}", file=sys.stderr)
        return 1
    commit_rc = subprocess.run(
        ["git", "commit", "--no-verify", "-m", "WIP for review"],
        capture_output=True,
        text=True,
        check=False,
    )
    if commit_rc.returncode != 0:
        err = commit_rc.stderr.strip() or commit_rc.stdout.strip()
        print(f"git commit failed: {err}", file=sys.stderr)
        return 1
    print("created-wip")
    print(f"{reason} - WIP commit created", file=sys.stderr)
    return 0


def cmd_architecture(args: argparse.Namespace) -> int:
    """Check ARCHITECTURE.md for staleness against the branch diff."""
    base = args.base or _run(["git", "merge-base", "main", "HEAD"])
    if not base:
        return _emit({"error": "Could not determine merge-base"}, code=1)

    arch_path = Path("ARCHITECTURE.md")
    if not arch_path.exists():
        json.dump(
            {"stale_sections": [], "architecture_exists": False}, sys.stdout, indent=2
        )
        print()
        return 0

    changed_files = _changed_files_since(base)
    stale = []

    for section_name, (_, path_prefixes) in ARCHITECTURE_SECTIONS.items():
        if path_prefixes:
            touches_section = any(
                any(f.startswith(prefix) for prefix in path_prefixes)
                for f in changed_files
            )
            if touches_section:
                stale.append(section_name)

    result = {
        "stale_sections": stale,
        "architecture_exists": True,
        "changed_files_count": len(changed_files),
    }

    json.dump(result, sys.stdout, indent=2)
    print()
    return 0


def main() -> int:
    """CLI entry point for signal extraction and architecture staleness check."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sig = sub.add_parser("signals", help="Extract learning signals from WIP history")
    sig.add_argument(
        "--base", help="Git ref to diff against (default: merge-base with main)"
    )
    sig.add_argument(
        "--lessons", help="Path to lessons.md (default: design/lessons.md)"
    )

    arch = sub.add_parser("architecture", help="Check ARCHITECTURE.md for staleness")
    arch.add_argument(
        "--base", help="Git ref to diff against (default: merge-base with main)"
    )

    pf = sub.add_parser(
        "preflight-wip",
        help=(
            "Self-applying WIP guard for Phase 3.5: commits dirty work itself "
            "(use --dry-run to inspect without committing)."
        ),
    )
    pf.add_argument(
        "--base", help="Git ref to diff against (default: merge-base with main)"
    )
    pf.add_argument(
        "--dry-run",
        action="store_true",
        help="Print 'create-wip'/'skip' but do NOT commit (legacy behavior).",
    )

    args = parser.parse_args()

    if args.command == "signals":
        return cmd_signals(args)
    if args.command == "architecture":
        return cmd_architecture(args)
    if args.command == "preflight-wip":
        return cmd_preflight_wip(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
