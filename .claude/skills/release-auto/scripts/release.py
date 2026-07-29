#!/usr/bin/env -S uv run python3
r"""
Stateful release orchestrator for the /release-auto skill.

Inverts control versus /prepare-release: instead of the agent interpreting a
~10K-token runbook turn-by-turn, this script drives the deterministic spine and
calls the agent only at a few batched *gates*. Between gates it runs headless
(lint, extract, upgrade, version bump, reconcile, recut, lint-diff, push/PR).

Control flow (decision 1 - sentinel-exit + resume):
  - ``start`` runs mechanical work to the first gate, writes ``.release/state.json``,
    prints ``DECISION_NEEDED\\n<json>`` and exits ``EXIT_GATE`` (10).
  - The agent makes the decision (composes CHANGELOG prose, authors the commit
    plan, ...), then re-invokes ``resume --decision <src>``.
  - The loop ends when a phase completes with no gate: exit 0.

The load-bearing verbs are ``recut`` and ``reconcile``:
  - ``recut`` = pure function of ``(commit-plan + working tree)``. Re-cutting after
    a review fix is the same plan against different file contents = zero agent
    turns (decision 3). It *pre-validates* the whole plan before touching git and
    writes a ``refs/release-backup/<version>`` safety ref first (decision 9).
  - ``reconcile`` = set-diff of the working tree against the plan globs. It gates
    only on a *covered-set delta* (new/orphan/newly-touched path); pure content
    re-edits of already-approved files pass silently (decision 5).

State lives under ``.release/`` (git-ignored, version-keyed) and is wiped on
success. ``resume`` refuses if the state version mismatches or HEAD moved
underneath the orchestrator.

Usage:
    release.py start --version 1.16.0 [--skip-review]
    release.py resume --decision .release/decision.json
    release.py resume --decision -            # read decision JSON from stdin
    release.py recut                          # coda re-cut (reconcile+recut+lint)
    release.py push                           # force-with-lease + create/update PR
    release.py status
    release.py abort                          # soft-rewind commits, wipe .release/
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath

# -- constants ----------------------------------------------------------------

STATE_DIR = Path(".release")
STATE_FILE = STATE_DIR / "state.json"
PLAN_FILE = STATE_DIR / "commit-plan.json"
POLICY_FILE = STATE_DIR / "review-policy.json"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_GATE = 10

# Files that always ride with the CHANGELOG commit (content-coupled to the bump).
CHANGELOG_RIDERS = ("CHANGELOG.md", "project-words.txt", "pyproject.toml", "uv.lock")

SECTION_HEADER_RE = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\S+))?\s*$")
# Shared leaf scripts (extract.py, cspell_words.py, test_stats.py,
# extract_signals.py) - absorbed from the retired /prepare-release skill.
SHARED = Path(".claude/skills/release-auto/scripts")
# Committed default review policy, seeded into .release/ for the coda to edit.
DEFAULT_POLICY = Path(".claude/skills/release-auto/review-policy.json")


# -- errors -------------------------------------------------------------------


class ReleaseError(Exception):
    """A recoverable orchestrator failure surfaced to the agent/user."""


# -- git helpers --------------------------------------------------------------


def git(args: list[str], *, check: bool = True) -> str:
    """
    Run a git command and return stripped stdout.

    Raises ``ReleaseError`` on non-zero exit when ``check`` is set.
    """
    result = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        raise ReleaseError(f"git {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def head_sha() -> str:
    """Return the current HEAD commit SHA."""
    return git(["rev-parse", "HEAD"])


def current_branch() -> str:
    """Return the current branch name (or empty on detached HEAD)."""
    return git(["rev-parse", "--abbrev-ref", "HEAD"], check=False)


def tag_exists(version: str) -> bool:
    """
    Return True if ``v<version>`` is an existing git tag (i.e. shipped).

    Used to recognize orphaned ``.release/`` state left behind by an
    already-released cycle - the one unambiguous "this state is garbage" signal.
    """
    return bool(
        git(["rev-parse", "--verify", "--quiet", f"refs/tags/v{version}"], check=False)
    )


def last_tag() -> str:
    """Return the most recent tag reachable from HEAD, or empty if none."""
    return git(["describe", "--tags", "--abbrev=0"], check=False)


def tree_is_clean() -> bool:
    """True if the working tree has no tracked-or-untracked changes vs HEAD."""
    return git(["status", "--porcelain", "-uall"], check=False) == ""


def head_is_published() -> bool:
    """
    True only if HEAD exactly matches the branch's upstream tracking ref.

    False when there is no upstream (never pushed) OR the two SHAs differ for any
    reason - local ahead, behind, or diverged. Any mismatch means the local and
    published states are not identical, so the nothing-to-release guard should not
    treat this as a finished, published release.
    """
    upstream = git(
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], check=False
    )
    if not upstream:
        return False
    up_sha = git(["rev-parse", "@{u}"], check=False)
    return bool(up_sha) and up_sha == head_sha()


def tracked_and_untracked(base: str) -> list[str]:
    """
    Return every path that differs between ``base`` and the working tree.

    Union of committed + staged + unstaged tracked changes (``git diff --name-only
    base``) and untracked files (``git status --porcelain`` ``??`` entries). This
    is the *universe* both ``reconcile`` and ``recut`` pre-validation operate on.
    """
    paths: set[str] = set()
    # `git diff <base>` compares base->working tree and misses paths that are
    # staged in the index but no longer differ in the working tree; `--cached`
    # compares base->index. Union of the two covers committed + staged + unstaged
    # tracked changes regardless of where a given change currently sits.
    # `--no-renames` so a rename surfaces as BOTH its delete (source) and add
    # (destination) paths; otherwise the collapsed source path escapes every
    # group's globs and its removal is never staged (a moved file left duplicated).
    tracked = git(["diff", "--no-renames", "--name-only", base], check=False)
    paths.update(p for p in tracked.splitlines() if p)
    staged = git(["diff", "--no-renames", "--name-only", "--cached", base], check=False)
    paths.update(p for p in staged.splitlines() if p)
    # -uall expands untracked directories into individual file paths; without it
    # git reports a wholly-untracked dir as a single `?? dir/` entry that no glob
    # meant for files would match, producing a spurious orphan.
    porcelain = git(["status", "--porcelain", "-uall"], check=False)
    for line in porcelain.splitlines():
        if line.startswith("??"):
            paths.add(line[3:].strip())
    return sorted(paths)


def working_tree_dirty_paths() -> list[str]:
    """
    Return every path with uncommitted work relative to HEAD.

    Modified, staged, or untracked - i.e. exactly the content a ``recut`` would
    fold into the release commits. Empty when the tree is clean (a recut just
    ran). Used by the push guard to refuse pushing stale commits while a fix
    sits uncommitted.
    """
    paths: set[str] = set()
    # base=HEAD, so this is dirt vs the last commit, not vs the release tag.
    tracked = git(["diff", "--no-renames", "--name-only", "HEAD"], check=False)
    paths.update(p for p in tracked.splitlines() if p)
    staged = git(
        ["diff", "--no-renames", "--name-only", "--cached", "HEAD"], check=False
    )
    paths.update(p for p in staged.splitlines() if p)
    porcelain = git(["status", "--porcelain", "-uall"], check=False)
    for line in porcelain.splitlines():
        if line.startswith("??"):
            paths.add(line[3:].strip())
    return sorted(paths)


def uncommitted_covered_paths(plan: dict) -> list[str]:
    """
    Return dirty paths the plan claims - the push guard's refusal set.

    A non-empty result means a fix was edited but never re-cut, so the pushed
    commits are stale relative to the working tree. Orphan dirty paths are left
    out here: ``recut``'s reconcile handles those with a plan-update gate, and
    the push guard only needs to catch the "forgot to recut" case.
    """
    dirty = working_tree_dirty_paths()
    return [p for p in dirty if match_group(p, plan) is not None]


# -- state I/O ----------------------------------------------------------------


def load_state() -> dict:
    """Read ``.release/state.json`` or raise if the pipeline has not started."""
    if not STATE_FILE.is_file():
        raise ReleaseError(
            "no .release/state.json - run `release.py start --version X.Y.Z` first"
        )
    return json.loads(STATE_FILE.read_text())


def save_state(state: dict) -> None:
    """Persist ``state`` to ``.release/state.json`` (creating the dir)."""
    STATE_DIR.mkdir(exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


def guard_resume(state: dict) -> None:
    """
    Refuse to resume if HEAD moved underneath us since the last step.

    Catches manual commits/resets made between orchestrator invocations -
    resuming against a moved HEAD would recut the wrong universe. (Version
    identity is enforced separately: ``cmd_start`` refuses to begin a second
    release while ``.release/state.json`` exists.)
    """
    expected = state.get("head_sha")
    actual = head_sha()
    if expected and expected != actual:
        raise ReleaseError(
            "HEAD moved since the last release step "
            f"(expected {expected[:12]}, found {actual[:12]}). "
            "Inspect `git log`; re-run `release.py start` if this is intentional."
        )


# -- glob matching ------------------------------------------------------------


def match_group(path: str, plan: dict) -> int | None:
    """
    Return the index of the first plan group whose globs match ``path``.

    First-match-wins, so overlapping globs resolve deterministically by group
    order (decision 3: a file touched by two logical changes lands in one commit).
    Returns ``None`` when no group claims the path (an orphan).

    Uses ``PurePosixPath.full_match`` (added in Python 3.13; the project pins
    ``requires-python = "~=3.13.0"``). full_match anchors the whole path, so a
    bare ``CHANGELOG.md`` glob matches only the root file, never a nested
    ``sub/CHANGELOG.md``.
    """
    pp = PurePosixPath(path)
    for idx, group in enumerate(plan["groups"]):
        for glob in group.get("globs", []):
            if pp.full_match(glob):
                return idx
    return None


def assign_paths(
    paths: list[str], plan: dict
) -> tuple[dict[int, list[str]], list[str]]:
    """
    Partition ``paths`` into ``{group_index: [paths]}`` plus a list of orphans.

    Pure function - no git mutation. Used by both pre-validation and reconcile.
    """
    assigned: dict[int, list[str]] = {}
    orphans: list[str] = []
    for path in paths:
        idx = match_group(path, plan)
        if idx is None:
            orphans.append(path)
        else:
            assigned.setdefault(idx, []).append(path)
    # Sort orphans so gate payloads and error messages are deterministic
    # regardless of the caller's input ordering.
    return assigned, sorted(orphans)


# -- plan validation ----------------------------------------------------------


def load_plan() -> dict:
    """Read ``.release/commit-plan.json`` or raise if the agent never wrote it."""
    if not PLAN_FILE.is_file():
        raise ReleaseError(
            "no .release/commit-plan.json - the phase-1 gate must author it first"
        )
    plan = json.loads(PLAN_FILE.read_text())
    groups = plan.get("groups")
    if not groups:
        raise ReleaseError("commit-plan.json has no groups")
    # Validate each group's required keys up front so a malformed plan fails with
    # a clear ReleaseError here, not a KeyError deep inside prevalidate/recut.
    for i, group in enumerate(groups):
        if not isinstance(group, dict):
            raise ReleaseError(f"commit-plan group [{i}] is not an object")
        missing = [k for k in ("globs", "message") if not group.get(k)]
        if missing:
            raise ReleaseError(
                f"commit-plan group [{i}] is missing required key(s): "
                + ", ".join(missing)
            )
        if not isinstance(group["globs"], list):
            raise ReleaseError(f"commit-plan group [{i}] 'globs' must be a list")
    return plan


def prevalidate(plan: dict, base: str) -> dict[int, list[str]]:
    """
    Prove the plan is fully executable *before* touching git (decision 9b).

    Checks: (1) every changed path is claimed by exactly one group (full
    coverage, no orphans); (2) every group ends up non-empty. A plan that would
    fail mid-recut fails here instead - the soft-reset never runs.

    Returns the ``{group_index: [paths]}`` assignment on success.
    """
    universe = tracked_and_untracked(base)
    if not universe:
        raise ReleaseError(f"no changes between {base} and the working tree")
    assigned, orphans = assign_paths(universe, plan)
    if orphans:
        raise ReleaseError(
            "commit-plan does not cover these paths (orphans):\n  "
            + "\n  ".join(orphans)
        )
    empty = [
        f"[{i}] {g['message']}"
        for i, g in enumerate(plan["groups"])
        if not assigned.get(i)
    ]
    if empty:
        raise ReleaseError(
            "these plan groups would produce empty commits:\n  " + "\n  ".join(empty)
        )
    return assigned


# -- reconcile ----------------------------------------------------------------


def reconcile(plan: dict, state: dict) -> dict:
    """
    Set-diff the working tree against the plan; decide whether ``recut`` may run.

    A coda ``recut`` must gate iff the plan cannot currently execute - i.e. the
    changed-path universe (``tracked_and_untracked(reset_target)``) has an
    *orphan* (a changed path no group claims) or a group would be *empty* (none of
    the changed paths match its globs - a group whose globs only match unchanged
    files still commits nothing). Those are exactly the two conditions
    ``prevalidate`` would raise on, surfaced here as a plan-update gate so the
    agent fixes the globs before any git mutation.

    The covered-set delta vs ``confirmed_covered_set`` (``new_covered`` /
    ``dropped``) is reported for context but is **not**, on its own, a gate.
    Earlier this gated directly, which dead-ended two real flows: after the agent
    updated the plan to claim a new file it stayed ``new_covered`` and re-gated
    forever; and reverting a covered file mid-coda left a ``dropped`` delta that
    ``recut`` could never clear because the coda path never re-seeds
    ``confirmed_covered_set``. Gating on the actual executability conditions
    instead means a plan that matches the tree always proceeds - whether paths
    were added, dropped, or only re-edited (the zero-gate review-fix path).
    """
    base = state["reset_target"]
    universe = tracked_and_untracked(base)
    assigned, orphans = assign_paths(universe, plan)
    covered = sorted(p for ps in assigned.values() for p in ps)
    empty_groups = [
        f"[{i}] {g['message']}"
        for i, g in enumerate(plan["groups"])
        if not assigned.get(i)
    ]
    confirmed = set(state.get("confirmed_covered_set", []))
    new_covered = sorted(set(covered) - confirmed)
    dropped = sorted(confirmed - set(covered))
    # Gate only on non-executability; the set-delta is advisory context.
    return {
        "covered": covered,
        "orphans": orphans,
        "empty_groups": empty_groups,
        "new_covered": new_covered,
        "dropped": dropped,
        "blocked": bool(orphans or empty_groups),
    }


# -- recut --------------------------------------------------------------------


def commit_message(group: dict) -> str:
    """Build the full commit message (subject + trailer block) for a group."""
    subject = group["message"]
    trailers = group.get("trailers") or []
    if not trailers:
        return subject
    return subject + "\n\n" + "\n".join(trailers)


def backup_ref(version: str) -> str:
    """Return the fully-qualified safety backup ref name for ``version``."""
    return f"refs/release-backup/{version}"


def write_backup(version: str) -> None:
    """Point ``refs/release-backup/<version>`` at HEAD before any mutation."""
    git(["update-ref", backup_ref(version), "HEAD"])


def restore_soft(head: str) -> None:
    """
    Non-destructively rewind to ``head`` after a failed recut.

    Uses ``reset --soft`` (NOT ``--hard``): on a first cut the entire release is
    still uncommitted, so a hard reset to the backup ref - which points at a HEAD
    that does NOT contain that work - would delete it. recut only ever moves
    content between committed/staged/unstaged and never checks out or deletes file
    content, so soft-rewinding to the pre-recut HEAD and unstaging returns the
    working tree to exactly its pre-recut dirty state with nothing lost.
    """
    git(["reset", "--soft", head])
    git(["restore", "--staged", "."])


def delete_backup(version: str) -> None:
    """Remove the safety backup ref (called once the pipeline succeeds)."""
    git(["update-ref", "-d", backup_ref(version)], check=False)


def recut(plan: dict, state: dict, validate=None) -> list[str]:
    """
    Soft-reset to the target and re-commit by group (decision 3 + 9).

    Pre-validates the entire plan first, records the pre-recut HEAD, writes a
    safety backup ref, then mutates git. ``validate`` (if given) is a zero-arg
    callable run *inside* the atomic block after the commits are made - e.g.
    ``make lint-diff`` - so a validation failure rewinds too and git is never left
    mutated on any failure (decision 9a). On any exception after mutation begins,
    the working tree is soft-rewound to the pre-recut HEAD (uncommitted work
    preserved) and the error re-raised. Returns the list of commit subjects.
    """
    base = state["reset_target"]
    version = state["version"]
    assigned = prevalidate(plan, base)  # raises before any mutation

    pre_head = head_sha()
    write_backup(version)
    try:
        git(["reset", "--soft", base])
        git(["restore", "--staged", "."])
        subjects: list[str] = []
        for idx, group in enumerate(plan["groups"]):
            paths = assigned.get(idx, [])
            # --all stages modifications, additions AND deletions for these
            # pathspecs, so a group whose plan covers a now-deleted file still
            # commits the removal instead of silently leaving it unstaged.
            git(["add", "--all", "--", *paths])
            _commit(commit_message(group))
            subjects.append(group["message"])
        if validate is not None:
            validate()
    except Exception:
        restore_soft(pre_head)
        raise
    return subjects


def _commit(message: str) -> None:
    """Create one ``--no-verify`` commit reading the message from stdin."""
    result = subprocess.run(
        ["git", "commit", "--no-verify", "-F", "-"],
        input=message,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ReleaseError(
            f"git commit failed:\n{result.stderr.strip() or result.stdout.strip()}"
        )


# -- make / shared-script wrappers -------------------------------------------


def run_make(target: str) -> None:
    """Run a ``make`` target, raising ``ReleaseError`` with output on failure."""
    result = subprocess.run(
        ["make", target], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        tail = (result.stdout + result.stderr).strip()[-4000:]
        raise ReleaseError(f"`make {target}` failed:\n{tail}")


def run_extract(version: str) -> str:
    """Run the shared extract.py and return its chunked output."""
    script = SHARED / "extract.py"
    result = subprocess.run(
        [str(script), "--version", version],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ReleaseError(f"extract.py failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


# -- CHANGELOG parsing --------------------------------------------------------


def changelog_section(version: str, path: str = "CHANGELOG.md") -> str:
    """
    Return the body of the ``## [<version>]`` block for the PR body.

    Empty string if the section does not exist yet.
    """
    text = Path(path).read_text()
    lines = text.splitlines()
    out: list[str] = []
    capturing = False
    for line in lines:
        m = SECTION_HEADER_RE.match(line)
        if m:
            if capturing:
                break
            capturing = m.group(1) == version
            continue
        if capturing:
            out.append(line)
    return "\n".join(out).strip()


def version_exists(version: str, path: str = "CHANGELOG.md") -> bool:
    """Return True if a ``## [<version>]`` block already exists (re-run case)."""
    if not Path(path).is_file():
        return False
    return bool(changelog_section(version, path)) or any(
        (m := SECTION_HEADER_RE.match(ln)) and m.group(1) == version
        for ln in Path(path).read_text().splitlines()
    )


