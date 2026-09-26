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
    release.py second-opinion [--files ...]   # coda 4a: heterogeneous-model review
    release.py copilot-review                 # coda 4b: request/await Copilot, triage
    release.py recut                          # coda re-cut (reconcile+recut+lint)
    release.py push [--done [--force]]        # force-with-lease + create/update PR
    release.py integration --since <ts>       # await the integration workflows
    release.py status
    release.py abort                          # soft-rewind commits, wipe .release/
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path, PurePosixPath

# -- constants ----------------------------------------------------------------

STATE_DIR = Path(".release")
STATE_FILE = STATE_DIR / "state.json"
PLAN_FILE = STATE_DIR / "commit-plan.json"
# Deliberately not the live plan name: a leftover under `commit-plan.json` would
# be picked up by `load_plan()` on a run that never authored one, turning "the
# phase-1 gate must author it first" into "we silently shipped last release's".
PREV_PLAN_FILE = STATE_DIR / "commit-plan.prev.json"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_PENDING = 4
EXIT_GATE = 10

# Every path is repo-relative; main() changes to the repo root first. Messages
# name the driver by its absolute path, which runs as printed from any directory.
CLI = str(Path(__file__).resolve())

# Files that always ride with the CHANGELOG commit (content-coupled to the bump).
CHANGELOG_RIDERS = ("CHANGELOG.md", "project-words.txt", "pyproject.toml", "uv.lock")

SECTION_HEADER_RE = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\S+))?\s*$")
SHARED = Path(".claude/skills/release-auto/scripts")
# Committed review policy; copilot-review pre-matches every thread against it.
POLICY = Path(".claude/skills/release-auto/review-policy.json")
# Sibling skills driven by the review coda.
PR_REVIEW_SCRIPT = Path(".claude/skills/address-pr-review/scripts/pr_review.py")
BRIEF_SCRIPT = Path(".claude/skills/second-opinion/scripts/review_brief.py")
# VS Code Server ships the Copilot CLI outside PATH.
COPILOT_FALLBACK = Path(
    "~/.vscode-server/data/User/globalStorage/github.copilot-chat/copilotCli/copilot"
).expanduser()

# Workflows gated on this PR label run the integration suite. The label also
# re-runs them on every push, so it is applied once, when nothing is left to push.
INTEGRATION_LABEL = "test:integration"
INTEGRATION_PASS = ("success", "skipped", "neutral")
GH_TIMEOUT = 60

