r"""
Keep the agent-facing design docs honest about the tree they describe.

`ARCHITECTURE.md` is the mandated reference for anyone - human or agent -
making a cross-cutting change, and `.claude/CLAUDE.md` requires reading it
before asserting how a subsystem behaves. A stale claim there is worse than a
missing one: it is read as authoritative and acted on.

Audits of the doc show the rot is confined to the *mechanically checkable*
facts. Semantic content (dispatch tables, the `# bins:` tiers, the doctor
check list, the wsl function split) survives editing because changing it
requires understanding it. What rots is what nobody re-derives: a file path
that outlived its file, and a count that was true once.

Three assertions, all opt-in-free or annotation-local:

A. **Dead path references.** Every backtick-quoted path in a doc must exist.
   Only paths rooted at a real repo top-level directory are judged, which is
   what keeps the check precise: the runtime-layout tables in ARCHITECTURE.md
   describe *destination* paths under `~/.config/...` (`omp/theme.omp.json`,
   `Scripts/_aliases_nix.ps1`) and are correctly ignored without an allowlist
   anyone has to maintain. Globs are skipped.

B. **Line budgets** - `<!-- arch:max-lines <path> <max> -->`. For counts that
   state design intent ("slim ~190-line orchestrator"). Widening one past the
   budget then has to be a deliberate edit to the number.

C. **Exact counts** - `<!-- arch:count <path> '<regex>' <n> -->`. Fails when
   the number of lines matching `<regex>` is not `<n>`. `<path>` may be a
   glob, in which case matches are summed across files.

Markers live inline next to the claim they guard so the two cannot drift
apart. HTML comments are safe in these files: `check-md-html-tags` scopes to
`^docs/.*\.md$`, and `align-tables` only rewrites tables.

A malformed marker is an error, never a silent skip - a typo that disabled a
check would defeat the point of having one.

# :example
python3 -m tests.hooks.check_arch_drift
"""

import os
import re
import shlex
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Docs an agent is instructed to trust: the architecture reference, the rules
# that gate edits, and the review charters whose file lists decide what a review
# shard actually looks at. A charter naming a file that no longer exists silently
# under-reviews, which is the failure this check exists to make loud.
DOC_GLOBS = (
    "ARCHITECTURE.md",
    "CONTRIBUTING.md",
    ".claude/CLAUDE.md",
    ".claude/rules/*.md",
    "design/**/*.md",
    # Named, not `docs/**/*.md`: standards.md states hook and test counts that go
    # stale, and it rotted to four wrong figures precisely because nothing checked
    # it. The rest of docs/ is the user manual, where a path may be illustrative.
    "docs/standards.md",
)

# A backtick-quoted token is only judged as a repo path when it starts with one
# of these. Anything else is prose, a bare filename, or a runtime destination.
REPO_DIRS = (
    ".assets/",
    ".claude/",
    ".github/",
    "design/",
    "docs/",
    "modules/",
    "nix/",
    "scripts/",
    "tests/",
    "wsl/",
)

# `path/to/thing` inside backticks. Requires at least one `/`, so `nx.sh` and
# `§3c` never reach the existence check. Deliberately does NOT require a file
# extension: REPO_DIRS below is what supplies the precision, and demanding a
# suffix would skip extensionless targets (`.assets/config/bin/wslview`) and any
# suffix with a hyphen in it (`.assets/docker/Dockerfile.test-nix`) - a narrower
# rule than "every repo path in the doc must exist" claims to be.
#
# A trailing `::symbol` or `:line` locator is consumed and dropped, so
# `tests/hooks/_file_scopes.py::INTERACTIVE_SHELL` (ARCHITECTURE.md cites it
# twice) is checked as the file it names rather than skipped for not ending at
# the closing backtick.
PATH_RE = re.compile(r"`([.\w-]+(?:/[.\w*-]+)+)(?:::[\w.]+|:\d+)?`")

MARKER_RE = re.compile(r"<!--\s*arch:(max-lines|count)\s+(.*?)\s*-->")

# A design proposal describes files that do not exist yet - that is its job, not
# drift. Such a doc declares itself with `<!-- arch-drift: proposal -->`, which
# exempts it from the path check only. Counts and budgets still apply, and the
# opt-out lives in the document rather than in an allowlist here so it is visible
# to whoever is reading the proposal.
PROPOSAL_RE = re.compile(r"<!--\s*arch-drift:\s*proposal\s*-->")

# Inline code span. A marker written inside backticks is documenting the syntax
# (§8 of ARCHITECTURE.md does exactly that) and must not be evaluated as a claim.
CODE_SPAN_RE = re.compile(r"`[^`]*`")


def _root() -> Path:
    return Path(os.environ.get("CHECK_ARCH_DRIFT_ROOT", REPO_ROOT))


