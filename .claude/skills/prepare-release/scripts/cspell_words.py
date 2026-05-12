#!/usr/bin/env python3
"""
Detect cspell-unknown words in release docs and add approved ones to project-words.txt.

Two modes:
  scan: list every unknown word cspell flags across changed *.md since <last-tag>,
        with file / line / surrounding context. Output is JSON on stdout so the agent
        can classify each entry (proper-name -> add, prose typo -> fix the source file).
  add:  take positional words, normalize (lowercase, dedupe), insert into
        project-words.txt and re-sort. Idempotent.

Usage:
  cspell_words.py scan
  cspell_words.py scan --since v1.8.0          # override auto-detected base ref
  cspell_words.py add backrefs idna pathspec
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

CSPELL_LINE_RE = re.compile(
    r"^(?P<file>[^:]+):(?P<line>\d+):(?P<col>\d+)"
    r"\s+-\s+Unknown word\s+\((?P<word>[^)]+)\)"
)
CONTEXT_PAD = 60


def repo_root() -> Path:
    """Return the git top-level directory (or the script's project root as fallback)."""
    out = run_git(["rev-parse", "--show-toplevel"])
    return Path(out) if out else Path(__file__).resolve().parents[4]


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


def changed_md_files(base: str, root: Path) -> list[Path]:
    """Union of *.md files changed since <base>, plus uncommitted and staged *.md."""
    seen: set[str] = set()

    def collect(args: list[str]) -> None:
        out = run_git(args)
        for rel in out.splitlines():
            rel = rel.strip()
            if rel.endswith(".md"):
                seen.add(rel)

    if base:
        collect(["diff", "--name-only", f"{base}..HEAD", "--", "*.md"])
    collect(["diff", "--name-only", "--", "*.md"])  # unstaged
    collect(["diff", "--cached", "--name-only", "--", "*.md"])  # staged

    return sorted({(root / p) for p in seen if (root / p).is_file()})


def run_cspell(files: list[Path], root: Path) -> str:
    """
    Invoke cspell via prek (preferred) or the bare binary.

    Returns combined stdout+stderr. cspell exits non-zero when it finds unknown
    words; we always read the output regardless.
    """
    if not files:
        return ""
    rels = [str(f.relative_to(root)) for f in files]
    cmds: list[list[str]] = [
        ["prek", "run", "cspell", "--files", *rels],
        ["cspell", "--no-progress", "--no-summary", *rels],
    ]
    last_err = ""
    for cmd in cmds:
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, cwd=root, check=False
            )
            return (result.stdout or "") + (result.stderr or "")
        except FileNotFoundError as e:
            last_err = str(e)
            continue
    print(f"ERROR: could not invoke cspell ({last_err})", file=sys.stderr)
    return ""


def context_for(file_path: Path, line_no: int, word: str) -> str:
    """Return ~CONTEXT_PAD chars on either side of the unknown word."""
    try:
        lines = file_path.read_text().splitlines()
    except OSError:
        return ""
    if line_no < 1 or line_no > len(lines):
        return ""
    line = lines[line_no - 1]
    idx = line.lower().find(word.lower())
    if idx < 0:
        return line.strip()
    start = max(0, idx - CONTEXT_PAD)
    end = min(len(line), idx + len(word) + CONTEXT_PAD)
    snippet = line[start:end].strip()
    prefix = "..." if start > 0 else ""
    suffix = "..." if end < len(line) else ""
    return f"{prefix}{snippet}{suffix}"


def cmd_scan(args: argparse.Namespace) -> int:
    """Run cspell over changed *.md and emit unknown words as JSON on stdout."""
    root = repo_root()
    base = args.since or run_git(["describe", "--tags", "--abbrev=0"])
    files = changed_md_files(base, root)
    if not files:
        print("[]")
        return 0

    raw = run_cspell(files, root)
    findings: dict[str, dict] = {}
    for raw_line in raw.splitlines():
        m = CSPELL_LINE_RE.match(raw_line.strip())
        if not m:
            continue
        word = m.group("word")
        if word in findings:
            continue
        file_rel = m.group("file")
        line_no = int(m.group("line"))
        file_abs = root / file_rel
        findings[word] = {
            "word": word,
            "file": file_rel,
            "line": line_no,
            "context": context_for(file_abs, line_no, word),
        }

    print(json.dumps(list(findings.values()), indent=2))
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    """Insert positional words into project-words.txt sorted; idempotent."""
    root = repo_root()
    words_path = root / "project-words.txt"
    if not words_path.is_file():
        print(f"ERROR: {words_path} not found", file=sys.stderr)
        return 1

    raw_lines = words_path.read_text().splitlines()
    existing = {line.strip().lower() for line in raw_lines if line.strip()}
    incoming = {w.strip().lower() for w in args.words if w.strip()}

    added = sorted(incoming - existing)
    already = sorted(incoming & existing)

    if not added:
        print("No new words to add.")
        if already:
            print(f"Already present: {', '.join(already)}")
        return 0

    merged = sorted(existing | incoming)
    words_path.write_text("\n".join(merged) + "\n")
    print(f"Added {len(added)} word(s): {', '.join(added)}")
    if already:
        print(f"Already present: {', '.join(already)}")
    return 0


def main() -> int:
    """Dispatch to scan or add mode based on parsed args."""
    parser = argparse.ArgumentParser(
        description=(
            "Scan release docs for cspell-unknown words; "
            "add approved ones to project-words.txt."
        )
    )
    sub = parser.add_subparsers(dest="mode", required=True)

    scan = sub.add_parser("scan", help="List unknown words in changed *.md files")
    scan.add_argument(
        "--since",
        default="",
        help="Base ref for the diff (default: latest tag from `git describe`)",
    )
    scan.set_defaults(func=cmd_scan)

    add = sub.add_parser("add", help="Add words to project-words.txt (sorted, deduped)")
    add.add_argument("words", nargs="+", help="Words to add")
    add.set_defaults(func=cmd_add)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