BULLET_WORD_CAP = 40
# Second-opinion runs allowed per release (the review + one scoped rerun), and
# coda re-pushes after which remaining review threads go back to the user.
SECOND_OPINION_CAP = 2
CODA_PUSH_CAP = 2


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
            f"no .release/state.json - run `{CLI} start --version X.Y.Z` first"
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
            f"Inspect `git log`; re-run `{CLI} start` if this is intentional."
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

    # `lint-diff` on a reopen, not bare `lint`. The CHANGELOG entry is already
    # cut into `## [X.Y.Z]` by then, so `[Unreleased]` is empty and any
    # uncommitted runtime fix trips check-changelog - the same false positive
    # SKILL.md tells the agent never to validate a coda fix with bare `make
    # lint`. `lint-diff` (--from-ref main) runs the same hooks diff-scoped and
    # sees CHANGELOG.md in the diff. A first cut still uses bare `lint`: there
    # is no version block yet, so the hook reads `[Unreleased]` and is right to.
    run_make("lint-diff" if reopen else "lint")
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
        "plan_seed": seed_plan(),
        "instructions": (
            "Compose the CHANGELOG entry (Edit CHANGELOG.md), fix any cspell typos, "
            "then author .release/commit-plan.json (file-granularity glob->commit). "
            "When plan_seed.seeded is true the previous release's plan is already "
            "there - edit it rather than starting over. Resume with a decision: "
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

    problems = changelog_problems(final, changelog_section(final), state["last_tag"])
    unconfirmed = problems["suggest_version"] and not decision.get("version_confirmed")
    if problems["long_bullets"] or unconfirmed:
        save_state(state)
        return emit_gate(
            "changelog",
            {
                **problems,
                "instructions": (
                    f"Split any long_bullets over {BULLET_WORD_CAP} words into two "
                    "bullets. If suggest_version is set, the sections do not match "
                    "the version bump: ask the user, rename the CHANGELOG heading if "
                    "they switch, and resume with version_final set to their choice "
                    'plus "version_confirmed": true.'
                ),
            },
            ["fix-and-resume", "abort"],
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
    save_state(state)

    context = {
        "version": final,
        "commits": subjects,
        "pr_body_preview": changelog_section(final),
        "review_coda": not state.get("skip_review"),
        "instructions": (
            "Review the commit sequence and PR body. Resume with "
            '{"approve": true} to push + open/update the PR, or {"abort": true}. '
            "review_coda reports whether the review coda will run; when it is false "
            'this push wipes the run. If the user asked for the review, add {"review": '
            "true} here - this gate is the last point at which it can be turned on."
        ),
    }
    return emit_gate("push", context, ["approve", "abort"])


def changelog_problems(version: str, body: str, last: str) -> dict:
    """
    Check the composed release section: bullet length and version-vs-sections.

    ``Added``/``Removed`` in a patch release suggests the next minor; a minor or
    major holding only ``Fixed``/``Security`` suggests the next patch. Both are
    measured from ``last`` (the previous tag), since that is what users upgrade
    from. A version that is not ``X.Y.Z`` skips the suggestion.
    """
    bullets: list[str] = []
    for ln in body.splitlines():
        if ln.startswith("- "):
            bullets.append(ln)
        elif bullets and ln.startswith("  ") and ln.strip():
            bullets[-1] += " " + ln.strip()
        else:
            bullets.append("")  # anything else ends the bullet
    long_bullets = [b for b in bullets if len(b[2:].split()) > BULLET_WORD_CAP]
    sections = set(re.findall(r"^### (\w+)", body, re.MULTILINE))
    suggest = None
    try:
        patch = int(version.split(".")[2])
        major, minor, last_patch = (int(x) for x in last.lstrip("v").split(".")[:3])
    except (IndexError, ValueError):
        patch = None
    if patch and sections & {"Added", "Removed"}:
        suggest = f"{major}.{minor + 1}.0"
    elif patch == 0 and sections and sections <= {"Fixed", "Security"}:
        suggest = f"{major}.{minor}.{last_patch + 1}"
    return {"long_bullets": long_bullets, "suggest_version": suggest}


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
    """
    Consume the push decision: force-push, open/update PR, end the spine.

    ``{"review": true}`` is settable here because this gate is the last moment
    before a ``--skip-review`` push wipes the run, and the flag is otherwise
    fixed at ``start`` - a user who asks for the review after the driver was
    launched with ``--skip-review`` would otherwise have to re-run the whole
    spine to get it. One-way on purpose: omitting the key leaves an already
    enabled coda enabled, so forgetting to repeat it cannot silently wipe the
    state the coda runs on.
    """
    if decision.get("abort"):
        raise ReleaseError("push aborted by decision - nothing pushed")
    if not decision.get("approve"):
        raise ReleaseError('push gate needs {"approve": true} or {"abort": true}')
    if decision.get("review"):
        state["skip_review"] = False

    _do_push()
    _upsert_pr(state["version"])

    state["phase"] = "spine_complete"
    state["head_sha"] = head_sha()
    save_state(state)

    if state.get("skip_review"):
        return _finish(state, "spine complete (--skip-review); no review coda.")

    print("SPINE_COMPLETE")
    print(
        json.dumps(
            {
                "version": state["version"],
                "next": (
                    f"Run the review coda: `{CLI} second-opinion`, then "
                    f"`{CLI} copilot-review`. Fold fixes with `{CLI} recut` + "
                    f"`{CLI} push`. Finish with `{CLI} push --done`, which "
                    "triggers the integration tests."
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
    # `gh pr view` also finds a merged or closed PR for a reused branch name
    pr_state = subprocess.run(
        ["gh", "pr", "view", "--json", "state", "--jq", ".state"],
        capture_output=True,
        text=True,
        check=False,
        timeout=GH_TIMEOUT,
    )
    if pr_state.returncode == 0 and pr_state.stdout.strip() == "OPEN":
        _gh(["pr", "edit", "--title", title, "--body", body])
    else:
        _gh(["pr", "create", "--base", "main", "--title", title, "--body", body])


def _gh(args: list[str]) -> None:
    """Run a ``gh`` command, raising ``ReleaseError`` on failure."""
    result = subprocess.run(
        ["gh", *args], capture_output=True, text=True, check=False, timeout=GH_TIMEOUT
    )
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
        return
    if not STATE_DIR.is_dir():
        return
    # The commit plan outlives the wipe, renamed. Everything else in here the
    # driver computed and can recompute in a second; the plan is the one artifact
    # the *agent* authored, and `start --reopen` exists precisely to re-cut an
    # already-pushed release - so throwing it away made the documented
    # consolidation path re-derive every group and commit message from scratch.
    #
    # `is_file()` follows symlinks, so the read is gated on `is_symlink()` for
    # the same reason the directory is above: a symlinked plan would otherwise
    # have an arbitrary file's contents copied out under a name the next run
    # seeds from. Guarding one and not the other is the inconsistency, not the
    # threat model.
    plan = (
        PLAN_FILE.read_bytes()
        if PLAN_FILE.is_file() and not PLAN_FILE.is_symlink()
        else None
    )
    shutil.rmtree(STATE_DIR)
    if plan is not None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        PREV_PLAN_FILE.write_bytes(plan)


def seed_plan() -> dict:
    """
    Copy the last finished release's plan into place for this run to edit.

    Reported in the gate rather than applied silently: a seeded plan is the last
    release's judgment and has to be re-read against this one's diff. Coverage is
    the part that cannot rot unnoticed - ``prevalidate`` rejects an orphan path
    and an empty group - so a stale glob fails loudly. The commit messages and
    the CHANGELOG riders have no such backstop, which is what the note says.
    """
    # `is_symlink() or exists()` on the destination, not `is_file()`: a *broken*
    # symlink is neither a file nor "exists", so it would slip past both and
    # `shutil.copyfile` - which opens the destination for writing - would follow
    # it and create the plan outside `.release/`. It is also the "already
    # authored" check, and a symlink standing in for a plan is not one.
    if PLAN_FILE.is_symlink() or PLAN_FILE.exists():
        return {"seeded": False}
    if PREV_PLAN_FILE.is_symlink() or not PREV_PLAN_FILE.is_file():
        return {"seeded": False}
    shutil.copyfile(PREV_PLAN_FILE, PLAN_FILE)
    try:
        groups = json.loads(PREV_PLAN_FILE.read_text()).get("groups", [])
        subjects = [g.get("message", "") for g in groups if isinstance(g, dict)]
    except (OSError, json.JSONDecodeError, AttributeError):
        subjects = []
    return {
        "seeded": True,
        "from": str(PREV_PLAN_FILE),
        "groups": subjects,
        "note": (
            "The previous release's plan has been copied to .release/commit-plan.json. "
            "Re-read it against diff_name_status and edit it - do not resume on it "
            "unread. Only glob coverage is machine-checked; the commit messages and "
            "the docs(changelog) group's version still describe the last release."
        ),
    }


def _load_pr_review():
    """
    Import the sibling skill's ``pr_review`` module, or None if it is absent.

    By path rather than by name: the script lives under another skill and is not
    importable off ``sys.path``. A missing copy degrades to "unknown" rather than
    taking the finish down - the coda's own ``unresolved`` call is the primary
    check and this is only the backstop.
    """
    if not PR_REVIEW_SCRIPT.is_file():
        return None
    spec = importlib.util.spec_from_file_location("pr_review", PR_REVIEW_SCRIPT)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception:
        return None
    return module


def open_threads() -> list[dict] | None:
    """
    Every unresolved thread on this branch's PR, outdated ones included.

    Outdated threads count. Filtering them out treats "already outdated" as
    "already handled", which is the opposite of true: an outdated thread is one
    an earlier force-push hid from ``pr_review.py state``, so it is *more* likely
    to have been missed than a fresh one, not less.

    Returns None when the question could not be answered - no vendored copy, no
    ``gh``, an auth failure, no PR on the branch. None means "unknown" and ``[]``
    means "nothing is open"; collapsing the two would report a failed lookup as
    a clean PR, which is the exact defect this check exists to remove.
    """
    pr_review = _load_pr_review()
    if pr_review is None:
        return None
    try:
        owner, repo = pr_review._repo_info()
        return pr_review.unresolved_threads(owner, repo, pr_review._auto_pr())
    except SystemExit:
        return None


def _finish(state: dict, message: str, *, check_threads: bool = True) -> int:
    """
    Trigger integration tests, then delete the backup ref and wipe ``.release/``.

    ``push --done`` has already refused on open threads, so it passes
    ``check_threads=False`` unless forced; the ``--skip-review`` path still
    gets the warning. Integration runs only now because nothing is left to
    push, and the label re-runs the suite on every push. The trigger comes
    before the wipe so a failed one raises with the run intact, and
    ``push --done`` can simply be retried.
    """
    still_open = open_threads() if check_threads else []
    integration = trigger_integration()
    delete_backup(state["version"])
    _wipe_state_dir()
    print(message)
    print(json.dumps({"integration": integration}, indent=2))
    if still_open is None:
        print(
            "WARNING: could not check for unresolved review threads - verify the "
            "PR by hand before merging.",
            file=sys.stderr,
        )
    elif still_open:
        print(
            f"WARNING: {len(still_open)} unresolved review thread(s) remain on the PR:",
            file=sys.stderr,
        )
        for thread in still_open:
            flag = " (outdated)" if thread["isOutdated"] else ""
            print(
                f"  {thread['path']}:{thread['line']}{flag} - {thread['id']}",
                file=sys.stderr,
            )
    return EXIT_OK


# -- integration tests --------------------------------------------------------


def integration_workflows() -> list[str]:
    """Workflow files gated on ``INTEGRATION_LABEL``, detected rather than listed."""
    return sorted(
        p.name
        for p in Path(".github/workflows").glob("*.y*ml")
        if INTEGRATION_LABEL in p.read_text()
    )


def trigger_integration() -> dict:
    """
    Apply the integration label to this branch's PR so the suite runs once.

    ``labeled`` fires only when the label is added, so one already present is
    removed first. ``since`` is taken a little before the trigger to absorb
    clock skew between this machine and GitHub.
    """
    workflows = integration_workflows()
    if not workflows:
        return {
            "triggered": False,
            "reason": f"no workflow is gated on {INTEGRATION_LABEL}",
        }
    since = (datetime.now(UTC) - timedelta(seconds=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        labels = _gh_json(["pr", "view", "--json", "labels"])["labels"]
    except subprocess.TimeoutExpired as exc:
        raise ReleaseError(f"gh pr view timed out: {exc}") from exc
    if any(label["name"] == INTEGRATION_LABEL for label in labels):
        _gh(["pr", "edit", "--remove-label", INTEGRATION_LABEL])
    _gh(["pr", "edit", "--add-label", INTEGRATION_LABEL])
    return {
        "triggered": True,
        "since": since,
        "workflows": workflows,
        "next": f"{CLI} integration --since {since}",
    }


def _gh_json(args: list[str]) -> list | dict:
    """Run a ``gh`` command that prints JSON and return it parsed."""
    result = subprocess.run(
        ["gh", *args], capture_output=True, text=True, check=False, timeout=GH_TIMEOUT
    )
    if result.returncode != 0:
        raise ReleaseError(f"gh {' '.join(args)} failed:\n{result.stderr.strip()}")
    return json.loads(result.stdout or "null")


def integration_runs(workflows: list[str], sha: str, since: str) -> dict[str, dict]:
    """
    Latest labelled run per workflow for ``sha`` created at/after ``since``.

    A push without the label also creates a run, whose jobs all skip and whose
    conclusion is ``skipped`` - never an integration result, so never selected.
    A newest ``cancelled`` run is returned as-is (the caller treats it as not
    finished) rather than falling back to an older, superseded success.
    """
    runs: dict[str, dict] = {}
    for wf in workflows:
        found = _gh_json(
            [
                "run",
                "list",
                "--workflow",
                wf,
                "--commit",
                sha,
                "--event",
                "pull_request",
                "--limit",
                "20",
                "--json",
                "databaseId,status,conclusion,createdAt,url",
            ]
        )
        fresh = [
            r
            for r in found or []
            if r["createdAt"] >= since and r["conclusion"] != "skipped"
        ]
        if fresh:
            runs[wf] = max(fresh, key=lambda r: r["createdAt"])
    return runs


def cmd_integration(args: argparse.Namespace) -> int:
    """
    Handle ``release.py integration`` - wait for the labelled runs to finish.

    Stateless (``push --done`` already wiped ``.release/``): the runs are found
    by HEAD's SHA and the trigger time. Exits 0 when every workflow passed, 1
    when one failed (with the failed job names), ``EXIT_PENDING`` when the
    timeout ran out first - re-run the same command to keep waiting.
    """
    workflows = integration_workflows()
    sha = head_sha()
    deadline = time.monotonic() + args.timeout
    runs: dict[str, dict] = {}
    last_error = None
    while True:
        # a transient GitHub error is a missed poll, not a failed test run
        try:
            runs = integration_runs(workflows, sha, args.since)
            last_error = None
        except (ReleaseError, subprocess.TimeoutExpired) as exc:
            last_error = str(exc)
        # a cancelled newest run was superseded by one GitHub has not listed yet
        done = (
            last_error is None
            and len(runs) == len(workflows)
            and all(
                r["status"] == "completed" and r["conclusion"] != "cancelled"
                for r in runs.values()
            )
        )
        if done or time.monotonic() >= deadline:
            break
        time.sleep(args.interval)
    report: dict = {
        "sha": sha,
        "workflows": {
            wf: {k: r.get(k) for k in ("status", "conclusion", "url")}
            for wf, r in runs.items()
        },
        "missing": [wf for wf in workflows if wf not in runs],
    }
    if not done:
        report["pending"] = True
        if last_error:
            report["last_error"] = last_error
        print(json.dumps(report, indent=2))
        return EXIT_PENDING
    failed = {
        wf: r for wf, r in runs.items() if r["conclusion"] not in INTEGRATION_PASS
    }
    for wf, r in failed.items():
        jobs = _gh_json(["run", "view", str(r["databaseId"]), "--json", "jobs"])["jobs"]
        report["workflows"][wf]["failed_jobs"] = [
            j["name"] for j in jobs if j.get("conclusion") not in INTEGRATION_PASS
        ]
    print(json.dumps(report, indent=2))
    return EXIT_ERROR if failed else EXIT_OK


# -- review coda --------------------------------------------------------------


def _copilot_cli() -> str | None:
    """Path to the Copilot CLI, or None when it is not installed."""
    found = shutil.which("copilot")
    if found:
        return found
    return str(COPILOT_FALLBACK) if COPILOT_FALLBACK.is_file() else None


def cmd_second_opinion(args: argparse.Namespace) -> int:
    """
    Handle ``release.py second-opinion`` - coda 4a, a different model family.

    Picks the model from the review brief (premium on trigger paths or large
    diffs) and reviews ``<last-tag>..HEAD`` against the release's CHANGELOG
    section, or only ``--files`` on the one allowed rerun. A missing Copilot
    CLI skips the layer rather than blocking the release.
    """
    state = load_state()
    runs = state.get("second_opinion_runs", 0)
    if runs >= SECOND_OPINION_CAP:
        raise ReleaseError(
            f"second-opinion already ran {runs} times - move on to "
            f"`{CLI} copilot-review`"
        )
    copilot = _copilot_cli()
    if copilot is None:
        print(json.dumps({"skipped": "copilot CLI not found"}, indent=2))
        return EXIT_OK
    tag, version = state["last_tag"], state["version"]
    brief = subprocess.run(
        ["uv", "run", "--frozen", "python", str(BRIEF_SCRIPT), "model", tag],
        capture_output=True,
        text=True,
        check=False,
    )
    if brief.returncode != 0:
        raise ReleaseError(f"review_brief.py model failed:\n{brief.stderr.strip()}")
    choice = json.loads(brief.stdout)
    diff = f"git diff {tag}..HEAD" + (
        " -- " + " ".join(args.files) if args.files else ""
    )
    prompt = (
        "Read .claude/skills/second-opinion/REVIEW-BRIEF.md AND the "
        f"'## [{version}]' section of CHANGELOG.md (the author's stated intent), "
        f"then review the branch's changes since {tag}. Run: {diff}. Dismiss "
        "findings that contradict the documented intent unless the code genuinely "
        "fails to deliver it (then flag the bullet-vs-code gap). Output findings "
        "using the brief's format and severities."
    )
    result = subprocess.run(
        [
            copilot,
            "-p",
            prompt,
            "-s",
            "--model",
            choice["model"],
            "--no-custom-instructions",
            "--excluded-tools",
            "skill",
            "--allow-all-tools",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=args.timeout,
    )
    if result.returncode != 0:
        raise ReleaseError(f"copilot failed:\n{result.stderr.strip()[-2000:]}")
    state["second_opinion_runs"] = runs + 1
    save_state(state)
    header = {
        "model": choice["model"],
        "reasons": choice.get("reasons", []),
        "run": runs + 1,
    }
    print(json.dumps(header))
    print(result.stdout.strip())
    return EXIT_OK


def propose(thread: dict, policy: dict) -> dict | None:
    """
    First policy rule matching ``thread``, as a proposed disposition.

    A rule may name ``match_path`` (glob), ``match_body`` (case-insensitive
    substring) or both; every key it names must match.
    """
    body = thread.get("body", "").lower()
    path = PurePosixPath(thread.get("path") or ".")
    for section in ("known_false_positives", "path_ownership", "accepted_intentional"):
        for rule in policy.get(section, []):
            if "match_path" in rule and not path.full_match(rule["match_path"]):
                continue
            if "match_body" in rule and rule["match_body"].lower() not in body:
                continue
            return {
                "disposition": rule["disposition"],
                "reason": rule["reason"],
                "rule": section,
            }
    return None


def _pr_review(args: list[str]) -> dict:
    """Run a ``pr_review.py`` verb; its stderr (poll progress) passes through."""
    result = subprocess.run(
        ["python3", str(PR_REVIEW_SCRIPT), *args],
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )
    # 0-4 are review states (D, C, B, A) and the wait timeout, but an error also
    # exits 1 - with no JSON on stdout, which is what tells the two apart
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        payload = None
    if result.returncode not in range(5) or not isinstance(payload, dict):
        raise ReleaseError(
            f"pr_review.py {args[0]} failed (exit {result.returncode}), see stderr"
        )
    return payload


def cmd_copilot_review(args: argparse.Namespace) -> int:
    """
    Handle ``release.py copilot-review`` - coda 4b, the Copilot PR review.

    Requests the review only when nobody has (a force-push usually does not
    re-request it), waits, and gates on the fresh threads with a policy
    proposal attached to each. Exits 0 when clean, ``EXIT_PENDING`` when the
    wait timed out, ``EXIT_GATE`` with threads to triage.
    """
    state = load_state()
    review = _pr_review(["state"])
    if review["state"] == "A":
        _pr_review(["trigger"])
    if review["state"] in ("A", "B"):
        review = _pr_review(["wait", "--timeout", str(args.timeout)])
    if review["state"] in ("A", "B"):
        print(json.dumps({"state": review["state"], "pending": True}, indent=2))
        return EXIT_PENDING
    threads = review["unresolvedFreshThreads"]
    if not threads:
        print(json.dumps({"state": review["state"], "threads": []}, indent=2))
        return EXIT_OK
    policy = json.loads(POLICY.read_text()) if POLICY.is_file() else {}
    for thread in threads:
        thread["proposal"] = propose(thread, policy)
    capped = state.get("coda_pushes", 0) >= CODA_PUSH_CAP
    return emit_gate(
        "review_triage",
        {
            "threads": threads,
            "fix_cycle_cap_reached": capped,
            "instructions": (
                "Show the user every thread with its proposal (null = no rule "
                "matched) in one question; confirm or override each. Resolve fix "
                "and resolve-only threads with pr_review.py resolve <id> before "
                f"re-cutting, then `{CLI} recut` + `{CLI} push` and run "
                "copilot-review again."
                + (
                    " The fix-cycle cap is reached: hand the remaining threads to "
                    "the user instead of fixing them in this run."
                    if capped
                    else ""
                )
            ),
        },
        ["triage", "abort"],
    )


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
                f"already tagged (shipped). Run `{CLI} abort` to clear it - "
                "ancestor-guarded, so it will not rewind the shipped release "
                "(any un-finished recut commits are preserved in the tree)."
            )
        raise ReleaseError(
            f"a release for {existing_version} is already in progress "
            f"(phase {existing['phase']}). Run `{CLI} status`, `resume`, or "
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
                    f"in empty_groups, then re-run `{CLI} recut`."
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
    """
    Handle ``release.py push`` - coda re-push + PR update (+ optional finish).

    ``--done`` on a finished run is a no-op, not an error. A ``--skip-review``
    run wipes its own state at the push gate, and a coda that ends on a clean
    review may have already finished - so re-running the documented last step
    landed on "no .release/state.json", which reads as a fault when the release
    had simply already completed.
    """
    if args.done and not STATE_FILE.is_file():
        print(
            json.dumps(
                {
                    "done": True,
                    "pushed": None,
                    "note": "no run in progress; already finished",
                },
                indent=2,
            )
        )
        return EXIT_OK
    state = load_state()
    guard_resume(state)
    # Guard: a fix edited but not re-cut would be silently left out of the push -
    # the commits would be stale relative to the working tree. recut is the sole
    # committer, so any plan-covered dirt here means `recut` was skipped.
    stale = uncommitted_covered_paths(load_plan())
    if stale:
        raise ReleaseError(
            "uncommitted changes on plan-covered paths would not be pushed - "
            f"run `{CLI} recut` first:\n  " + "\n  ".join(stale)
        )
    if args.done:
        return _done(state, force=getattr(args, "force", False))
    _do_push()
    _upsert_pr(state["version"])
    state["head_sha"] = head_sha()
    state["coda_pushes"] = state.get("coda_pushes", 0) + 1
    save_state(state)
    print(json.dumps({"pushed": state["version"], "pr": "updated"}, indent=2))
    return EXIT_OK


def _done(state: dict, *, force: bool) -> int:
    """
    Finish a reviewed release: nothing left to push and no thread left open.

    Pushing here would hand unreviewed commits to the integration run, so an
    unpublished HEAD is refused. Open threads - outdated ones included - gate
    before the state is wiped, so they can still be triaged; ``--force``
    finishes anyway (e.g. GitHub unreachable), with the warning.
    """
    if not head_is_published():
        raise ReleaseError(
            f"HEAD is not pushed - run `{CLI} push` and re-run the review before "
            "finishing"
        )
    threads = open_threads()
    if threads != [] and not force:
        return emit_gate(
            "unresolved_threads",
            {
                "threads": threads,
                "instructions": (
                    "null threads = the lookup failed; otherwise triage each "
                    "thread (outdated ones too) and resolve it with pr_review.py "
                    f"resolve <id>, then re-run `{CLI} push --done`. `--force` "
                    "finishes regardless."
                ),
            },
            ["resolve-and-rerun", "force"],
        )
    return _finish(
        state,
        f"release {state['version']} complete - state wiped.",
        check_threads=threads != [],
    )


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
        "--done",
        action="store_true",
        help="Finish a clean review coda: wipe state, trigger integration tests",
    )
    p_push.add_argument(
        "--force", action="store_true", help="With --done: finish despite open threads"
    )
    p_push.set_defaults(func=cmd_push)

    p_second = sub.add_parser(
        "second-opinion", help="Coda 4a: heterogeneous-model review"
    )
    p_second.add_argument("--files", nargs="+", help="Limit the rerun to these files")
    p_second.add_argument(
        "--timeout", type=int, default=570, help="Seconds (default 570)"
    )
    p_second.set_defaults(func=cmd_second_opinion)

    p_copilot = sub.add_parser(
        "copilot-review", help="Coda 4b: Copilot PR review + triage"
    )
    p_copilot.add_argument(
        "--timeout", type=int, default=480, help="Wait seconds (default 480)"
    )
    p_copilot.set_defaults(func=cmd_copilot_review)

    p_integ = sub.add_parser("integration", help="Wait for the integration workflows")
    p_integ.add_argument(
        "--since", required=True, help="Trigger time printed by push --done"
    )
    p_integ.add_argument(
        "--timeout", type=int, default=540, help="Seconds (default 540)"
    )
    p_integ.add_argument(
        "--interval", type=int, default=30, help="Poll seconds (default 30)"
    )
    p_integ.set_defaults(func=cmd_integration)

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
    if getattr(args, "decision", "-") != "-":
        args.decision = str(Path(args.decision).resolve())
    try:
        top = git(["rev-parse", "--show-toplevel"])
        os.chdir(top)
        return args.func(args)
    except ReleaseError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_ERROR
    except subprocess.TimeoutExpired as exc:
        cmd = " ".join(exc.cmd)
        print(f"ERROR: {cmd} timed out after {exc.timeout}s", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