def _rel(path: Path) -> str:
    try:
        return str(path.relative_to(_root()))
    except ValueError:
        return str(path)


def _docs() -> list[Path]:
    root = _root()
    found: list[Path] = []
    for pattern in DOC_GLOBS:
        found.extend(sorted(root.glob(pattern)))
    return [p for p in found if p.is_file()]


def _resolve(root: Path, spec: str) -> list[Path]:
    """Expand a marker's path spec to real files. A glob may match nothing."""
    if any(ch in spec for ch in "*?["):
        return sorted(p for p in root.glob(spec) if p.is_file())
    candidate = root / spec
    return [candidate] if candidate.is_file() else []


def _check_paths(doc: Path, root: Path) -> list[tuple[int, str]]:
    """Report backtick-quoted repo paths in *doc* that do not exist."""
    text = doc.read_text(encoding="utf-8")
    if PROPOSAL_RE.search(text):
        return []
    failures = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in PATH_RE.finditer(line):
            spec = match.group(1)
            if "*" in spec or not spec.startswith(REPO_DIRS):
                continue
            if not (root / spec).exists():
                failures.append((lineno, f"references `{spec}`, which does not exist"))
    return failures


def _check_markers(doc: Path, root: Path) -> list[tuple[int, str]]:
    """Evaluate every arch:max-lines / arch:count marker in *doc*."""
    failures = []
    for lineno, line in enumerate(doc.read_text(encoding="utf-8").splitlines(), 1):
        prose = CODE_SPAN_RE.sub(lambda m: " " * len(m.group(0)), line)
        for match in MARKER_RE.finditer(prose):
            kind, rest = match.group(1), match.group(2)
            try:
                args = shlex.split(rest)
            except ValueError as exc:
                failures.append((lineno, f"malformed arch:{kind} marker: {exc}"))
                continue
            handler = _check_max_lines if kind == "max-lines" else _check_count
            failures.extend((lineno, msg) for msg in handler(root, args))
    return failures


def _check_max_lines(root: Path, args: list[str]) -> list[str]:
    if len(args) != 2:
        return ["arch:max-lines takes <path> <max>, got: " + " ".join(args)]
    spec, raw_max = args
    if not raw_max.isdigit():
        return [f"arch:max-lines budget must be a number, got `{raw_max}`"]
    targets = _resolve(root, spec)
    if not targets:
        return [f"arch:max-lines target `{spec}` does not exist"]
    budget = int(raw_max)
    actual = sum(len(t.read_text(encoding="utf-8").splitlines()) for t in targets)
    if actual > budget:
        return [
            f"`{spec}` is {actual} lines, over its stated budget of {budget}. "
            "Trim it, or raise the budget in the marker and say why in the prose."
        ]
    return []


def _check_count(root: Path, args: list[str]) -> list[str]:
    if len(args) != 3:
        return ["arch:count takes <path> '<regex>' <n>, got: " + " ".join(args)]
    spec, pattern, raw_expected = args
    if not raw_expected.isdigit():
        return [f"arch:count expects a number, got `{raw_expected}`"]
    try:
        regex = re.compile(pattern)
    except re.error as exc:
        return [f"arch:count regex `{pattern}` is invalid: {exc}"]
    targets = _resolve(root, spec)
    if not targets:
        return [f"arch:count target `{spec}` does not exist"]
    expected = int(raw_expected)
    actual = sum(
        sum(
            1
            for line in t.read_text(encoding="utf-8").splitlines()
            if regex.search(line)
        )
        for t in targets
    )
    if actual != expected:
        return [
            f"`{spec}` has {actual} lines matching /{pattern}/, "
            f"but the doc claims {expected}. Update the prose and the marker."
        ]
    return []


def main(argv: list[str] | None = None) -> int:
    """Check every agent-facing doc for dead paths and stale counts."""
    del argv  # pre-commit passes no filenames; budgets must fire on code edits too
    root = _root()
    failures: list[tuple[Path, int, str]] = []
    for doc in _docs():
        for lineno, msg in _check_paths(doc, root) + _check_markers(doc, root):
            failures.append((doc, lineno, msg))

    if not failures:
        return 0

    print(
        f"Design docs disagree with the tree ({len(failures)} problem(s)):\n",
        file=sys.stderr,
    )
    for doc, lineno, msg in sorted(failures, key=lambda f: (str(f[0]), f[1])):
        print(f"  {_rel(doc)}:{lineno}: {msg}", file=sys.stderr)

    print(
        "\nThese docs are what an agent is told to trust before changing code,\n"
        "so a stale claim gets acted on. Fix the doc, or - when the number is\n"
        "decoration rather than a design budget - delete the number instead.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
