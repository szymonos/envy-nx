#!/usr/bin/env python3
"""
Validate docs words.

Reads words from project-words.txt, checks if each word appears in any
markdown file in the repository, removes unused words, and writes back
a sorted, lowercase, deduplicated list.

The hook uses pass_filenames: false because pre-commit batches filenames
and this hook needs to see all .md files to make correct decisions.

Usage:
    python3 -m tests.hooks.validate_docs_words
"""

import json
import re
import subprocess
import sys
from pathlib import Path


def main() -> None:
    """Validate docs words against docs content."""
    root = Path(__file__).resolve().parent.parent.parent
    print(f"Project root: {root}")
    words_path = root / "project-words.txt"

    # read and normalize project words
    raw_lines = words_path.read_text().splitlines()
    words = sorted({line.strip().lower() for line in raw_lines if line.strip()})
    rel_path = words_path.relative_to(root)
    print(f"Reading project words from ./{rel_path} ({len(words)} words)")

    # read cspell ignorePaths to stay in sync
    cspell_path = root / ".cspell.json"
    exclude: set[str] = set()
    if cspell_path.exists():
        cfg = json.loads(cspell_path.read_text())
        exclude = set(cfg.get("ignorePaths", []))

    # gather every working-tree .md not excluded by .gitignore
    # (so brand-new untracked docs count too)
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        capture_output=True,
        text=True,
        cwd=root,
        check=True,
    )
    files = sorted(root / p for p in result.stdout.split("\0") if p.endswith(".md"))
    files = [
        f
        for f in files
        if not any(str(f.relative_to(root)).startswith(e.lstrip("./")) for e in exclude)
    ]
    print(f"Gathering files... ({len(files)} files)")

    # read all content + filenames into one string
    parts: list[str] = []
    for f in files:
        parts.append(f.name)
        parts.append(f.read_text())
    content = "\n".join(parts)

    # tokenize raw content first (cspell matches whole words before splitting)
    tokens = set(re.findall(r"[a-z][a-z0-9]*", content.lower()))

    # split camelCase/PascalCase and letter/digit boundaries (like cspell does)
    content = re.sub(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", content)
    content = re.sub(r"(?<=[a-zA-Z])(?=[0-9])|(?<=[0-9])(?=[a-zA-Z])", " ", content)
    tokens |= set(re.findall(r"[a-z]+", content.lower()))

    # keep only words that appear in the content
    valid_words = sorted(w for w in words if w in tokens)
    removed = set(words) - set(valid_words)

    # write back
    words_path.write_text("\n".join(valid_words) + "\n")

    # report
    if removed:
        print(f"Removed {len(removed)} unused word(s): {', '.join(sorted(removed))}")
    result = subprocess.run(
        ["git", "status", "--porcelain", str(words_path)],
        capture_output=True,
        text=True,
        cwd=root,
    )
    if result.stdout.strip():
        rel = words_path.relative_to(root)
        print(f"\033[33mThe file \033[4m./{rel}\033[24m has been updated.\033[0m")
    else:
        print("\033[32mAll project-words have been validated.\033[0m")


if __name__ == "__main__":
    sys.exit(main() or 0)
