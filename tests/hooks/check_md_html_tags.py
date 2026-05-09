"""
Forbid unbalanced tag-like `<...` patterns in mkdocs-published Markdown.

Python-Markdown's HTML preprocessor runs BEFORE inline code-span
detection. A substring like `</dev/tty` inside backticks is still seen as
a malformed closing tag for element 'dev', and the preprocessor scans
forward looking for the closing '>' - silently eating subsequent table
rows, headings, or sections from the rendered page until it finds one.
**Backticks do NOT protect against this**; the HTML pass runs first.

This is a recurrence guard. Prior occurrence: `docs/standards.md` table
cell with `read </dev/tty` (CHANGELOG.md fix entry plus bug-073 in
.wolf/buglog.json).

Allowed forms (none of these match):
  - Balanced tags: `<div>...</div>`, `<br/>` (closing '>' on same line)
  - Autolinks: `<https://...>`, `<user@host>` (closing '>' on same line)
  - HTML entities: `&lt;dev/tty` (no literal '<')
  - Anything inside ``` or ~~~ fenced code blocks
  - Lines bearing the `<!-- md-tags-ok -->` self-attestation marker

Forbidden form (matches):
  - `<` followed by alphanumeric or `/`, with no matching `>` on the same
    line (or with the next `<` appearing before the `>`)

Fix: reword to avoid the literal '<'. Common patterns:
  - Split code spans: `read </dev/tty` -> `read` redirected from `/dev/tty`
  - Describe in prose: `<command>` -> "the command argument"
  - Use HTML entities outside backticks: text &lt;then `code`

Scope: only files under `docs/` are checked. CHANGELOG.md, design/, and
the rest of the repo are not published via mkdocs (`docs_dir: "docs/"`),
so the rendering bug does not manifest there - and CHANGELOG legitimately
discusses the very pattern we're forbidding.

# :example
python3 -m tests.hooks.check_md_html_tags
# :run on specific files (as pre-commit passes them)
python3 -m tests.hooks.check_md_html_tags docs/standards.md docs/proxy.md
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# A '<' followed by alphanumeric or '/': looks like an HTML tag opener
# (open or close form). Conservatively excludes things like '<3', '<-', '<='.
TAG_LIKE = re.compile(r"<([a-zA-Z][a-zA-Z0-9-]*|/[a-zA-Z][a-zA-Z0-9-/]*)")

# Self-attestation: a line containing this marker is exempted from the check.
# Use sparingly - usually a reword is the right answer.
SUPPRESS_MARKER = "<!-- md-tags-ok -->"

# Only mkdocs-published markdown is in scope.
SCOPED_DIR = "docs/"


def _in_scope(path: Path) -> bool:
    try:
        rel = path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return False
    return rel.startswith(SCOPED_DIR) and path.suffix == ".md"


def _scan(path: Path) -> list[tuple[int, int, str]]:
    """Return [(lineno, col, snippet)] for unbalanced tag-like patterns."""
    offenders: list[tuple[int, int, str]] = []
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return offenders

    in_fence = False
    for i, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            continue
        if in_fence or SUPPRESS_MARKER in line:
            continue

        for m in TAG_LIKE.finditer(line):
            tag_end = m.end()
            rest = line[tag_end:]
            close_pos = rest.find(">")
            next_open = rest.find("<")
            # Unbalanced: no closer at all, or next opener comes before closer.
            if close_pos == -1 or (next_open != -1 and next_open < close_pos):
                start = m.start()
                snippet_start = max(0, start - 10)
                snippet_end = min(len(line), tag_end + 20)
                snippet = line[snippet_start:snippet_end].strip()
                offenders.append((i, start + 1, snippet))
    return offenders


def main(argv: list[str] | None = None) -> int:
    """Scan docs/*.md for unbalanced tag-like patterns that break mkdocs."""
    args = argv or []
    if args:
        files = [Path(p) for p in args if _in_scope(Path(p)) and Path(p).is_file()]
    else:
        base = REPO_ROOT / SCOPED_DIR.rstrip("/")
        files = [p for p in base.rglob("*.md") if _in_scope(p)]

    failures: list[tuple[Path, int, int, str]] = []
    for f in files:
        for lineno, col, snippet in _scan(f):
            failures.append((f, lineno, col, snippet))

    if not failures:
        return 0

    print(
        "Forbidden: '<' followed by alphanumeric/slash with no matching '>' "
        "on the same line.",
        file=sys.stderr,
    )
    print(
        "Python-Markdown's HTML preprocessor consumes these as malformed tag\n"
        "openers - even inside backticks - silently dropping subsequent content\n"
        "from the rendered docs page.\n",
        file=sys.stderr,
    )
    for path, lineno, col, snippet in failures:
        rel = path.resolve().relative_to(REPO_ROOT).as_posix()
        print(f"  {rel}:{lineno}:{col}: {snippet!r}", file=sys.stderr)

    print(
        "\nFix: reword to avoid the literal '<'. Common patterns:\n"
        "  - Split code spans: `read </dev/tty` -> `read` redirected from `/dev/tty`\n"
        "  - Describe in prose: `<command>` -> 'the command argument'\n"
        "  - Use HTML entities outside backticks: text &lt;then `code`\n"
        "Last resort: append `<!-- md-tags-ok -->` to the line as a "
        "self-attestation that you've verified mkdocs renders it correctly.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