# -- guardrails ---------------------------------------------------------------


def refuse_shared_branch() -> None:
    """Stop before a force-push if the branch is shared or detached."""
    branch = current_branch()
    # A detached HEAD has no branch to push; current_branch() returns "HEAD".
    # Catch it here so the failure is clear rather than a confusing push error.
    if not branch or branch == "HEAD":
        raise ReleaseError(
            "detached HEAD - check out a release branch before cutting a release."
        )
    is_shared = branch in ("main", "master", "develop")
    is_release_branch = branch.startswith("release/")
    if is_shared:
        raise ReleaseError(
            f"refusing to operate on shared branch '{branch}' - "
            "cut the release from a feature/release branch."
        )
    if is_release_branch:
        # The expected release-branch pattern - allow it, but note the force-push.
        print(
            f"note: operating on '{branch}' (release branch) - force-push is expected.",
            file=sys.stderr,
        )


# -- gate emission ------------------------------------------------------------


def emit_gate(kind: str, context: dict, options: list[str]) -> int:
    """Print the sentinel + decision payload and return the gate exit code."""
    print("DECISION_NEEDED")
    print(json.dumps({"kind": kind, "context": context, "options": options}, indent=2))
    return EXIT_GATE


# -- decision input -----------------------------------------------------------


def read_decision(src: str) -> dict:
    """Load a decision payload from a file path, or from stdin when ``src`` is ``-``."""
    if src == "-":
        raw = sys.stdin.read()
    else:
        try:
            raw = Path(src).read_text()
        except OSError as exc:
            raise ReleaseError(f"cannot read decision file '{src}': {exc}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ReleaseError(f"invalid decision JSON: {exc}") from exc


# -- phases -------------------------------------------------------------------


def phase_start(version: str, skip_review: bool, reopen: bool = False) -> int:
    """
    Run the headless pre-gate work and stop at the phase-1 gate.

    Mechanical, in order: refuse shared branch, ``make lint``, bump
    ``pyproject.toml``, then ``make upgrade`` (so ``uv.lock`` picks up the new
    version), gather extract/cspell/diff signals. Then gate so the agent can
    compose CHANGELOG prose, classify cspell findings, and author the plan.
    """
    refuse_shared_branch()
    tag = last_tag()
    if not tag:
        raise ReleaseError("no git tag found - cannot scope the release")

    # Nothing-to-release guard: a version block already present AND a clean tree
    # AND HEAD already pushed means this exact release was cut and published in a
    # prior run. Starting again would re-cut identical commits and re-trigger the
    # review coda for zero change. Refuse before any mutation (no lint/upgrade).
    if (
        not reopen
        and version_exists(version)
        and tree_is_clean()
        and head_is_published()
    ):
        raise ReleaseError(
            f"release {version} is already cut, committed, and pushed - nothing to "
            "do. If you have new changes, make them first; to re-cut/consolidate the "
            "already-pushed commits (e.g. fold coda follow-ups), re-run "
            "`start --reopen`."
        )

    run_make("lint")
    if not reopen:
        # --reopen freezes the release payload: skip the version bump and dependency
        # upgrade so a consolidation re-cut never re-resolves deps or alters content.
        _bump_pyproject(version)
        run_make("upgrade")

    is_rerun = version_exists(version)
    state = {
        "version": version,
        "skip_review": skip_review,
        "last_tag": tag,
        "reset_target": tag,  # first cut; re-run target refined at plan time
        "is_rerun": is_rerun,
        "phase": "await_phase1",
        "head_sha": head_sha(),
        "confirmed_covered_set": [],
        "completed_phases": ["A"],
        "decisions": [],
    }
    save_state(state)

    extract = run_extract(version)
    cspell = _cspell_scan()
    diff = git(["diff", "--name-status", tag], check=False)
    context = {
        "version": version,
        "is_rerun": is_rerun,
        "extract": extract,
        "cspell_findings": cspell,
        "diff_name_status": diff,
        "instructions": (
            "Compose the CHANGELOG entry (Edit CHANGELOG.md), fix any cspell typos, "
            "then author .release/commit-plan.json (file-granularity glob->commit). "
            "Resume with a decision: "
            '{"cspell_add": [...], "version_final": "X.Y.Z", "plan_written": true}'
        ),
    }
    return emit_gate("phase1", context, ["author-plan-and-resume", "abort"])


def _bump_pyproject(version: str) -> None:
    """Set ``pyproject.toml`` ``version = "X.Y.Z"`` (mechanical, no judgment)."""
    path = Path("pyproject.toml")
    text = path.read_text()
    new, n = re.subn(
        r'^version = "[^"]*"',
        f'version = "{version}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if n == 0:
        raise ReleaseError("could not find a version line in pyproject.toml")
    path.write_text(new)


def _cspell_scan() -> list:
    """
    Run the shared cspell scanner and return its findings list.

    Raises ``ReleaseError`` on a genuine helper failure (non-zero exit, or stdout
    that is not parseable JSON) rather than swallowing it as "no findings" - a
    silent swallow would skip the cspell gate and defer the failure to a later
    ``lint-diff``, far from the cause. An empty findings list is the only clean
    "nothing to do" signal.
    """
    script = SHARED / "cspell_words.py"
    result = subprocess.run(
        [str(script), "scan"], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise ReleaseError(
            "cspell_words.py scan failed:\n"
            + (result.stderr.strip() or result.stdout.strip())
        )
    try:
        return json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        raise ReleaseError(
            f"cspell_words.py scan returned unparseable output: {exc}"
        ) from exc


def _cspell_add(words: list[str]) -> None:
    """
    Add approved words to project-words.txt via the shared helper.

    Raises ``ReleaseError`` on failure - a silently-swallowed add would let the
    release proceed and blow up later in ``lint-diff`` / recut with a stale
    dictionary, far from the real cause.
    """
    if not words:
        return
    script = SHARED / "cspell_words.py"
    result = subprocess.run(
        [str(script), "add", *words], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise ReleaseError(
            "cspell_words.py add failed:\n"
            + (result.stderr.strip() or result.stdout.strip())
        )


def resume_phase1(state: dict, decision: dict) -> int:
    """
    Consume the phase-1 decision, run reconcile + recut, stop at the push gate.

    Adds approved cspell words, refines the re-run reset target, records the
    confirmed covered set, then recuts (headless) and validates via lint-diff.
    """
    _cspell_add(decision.get("cspell_add", []))

    final = decision.get("version_final", state["version"])
    if final != state["version"]:
        state["version"] = final
        # The agent changed the version at the gate (e.g. patch->minor after the
        # SemVer check). Re-bump pyproject.toml and re-sync uv.lock so the project
        # metadata and lockfile match the final version - otherwise the docs
        # commit ships the old version while the PR/title use the new one.
        _bump_pyproject(final)
        run_make("upgrade")

    # Re-scan cspell AFTER the agent composed the CHANGELOG - the start-time scan
    # ran before the entry existed, so words introduced in the release prose (e.g.
    # "pytest") escape it and would only fail at lint-diff, post-mutation. Surface
    # any residual unknown words as a gate now, pre-mutation, so the agent can
    # classify (add-or-fix) rather than the recut blowing up.
    residual = _cspell_scan()
    if residual:
        save_state(state)
        return emit_gate(
            "cspell",
            {
                "findings": residual,
                "instructions": (
                    "New unknown words remain after composing the release docs. "
                    "Fix typos in-place (Edit), then resume with the real names to "
                    'add: {"cspell_add": [...], "version_final": "'
                    + final
                    + '", "plan_written": true}. The plan and CHANGELOG you already '
                    "wrote are preserved."
                ),
            },
            ["classify-and-resume", "abort"],
        )

    plan = load_plan()
    state["reset_target"] = _resolve_reset_target(state, plan)

    # Seed the confirmed covered set from the plan the agent just authored, then
    # reconcile - on a first cut this is a no-op delta (silent), which is correct.
    universe = tracked_and_untracked(state["reset_target"])
    assigned, _ = assign_paths(universe, plan)
    state["confirmed_covered_set"] = sorted(p for ps in assigned.values() for p in ps)

    # lint-diff runs INSIDE recut's atomic block: a lint failure rewinds the
    # commits too, so a failed resume never leaves git mutated with stale state.
    subjects = recut(plan, state, validate=lambda: run_make("lint-diff"))

    state["head_sha"] = head_sha()
    state["phase"] = "await_push"
    state["completed_phases"].append("B")
    state["decisions"].append({"kind": "phase1", "version": final})
    save_state(state)

    context = {
        "version": final,
        "commits": subjects,
        "pr_body_preview": changelog_section(final),
        "instructions": (
            "Review the commit sequence and PR body. Resume with "
            '{"approve": true} to push + open/update the PR, or {"abort": true}.'
        ),
    }
    return emit_gate("push", context, ["approve", "abort"])


def _resolve_reset_target(state: dict, plan: dict) -> str:
    """
    Pick the soft-reset target: last tag for a first cut, else oldest touched^.

    Re-run/merge case (target version block pre-existed): reset only as far back
    as the oldest commit since the tag that this run's plan touches, so untouched
    earlier commits stay intact.
    """
    tag = state["last_tag"]
    if not state.get("is_rerun"):
        return tag
    # Only consider paths the CURRENT plan actually covers - not the full changed
    # universe. Resetting based on unrelated changed paths would drag the target
    # back over commits this run does not touch, forcing recut to rewrite them (or
    # fail prevalidation with those paths as orphans).
    universe = tracked_and_untracked(tag)
    assigned, _ = assign_paths(universe, plan)
    covered = [p for ps in assigned.values() for p in ps]
    oldest: str | None = None
    for path in covered:
        log = git(["log", "--format=%H", f"{tag}..HEAD", "--", path], check=False)
        commits = [c for c in log.splitlines() if c]
        if commits:
            candidate = commits[-1]  # oldest touch of this path
            oldest = candidate if oldest is None else oldest
            # keep the earliest across all files by comparing commit order
            if _is_ancestor(candidate, oldest) and candidate != oldest:
                oldest = candidate
    if oldest is None:
        return tag
    return f"{oldest}^"


def _is_ancestor(a: str, b: str) -> bool:
    """Return True if commit ``a`` is an ancestor of commit ``b``."""
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", a, b],
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def resume_push(state: dict, decision: dict) -> int:
    """Consume the push decision: force-push, open/update PR, end the spine."""
    if decision.get("abort"):
        raise ReleaseError("push aborted by decision - nothing pushed")
    if not decision.get("approve"):
        raise ReleaseError('push gate needs {"approve": true} or {"abort": true}')

    _do_push()
    _upsert_pr(state["version"])

    state["phase"] = "spine_complete"
    state["head_sha"] = head_sha()
    state["completed_phases"].append("C")
    save_state(state)

    if state.get("skip_review"):
        return _finish(state, "spine complete (--skip-review); no review coda.")

    # Seed the per-release policy copy from the committed default so the coda's
    # triage step has .release/review-policy.json to read. Only if absent - a
    # copy already present carries this release's local overrides.
    if not POLICY_FILE.exists() and DEFAULT_POLICY.is_file():
        STATE_DIR.mkdir(exist_ok=True)
        POLICY_FILE.write_text(DEFAULT_POLICY.read_text())

    print("SPINE_COMPLETE")
    print(
        json.dumps(
            {
                "version": state["version"],
                "next": (
                    "Run the review coda: trigger Copilot via "
                    "address-pr-review/pr_review.py, triage against "
                    ".release/review-policy.json, apply fixes, then "
                    "`release.py recut` + `release.py push`. When clean, "
                    "`release.py abort` is not needed - the spine wipes state on "
                    "the final `push`; run `release.py status` to inspect."
                ),
            },
            indent=2,
        )
    )
    return EXIT_OK


def _do_push() -> None:
    """Push with ``--force-with-lease``, setting upstream on first push."""
    branch = current_branch()
    if not branch or branch == "HEAD":
        raise ReleaseError("detached HEAD - cannot push a release without a branch.")
    if head_is_published():
        # The branch is already in sync with origin - e.g. pushed out-of-band
        # because this tool cannot push to a guarded remote. Skip the push so the
        # caller still runs _upsert_pr() + finalize instead of aborting on a
        # rejected push (which would strand the PR-body sync and state wipe).
        print("branch already in sync with origin - skipping push")
        return
    upstream = git(
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], check=False
    )
    if upstream:
        git(["push", "--force-with-lease"])
    else:
        # First push from this branch. Set upstream, but still use
        # --force-with-lease: recut rewrites history, so if the branch already
        # exists on origin (just not tracked locally) a plain push would be
        # rejected non-fast-forward. --force-with-lease is safe here - it refuses
        # only if origin has commits we have not seen.
        git(["push", "-u", "--force-with-lease", "origin", branch])


def _upsert_pr(version: str) -> None:
    """Create or update the release PR body from the CHANGELOG section."""
    body = changelog_section(version)
    if not body:
        raise ReleaseError(
            f"CHANGELOG has no content under ## [{version}] - refusing to open a "
            "release PR with an empty body. Compose the release notes first."
        )
    title = f"chore(release): {version}"
    exists = subprocess.run(
        ["gh", "pr", "view", "--json", "number"],
        capture_output=True,
        text=True,
        check=False,
    )
    if exists.returncode == 0:
        _gh(["pr", "edit", "--title", title, "--body", body])
    else:
        _gh(["pr", "create", "--base", "main", "--title", title, "--body", body])


def _gh(args: list[str]) -> None:
    """Run a ``gh`` command, raising ``ReleaseError`` on failure."""
    result = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise ReleaseError(f"gh {' '.join(args)} failed:\n{result.stderr.strip()}")


def _wipe_state_dir() -> None:
    """
    Remove ``.release/`` entirely - it is wholly driver-owned and git-ignored.

    A full rmtree (not a hand-listed unlink of state/plan/policy) is deliberate:
    the coda also writes ``decision.json`` here, and any future state file would
    otherwise be silently left behind, making the "state wiped" report a lie and
    leaking stale state into the next `start`.

    Guard against a ``.release`` symlink: ``Path.is_dir()`` follows symlinks, so
    an rmtree gated on it alone could delete an arbitrary target a symlink points
    at. Unlink the link itself (never its target); only rmtree a *real*
    directory. ``lstat``-based checks (``is_symlink``) do not follow the link.
    A stray regular *file* named ``.release`` is also unlinked - otherwise it
    lingers as stale state and makes the next ``STATE_DIR.mkdir()`` fail.
    """
    if STATE_DIR.is_symlink() or STATE_DIR.is_file():
        STATE_DIR.unlink()
    elif STATE_DIR.is_dir():
        shutil.rmtree(STATE_DIR)


def _finish(state: dict, message: str) -> int:
    """Delete the safety backup ref, wipe ``.release/``, and report success."""
    delete_backup(state["version"])
    _wipe_state_dir()
    print(message)
    return EXIT_OK


# -- top-level commands -------------------------------------------------------


def cmd_start(args: argparse.Namespace) -> int:
    """Handle ``release.py start``."""
    if STATE_FILE.is_file():
        existing = load_state()
        existing_version = existing["version"]
        if tag_exists(existing_version):
            # Orphaned state from an already-shipped cycle (e.g. the coda never
            # ran `push --done`, so `.release/` was never wiped). `abort` is
            # ancestor-guarded: it rewinds at most this run's own un-finished
            # recut commits (preserved in the working tree) and never the shipped
            # release - typically nothing, since a shipped cycle's backup ref is
            # not an ancestor of the current HEAD.
            raise ReleaseError(
                f"leftover .release/ state is from v{existing_version}, which is "
                "already tagged (shipped). Run `release.py abort` to clear it - "
                "ancestor-guarded, so it will not rewind the shipped release "
                "(any un-finished recut commits are preserved in the tree)."
            )
        raise ReleaseError(
            f"a release for {existing_version} is already in progress "
            f"(phase {existing['phase']}). Run `release.py status`, `resume`, or "
            "`abort` first."
        )
    return phase_start(args.version, args.skip_review, args.reopen)


def cmd_resume(args: argparse.Namespace) -> int:
    """Handle ``release.py resume`` - dispatch on the current phase."""
    state = load_state()
    guard_resume(state)
    decision = read_decision(args.decision)
    phase = state["phase"]
    if phase == "await_phase1":
        return resume_phase1(state, decision)
    if phase == "await_push":
        return resume_push(state, decision)
    raise ReleaseError(f"nothing to resume - phase is '{phase}'")


def cmd_recut(_args: argparse.Namespace) -> int:
    """
    Handle ``release.py recut`` - the coda re-cut verb.

    Reconcile against the plan; gate only when the plan cannot execute against the
    changed-path universe (an unclaimed orphan or an empty group). Otherwise recut
    silently, re-seed ``confirmed_covered_set``, and validate with lint-diff -
    reporting any advisory ``new_covered``/``dropped`` delta without gating. This
    is the zero-agent-turn path for review-driven fixes (decision 3/5).
    """
    state = load_state()
    guard_resume(state)
    plan = load_plan()
    rec = reconcile(plan, state)
    if rec["blocked"]:
        # The plan cannot execute against the current changed-path universe: an
        # orphan path no group claims, or a group none of the changed paths match
        # (its globs may still match unchanged files). Gate for a plan fix before
        # any git mutation.
        return emit_gate(
            "reconcile",
            {
                "orphans": rec["orphans"],
                "empty_groups": rec["empty_groups"],
                "new_covered": rec["new_covered"],
                "dropped": rec["dropped"],
                "instructions": (
                    "The commit-plan does not match the working tree. Add globs "
                    "for any orphan paths, and remove or repoint any group listed "
                    "in empty_groups, then re-run `release.py recut`."
                ),
            },
            ["update-plan-and-rerun", "abort"],
        )
    subjects = recut(plan, state, validate=lambda: run_make("lint-diff"))
    # Re-seed the confirmed covered set so state tracks what was actually cut.
    # Without this, a later reconcile would keep reporting a stale new/dropped
    # delta for paths this recut already reconciled.
    state["confirmed_covered_set"] = rec["covered"]
    state["head_sha"] = head_sha()
    save_state(state)
    result = {"recut": subjects}
    if rec["new_covered"] or rec["dropped"]:
        result["reconciled"] = {
            "new_covered": rec["new_covered"],
            "dropped": rec["dropped"],
        }
    print(json.dumps(result, indent=2))
    return EXIT_OK


def cmd_push(args: argparse.Namespace) -> int:
    """Handle ``release.py push`` - coda re-push + PR update (+ optional finish)."""
    state = load_state()
    guard_resume(state)
    # Guard: a fix edited but not re-cut would be silently left out of the push -
    # the commits would be stale relative to the working tree. recut is the sole
    # committer, so any plan-covered dirt here means `recut` was skipped.
    stale = uncommitted_covered_paths(load_plan())
    if stale:
        raise ReleaseError(
            "uncommitted changes on plan-covered paths would not be pushed - "
            "run `release.py recut` first:\n  " + "\n  ".join(stale)
        )
    _do_push()
    _upsert_pr(state["version"])
    state["head_sha"] = head_sha()
    save_state(state)
    if args.done:
        return _finish(state, f"release {state['version']} complete - state wiped.")
    print(json.dumps({"pushed": state["version"], "pr": "updated"}, indent=2))
    return EXIT_OK


def cmd_status(_args: argparse.Namespace) -> int:
    """Handle ``release.py status`` - print the current state JSON."""
    state = load_state()
    print(json.dumps(state, indent=2))
    return EXIT_OK


def cmd_abort(_args: argparse.Namespace) -> int:
    """
    Handle ``release.py abort`` - non-destructively unwind and wipe state.

    Soft-rewinds ONLY the commits *this run's recut* created, back to the reset
    target, so their content returns to the working tree uncommitted (NEVER
    ``reset --hard`` - that would delete a first cut's still-uncommitted work).

    The safety backup ref is the authority on whether a rewind is owed: ``recut``
    writes ``refs/release-backup/<version>`` at the pre-recut HEAD before it
    commits, and ``_finish`` deletes it on a clean finish. A rewind is owed only
    when the backup ref both *exists* and is an *ancestor of HEAD*:

    - backup present AND ancestor of HEAD -> a recut ran this session and did not
      finish; rewind to the backup HEAD (exactly the commits recut added),
      preserving content.
    - backup present but NOT an ancestor  -> an orphaned backup from a divergent,
      already-shipped cycle (e.g. the state left over when 1.16.0 shipped as a
      *different* merged commit than its abandoned recut). Soft-resetting to it
      would move the branch onto foreign history and stage a bogus diff - so
      touch nothing; just wipe state.
    - backup absent -> no un-finished recut exists. Any commits since the tag are
      the user's own work or a prior finalized/pushed release; rewinding them
      would unwind published history - touch nothing; wipe state.

    This is the fix for two data-integrity bugs: aborting a no-op re-run
    soft-rewound an already-pushed release (the absent-ref case), and aborting
    against a cross-cycle orphaned backup reset onto divergent history (the
    non-ancestor case).
    """
    state = load_state()
    version = state["version"]
    backup = backup_ref(version)
    have_backup = bool(git(["rev-parse", "--verify", "--quiet", backup], check=False))
    if have_backup and _is_ancestor(backup, "HEAD"):
        # Rewind exactly to the pre-recut HEAD recorded by this run's recut.
        restore_soft(backup)
        print(f"soft-rewound this run's release commits to {backup}; tree preserved.")
    elif have_backup:
        print(
            f"backup ref {backup} is not an ancestor of HEAD (orphaned state from a "
            "divergent/shipped cycle) - leaving commits and working tree untouched; "
            "only wiping .release/ state."
        )
    else:
        print(
            "no un-finished recut to unwind (no backup ref) - leaving commits and "
            "working tree untouched; only wiping .release/ state."
        )
    delete_backup(version)
    _wipe_state_dir()
    print(f"aborted release {version}; .release/ wiped.")
    return EXIT_OK


# -- CLI ----------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    """Construct the argument parser with one subcommand per verb."""
    parser = argparse.ArgumentParser(
        description="Stateful release orchestrator for /release-auto"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_start = sub.add_parser("start", help="Begin a release; run to the phase-1 gate")
    p_start.add_argument("--version", required=True, help="Target version, e.g. 1.16.0")
    p_start.add_argument(
        "--skip-review", action="store_true", help="Skip the review coda"
    )
    p_start.add_argument(
        "--reopen",
        action="store_true",
        help="Re-cut/consolidate an already-pushed release (skips bump + upgrade)",
    )
    p_start.set_defaults(func=cmd_start)

    p_resume = sub.add_parser("resume", help="Feed a gate decision and continue")
    p_resume.add_argument(
        "--decision", required=True, help="Path to decision JSON, or '-' for stdin"
    )
    p_resume.set_defaults(func=cmd_resume)

    p_recut = sub.add_parser(
        "recut", help="Coda re-cut (reconcile + recut + lint-diff)"
    )
    p_recut.set_defaults(func=cmd_recut)

    p_push = sub.add_parser("push", help="Force-with-lease push + PR upsert")
    p_push.add_argument(
        "--done", action="store_true", help="Wipe state after a clean review coda"
    )
    p_push.set_defaults(func=cmd_push)

    sub.add_parser("status", help="Print the current release state").set_defaults(
        func=cmd_status
    )
    sub.add_parser(
        "abort", help="Soft-rewind release commits and wipe state"
    ).set_defaults(func=cmd_abort)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Parse args, dispatch, and translate ``ReleaseError`` into exit code 1."""
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ReleaseError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
