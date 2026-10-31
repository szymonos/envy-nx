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

Usage (from the repo root):
    .claude/skills/release-auto/scripts/release.py start --version X.Y.Z [--skip-review]
        [--claude-review]
    .claude/skills/release-auto/scripts/release.py resume --decision -
    .claude/skills/release-auto/scripts/release.py second-opinion [--caller MODEL]
        [--fixes NOTES]
    .claude/skills/release-auto/scripts/release.py copilot-review
    .claude/skills/release-auto/scripts/release.py recut
    .claude/skills/release-auto/scripts/release.py push [--done [--force]]
    .claude/skills/release-auto/scripts/release.py integration --since <ts>
    .claude/skills/release-auto/scripts/release.py status
    .claude/skills/release-auto/scripts/release.py abort
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import secrets
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
GATE_FILE = STATE_DIR / "gate.json"
# The release's CHANGELOG section, handed to second-opinion as stated intent.
INTENT_FILE = STATE_DIR / "intent.md"
# The requirements ledger given at phase 1, reused by the fix review.
REQUIREMENTS_FILE = STATE_DIR / "requirements.md"
# Every review call the agent makes, as address-pr-review's decisions JSON:
# `settle` replies to and resolves each thread from it, and `push --done` posts
# it to the PR.
DECISION_LOG = STATE_DIR / "decisions.json"
# One line per review run - model, time, credits - tabled under the decisions.
REVIEWS_LOG = STATE_DIR / "reviews.jsonl"
# Lives in the repo rather than ~/.claude/skills, so rules_added() reads it at a
# fixed path; REVIEW.md links to it.
RULES_FILE = ".github/copilot-instructions.md"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_PENDING = 4
EXIT_GATE = 10

# Every path is repo-relative; main() changes to the repo root first. Messages
# name the driver by its absolute path, which runs as printed from any directory.
CLI = str(Path(__file__).resolve())

# Files that always ride with the CHANGELOG commit (content-coupled to the bump).
CHANGELOG_RIDERS = (
    "CHANGELOG.md",
    "project-words.txt",
    "pyproject.toml",
    "uv.lock",
    ".github/copilot-instructions.md",
)

# What ships to a user's machine. A release touching none of it - agent skills,
# tests, CI, design docs - adds no feature, whatever its CHANGELOG sections say.
PRODUCT_GLOBS = ("nix/**", ".assets/**", "wsl/**", "modules/**")

SECTION_HEADER_RE = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\S+))?\s*$")
SHARED = Path(".claude/skills/release-auto/scripts")
# Review skills are installed per user, not vendored here. second-opinion adds a
# review at the phase-1 gate, address-pr-review the Copilot coda after the push.
SKILLS_DIR = Path.home() / ".claude" / "skills"
PR_REVIEW_SCRIPT = SKILLS_DIR / "address-pr-review" / "scripts" / "pr_review.py"
BRIEF_SCRIPT = SKILLS_DIR / "second-opinion" / "scripts" / "review_brief.py"
RULES_AUDIT_SCRIPT = SKILLS_DIR / "bootstrap-review" / "scripts" / "review_md.py"
# Each skill carries the same triage-rules block; the gates point at it rather
# than restate it, since no parity test reaches across repos.
TRIAGE_RULES = {
    "second-opinion": SKILLS_DIR / "second-opinion" / "SKILL.md",
    "copilot-review": SKILLS_DIR / "address-pr-review" / "SKILL.md",
}
TRIAGE_SUMMARY = (
    "fix a defect you can point to at a file:line (escalate instead when the only "
    "fix breaks a project rule); decline everything else - style, 'consider X', "
    "hardening for a case that cannot happen, however well argued - with a "
    "one-sentence reason, and record a decline that will hold on the next change "
    "as a rule in .github/copilot-instructions.md (REVIEW.md links to it); "
    "resolve-only what is already addressed; escalate only what changes what the "
    "user sees or the release is for, shifts architecture or is hard to reverse, "
    "touches security, or you are unsure of - held for one question at the end"
)
# Escalations wait through the reviews and possibly a compaction, so
# the decision log holds them rather than the agent's memory.
HELD = (
    f"the held escalations are the decisions in {DECISION_LOG} whose call is "
    "still escalate and whose why is empty - none means nothing to ask; ask them "
    "in one AskUserQuestion and rewrite each answered row: a fix is an edit, call "
    "fix and a why saying what changed; the other way is call decline with the "
    "author's reason; 'Leave open' stays escalate with the user's reason as why, "
    "so it is never asked again, its thread left for a human reviewer. Add one "
    "note per question asked ('Asked: ... - left as is.'), then, when an answered "
    f"row carries a thread, run `{PR_REVIEW_SCRIPT} settle {DECISION_LOG}`"
)

# Workflows gated on this PR label run the integration suite. The label also
# re-runs them on every push, so it is applied once, when nothing is left to push.
INTEGRATION_LABEL = "test:integration"
INTEGRATION_PASS = ("success", "skipped", "neutral")
GH_TIMEOUT = 60
# `gh` errors raised before the request reached GitHub, so replaying any call -
# `gh pr create` included - cannot apply it twice. A TLS-intercepting proxy
# produces the handshake timeout in bursts that clear within seconds. "Timeout
# trying to log in" is gh failing to reach GitHub, not a missing login.
TRANSIENT_GH_ERRORS = (
    "TLS handshake timeout",
    "dial tcp",
    "proxyconnect tcp",
    "Timeout trying to log in",
)
# `gh` errors raised after the request may have reached GitHub: the connection
# dropped mid-call, or a gateway answered for it. Retried only for calls that are
# safe to repeat - reads, and edits that set absolute values - never for
# `gh pr create` or `gh pr comment`. Same list as address-pr-review's pr_review.py.
IN_FLIGHT_GH_ERRORS = (
    "EOF",
    "connection reset",
    "i/o timeout",
    "HTTP 502",
    "HTTP 503",
    "HTTP 504",
)
GH_ATTEMPTS = 3
GH_BACKOFF = 2.0
# The release PR's base, and what `start` rebases onto.
TRUNK = "main"

BULLET_WORD_CAP = 40
# One Copilot round: the phase-1 reviews already ran, and a second round mostly
# finds defects in the first round's own fixes. Those fixes get second-opinion
# instead. A push Copilot never reviewed or was asked to does not count.
CODA_PUSH_CAP = 1


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
    True only if HEAD exactly matches ``origin/<branch>``.

    False when the branch was never pushed OR the two SHAs differ for any
    reason - local ahead, behind, or diverged. Any mismatch means the local and
    published states are not identical, so the nothing-to-release guard should not
    treat this as a finished, published release.

    Not ``@{u}``: ``git switch -c x origin/main`` tracks trunk, and the push
    goes to ``origin/<branch>`` whatever the upstream says.
    """
    remote = git(
        ["rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{current_branch()}"],
        check=False,
    )
    return bool(remote) and remote == head_sha()


def tracked_and_untracked(base: str) -> list[str]:
    """
    Return every path that differs between ``base`` and the working tree.

    Tracked changes (``git diff --name-only base``) plus untracked files (``git
    status --porcelain`` ``??`` entries) - exactly what a recut commits, since it
    soft-resets to ``base``, unstages everything and stages the working tree.
    This is the *universe* both ``reconcile`` and ``recut`` pre-validation
    operate on.

    Not the index or ``base..HEAD``: a file a branch commit (or the index) added
    and the working tree deleted again is absent from base and disk alike, so
    ``git add`` would fail on a pathspec that matches nothing.
    """
    paths: set[str] = set()
    # `--no-renames` so a rename surfaces as BOTH its delete (source) and add
    # (destination) paths; otherwise the collapsed source path escapes every
    # group's globs and its removal is never staged (a moved file left duplicated).
    tracked = git(["diff", "--no-renames", "--name-only", base], check=False)
    paths.update(p for p in tracked.splitlines() if p)
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
    ``requires-python = "~=3.14.0"``). full_match anchors the whole path, so a
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

    The rewind writes back a byte copy of the index file, so whatever was staged
    before the run is still staged after it. Not ``write-tree``/``read-tree``: a
    tree drops intent-to-add entries and cannot be written from an index with
    unmerged entries.
    """
    base = state["reset_target"]
    version = state["version"]
    assigned = prevalidate(plan, base)  # raises before any mutation

    pre_head = head_sha()
    index_file = Path(git(["rev-parse", "--git-path", "index"]))
    pre_index = index_file.read_bytes() if index_file.is_file() else None
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
        if pre_index is None:
            restore_soft(pre_head)
        else:
            git(["reset", "--soft", pre_head])
            # Beside the index, then renamed: an interrupted in-place write would
            # destroy the staging this rewind exists to keep.
            tmp = index_file.with_name(index_file.name + ".release-restore")
            tmp.write_bytes(pre_index)
            os.replace(tmp, index_file)
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
        raise ReleaseError(f"{script} failed:\n{result.stderr.strip()}")
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


def rebase_onto_trunk() -> dict:
    """
    Replay the branch onto ``origin/main`` when trunk has moved past its base.

    Uncommitted work is stashed around the rebase, but only when no dirty path
    is one trunk changed - then re-applying the stash cannot conflict. Not
    ``--autostash``: when re-applying conflicts it still exits 0, leaving
    conflict markers in the tree and the stash behind.

    A branch with a merge commit is not rebased: a plain rebase drops merges,
    and with them any edit that exists only in the merge.

    A failed fetch, an overlap or a conflict leaves the branch where it was and
    is reported, not raised: a stale base makes the PR out of date, which
    GitHub shows and the user can fix by hand.
    """
    trunk = f"origin/{TRUNK}"
    try:
        # --tags: a fetch naming a branch follows no tags, and both the last tag
        # and the shipped-version check below must see what main has tagged.
        fetch = subprocess.run(
            ["git", "fetch", "--tags", "origin", TRUNK],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT,
        )
        detail = fetch.stderr.strip()[-500:] if fetch.returncode else None
    except subprocess.TimeoutExpired:
        detail = f"timed out after {GH_TIMEOUT}s"
    if detail is not None:
        return {
            "rebased": False,
            "behind": None,
            "reason": f"`git fetch --tags origin {TRUNK}` failed: {detail}",
        }
    if _is_ancestor(trunk, "HEAD"):
        return {"rebased": False, "behind": 0}
    base = git(["merge-base", trunk, "HEAD"])
    behind = int(git(["rev-list", "--count", f"HEAD..{trunk}"]) or 0)
    if git(["rev-list", "--merges", f"{base}..HEAD"]):
        return {
            "rebased": False,
            "behind": behind,
            "reason": "the branch has merge commits, which a rebase would drop; "
            "rebase by hand",
        }
    dirty = working_tree_dirty_paths()
    trunk_paths = git(["diff", "--name-only", "--no-renames", base, trunk]).splitlines()
    # A path also collides with its ancestors and descendants: trunk adding the
    # file `dir` blocks restoring an untracked `dir/local.txt` just as surely.
    overlap = sorted(
        d
        for d in dirty
        if any(
            d == t or d.startswith(t + "/") or t.startswith(d + "/")
            for t in trunk_paths
        )
    )
    if overlap:
        return {
            "rebased": False,
            "behind": behind,
            "reason": "uncommitted edits to files trunk also changed; "
            "commit them to rebase",
            "paths": overlap,
        }
    before = head_sha()
    stash_tip = ["rev-parse", "--verify", "--quiet", "refs/stash"]
    stash_before = git(stash_tip, check=False)
    if dirty:
        git(["stash", "push", "--include-untracked", "--quiet"])
    # A push that saves nothing still exits 0; popping then would apply an
    # older, unrelated stash.
    stashed = git(stash_tip, check=False) != stash_before
    rebase = subprocess.run(["git", "rebase", trunk], capture_output=True, text=True)
    conflicts: list[str] = []
    if rebase.returncode:
        conflicts = git(
            ["diff", "--name-only", "--diff-filter=U"], check=False
        ).splitlines()
        # A rejecting pre-rebase hook fails before any rebase state exists, and
        # an abort then fails too. The paths are relative to the repo root (cwd).
        if any(
            Path(git(["rev-parse", "--git-path", d])).exists()
            for d in ("rebase-merge", "rebase-apply")
        ):
            git(["rebase", "--abort"])
    if (
        stashed
        and subprocess.run(
            ["git", "stash", "pop", "--index", "--quiet"], capture_output=True
        ).returncode
    ):
        raise ReleaseError(
            "the rebase finished but restoring your uncommitted work failed; it is "
            "safe in `git stash list` - run `git stash pop`, resolve, start again"
        )
    if rebase.returncode:
        return {
            "rebased": False,
            "behind": behind,
            "reason": "rebasing onto trunk conflicts; rebase by hand to resolve",
            "paths": conflicts or [(rebase.stderr or rebase.stdout).strip()[-2000:]],
        }
    return {
        "rebased": True,
        "behind": behind,
        "from": before,
        "onto": git(["rev-parse", trunk]),
    }


# -- gate emission ------------------------------------------------------------


def emit_gate(kind: str, context: dict, options: list[str]) -> int:
    """
    Print the sentinel + decision payload and return the gate exit code.

    The payload is also written whole to ``.release/gate.json``, named first in
    the print: a harness that truncates long output cuts the middle, and the
    fields lost there are exactly the ones nobody notices are missing.
    """
    payload = {"kind": kind, "context": context, "options": options}
    STATE_DIR.mkdir(exist_ok=True)
    GATE_FILE.write_text(json.dumps(payload, indent=2) + "\n")
    print("DECISION_NEEDED")
    print(json.dumps({"full_context": str(GATE_FILE.resolve()), **payload}))
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


def phase_start(
    version: str, skip_review: bool, reopen: bool = False, claude_review: bool = False
) -> int:
    """
    Run the headless pre-gate work and stop at the phase-1 gate.

    Mechanical, in order: refuse shared branch, ``make lint``, bump
    ``pyproject.toml``, then ``make upgrade`` (so ``uv.lock`` picks up the new
    version), gather extract/cspell/diff signals. Then gate so the agent can
    compose CHANGELOG prose, classify cspell findings, and author the plan.
    """
    started_at = time.time()
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

    # A reopen re-cuts committed follow-ups only. An uncommitted fix fails lint
    # before it gets that far: check-changelog reads git's staged set, not the
    # diff it is passed, and the CHANGELOG entry already sits under `## [X.Y.Z]`
    # with `[Unreleased]` empty. Refuse before the fetch and rebase.
    if reopen:
        dirty = working_tree_dirty_paths()
        if dirty:
            raise ReleaseError(
                "`start --reopen` re-cuts committed follow-ups - commit these "
                "first (`git commit --no-verify` is safe: reopen lints and re-cuts "
                "the commit):\n  " + "\n  ".join(dirty)
            )

    # Before lint and the bump, so the release is linted and cut on the trunk the
    # PR merges into. After it the last tag may be newer (a hotfix on main).
    trunk = rebase_onto_trunk()
    tag = last_tag()
    # Checked after the rebase, which can bring the tag in from main; a tagged
    # version has shipped, so --reopen does not apply either.
    if tag_exists(version):
        raise ReleaseError(
            f"v{version} is already tagged (shipped) - pick the next version."
        )

    # `lint-diff` on a reopen, not bare `lint`: bare `lint` checks the working
    # tree against an empty `[Unreleased]`, while `lint-diff` (--from-ref main)
    # lints the committed follow-ups the reopen folds in. A first cut still uses
    # bare `lint`: there is no version block yet, so the hook reads
    # `[Unreleased]` and is right to.
    run_make("lint-diff" if reopen else "lint")
    if not reopen:
        # --reopen freezes the release payload: skip the version bump and dependency
        # upgrade so a consolidation re-cut never re-resolves deps or alters content.
        _bump_pyproject(version)
        run_make("upgrade")

    is_rerun = version_exists(version)
    audit_rules = RULES_AUDIT_SCRIPT.is_file() and Path("REVIEW.md").exists()
    state = {
        "version": version,
        # The decisions comment reports the run's time, and run_id lets a retried
        # `push --done` edit that comment rather than post a second one.
        "started_at": started_at,
        "run_id": secrets.token_hex(6),
        "audit_rules": audit_rules,
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
    # A reopen re-cuts commits that were already reviewed when first cut.
    reviewed = not (skip_review or reopen)
    review = reviewed and BRIEF_SCRIPT.is_file()
    claude_review = reviewed and claude_review and _claude_code(claude_review)
    context = {
        "version": version,
        "is_rerun": is_rerun,
        "review": review,
        "audit_rules": audit_rules,
        "claude_review": claude_review,
        "extract": extract,
        "cspell_findings": cspell,
        "diff_name_status": diff,
        "plan_seed": seed_plan(),
        "trunk": trunk,
        "instructions": (
            "Compose the CHANGELOG entry (Edit CHANGELOG.md), fix any cspell typos, "
            "then author .release/commit-plan.json (file-granularity glob->commit). "
            "When plan_seed.seeded is true the previous release's plan is already "
            "there - edit it rather than starting over. "
        )
        + (
            f"review is true: after the CHANGELOG is written, run `{CLI} "
            "second-opinion --caller <your own model id>` - adding `--requirements "
            "<file>` when the work behind the release has a requirements ledger, "
            "wherever this environment keeps one - and triage its findings "
            f"yourself ({TRIAGE_SUMMARY}; full rules between the triage-rules "
            f"markers in {TRIAGE_RULES['second-opinion']}). Leave fixes "
            "uncommitted - the plan folds them in - and record one decision per "
            f"finding in {DECISION_LOG}, written with the file tool: "
            '{"decisions": [{"round": "pre-push", "finding": "<path:line> <one '
            'line>", "call": "<call>", "why": "<why>"}], "notes": []}. An '
            "escalate row leaves why empty and is held there until the end of the "
            "review. "
            if review
            else ""
        )
        + (
            "audit_rules is true: edit the review rules in "
            ".github/copilot-instructions.md, never through the REVIEW.md link. "
            f"Run `{RULES_AUDIT_SCRIPT} audit` before the plan, "
            "fix each stale-path or stale-symbol finding as an uncommitted edit and "
            "rerun until none remains; for any other finding kind, name it in one "
            "line, suggest /bootstrap-review and carry on. "
            "Also replace a rule's '(<branch> branch)' citation with '(#<PR>)' once "
            "that branch's PR exists. "
            if audit_rules
            else ""
        )
        + (
            f"claude_review is true: then run /code-review at medium on {tag} and the "
            "uncommitted changes, giving it the CHANGELOG section and any requirements "
            "ledger as intent, every "
            "finding declined so far with its reason under 'Already decided', and "
            "triage and log it the same way. "
            if claude_review
            else ""
        )
        + (
            "Resume with a decision: "
            '{"cspell_add": [...], "version_final": "X.Y.Z", "plan_written": true}'
        )
        + (
            f" trunk.rebased is false: tell the user the branch is not on the latest "
            f"origin/{TRUNK} and why (trunk.reason, trunk.paths)."
            if trunk.get("behind") != 0 and not trunk.get("rebased")
            else ""
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
            f"{script} scan failed:\n"
            + (result.stderr.strip() or result.stdout.strip())
        )
    try:
        return json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        raise ReleaseError(f"{script} scan returned unparseable output: {exc}") from exc


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
            f"{script} add failed:\n" + (result.stderr.strip() or result.stdout.strip())
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

    problems = changelog_problems(
        final,
        changelog_section(final),
        state["last_tag"],
        tracked_and_untracked(state["last_tag"]),
    )
    unconfirmed = problems["suggest_version"] and not decision.get("version_confirmed")
    if problems["long_bullets"] or unconfirmed:
        save_state(state)
        return emit_gate(
            "changelog",
            {
                **problems,
                "instructions": (
                    f"Split any long_bullets over {BULLET_WORD_CAP} words into two "
                    "bullets. If suggest_version is set, the sections and changed "
                    "paths do not match the version bump: ask the user, rename the "
                    "CHANGELOG heading if "
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
        "review_coda": review_layers(state),
        "instructions": (
            "Review the commit sequence and PR body. Resume with "
            '{"approve": true} to push + open/update the PR, or {"abort": true}. '
            "review_coda names the Copilot review when address-pr-review is "
            "installed in ~/.claude/skills; when it is empty this push finishes "
            f"the run, so ask the held escalations first ({HELD}); after an "
            f"answered fix, run `{CLI} recut` before approving. "
            'If the user asked for the review, add {"review": true} here - '
            "this gate is the last point at which it can be turned on."
        ),
    }
    return emit_gate("push", context, ["approve", "abort"])


def changelog_problems(version: str, body: str, last: str, paths: list[str]) -> dict:
    """
    Check the composed release section: bullet length and version-vs-sections.

    ``Added``/``Removed`` in a patch release suggests the next minor, but only
    when ``paths`` (everything changed since ``last``) reach ``PRODUCT_GLOBS``.
    A minor or major holding only ``Fixed``/``Security``, or touching no product
    path, suggests the next patch. Both are measured from ``last`` (the previous
    tag), since that is what users upgrade from. A version that is not ``X.Y.Z``
    skips the suggestion.
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
    # ponytail: release-wide, not per bullet - a product fix beside a tooling
    # `Added` still suggests a minor. The gate only asks, so the user settles it.
    product = any(PurePosixPath(p).full_match(g) for p in paths for g in PRODUCT_GLOBS)
    if patch and product and sections & {"Added", "Removed"}:
        suggest = f"{major}.{minor + 1}.0"
    elif patch == 0 and (not product or sections and sections <= {"Fixed", "Security"}):
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
    # An escalation answered at this gate is an edit the cut commits lack.
    stale = uncommitted_covered_paths(load_plan())
    if stale:
        raise ReleaseError(
            "uncommitted changes on plan-covered paths would not be pushed - "
            f"run `{CLI} recut`, then approve again:\n  " + "\n  ".join(stale)
        )

    _do_push()
    _upsert_pr(state["version"])

    state["phase"] = "spine_complete"
    state["head_sha"] = head_sha()
    save_state(state)

    layers = review_layers(state)
    if not layers:
        return _finish(
            state,
            "spine complete; no review coda (--skip-review, or no review skill "
            "installed in ~/.claude/skills).",
        )

    print("SPINE_COMPLETE")
    print(
        json.dumps(
            {
                "version": state["version"],
                "review_coda": layers,
                "fix_cycles_left": CODA_PUSH_CAP - state.get("coda_pushes", 0),
                "next": _coda_next(
                    CODA_PUSH_CAP - state.get("coda_pushes", 0), layers, state
                ),
            },
            indent=2,
        )
    )
    return EXIT_OK


def _do_push() -> bool:
    """
    Push to ``origin/<branch>`` with ``--force-with-lease``; False when in sync.

    Always to the same-named remote branch with ``-u``, never a bare ``git
    push``: a branch made with ``git switch -c x origin/main`` tracks trunk,
    and a bare push would refuse (or, under ``push.default=upstream``, hit main).
    """
    branch = current_branch()
    if not branch or branch == "HEAD":
        raise ReleaseError("detached HEAD - cannot push a release without a branch.")
    remote = f"refs/remotes/origin/{branch}"
    # A reused branch name whose remote was deleted on merge keeps a stale
    # tracking ref, and the lease taken against it rejects the push. `ls-remote
    # --exit-code` exits 2 for "no such ref" in any locale and, unlike a fetch,
    # leaves the lease intact when the branch does exist. Checked before the
    # in-sync shortcut, which a stale ref equal to HEAD would otherwise satisfy.
    if git(["rev-parse", "--verify", "--quiet", remote], check=False):
        gone = subprocess.run(
            ["git", "ls-remote", "--exit-code", "--heads", "origin", branch],
            capture_output=True,
            timeout=GH_TIMEOUT,
        )
        if gone.returncode == 2:
            git(["update-ref", "-d", remote])
    if head_is_published():
        # The branch is already in sync with origin - e.g. pushed out-of-band
        # because this tool cannot push to a guarded remote. Skip the push so the
        # caller still runs _upsert_pr() + finalize instead of aborting on a
        # rejected push (which would strand the PR-body sync and state wipe).
        print("branch already in sync with origin - skipping push")
        return False
    # --force-with-lease even on a first push: recut rewrites history, so a
    # branch that exists on origin but is not tracked locally would reject a
    # plain push. The lease refuses only if origin has commits we have not seen.
    git(["push", "-u", "--force-with-lease", "origin", branch])
    return True


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
    pr_state = _run_gh(["pr", "view", "--json", "state", "--jq", ".state"])
    if pr_state.returncode == 0 and pr_state.stdout.strip() == "OPEN":
        _gh(["pr", "edit", "--title", title, "--body", body])
    else:
        _gh(["pr", "create", "--base", TRUNK, "--title", title, "--body", body])


def _repeatable(args: list[str]) -> bool:
    """Whether a ``gh`` call is safe to send twice: a read, or an absolute edit."""
    return args[:1] == ["run"] or args[:2] in (["pr", "view"], ["pr", "edit"])


def _run_gh(args: list[str]) -> subprocess.CompletedProcess[str]:
    """Run a ``gh`` command, retrying transient errors; in-flight ones if repeatable."""
    tokens = TRANSIENT_GH_ERRORS + (IN_FLIGHT_GH_ERRORS if _repeatable(args) else ())
    for attempt in range(1, GH_ATTEMPTS + 1):
        result = subprocess.run(
            ["gh", *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=GH_TIMEOUT,
        )
        transient = any(token in result.stderr for token in tokens)
        if result.returncode == 0 or not transient or attempt == GH_ATTEMPTS:
            return result
        print(
            f"gh: network error, retrying ({attempt}/{GH_ATTEMPTS - 1})",
            file=sys.stderr,
        )
        time.sleep(GH_BACKOFF * attempt)
    raise AssertionError("unreachable")  # pragma: no cover


def _gh(args: list[str]) -> None:
    """Run a ``gh`` command, raising ``ReleaseError`` on failure."""
    result = _run_gh(args)
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


def copilot_engaged() -> bool:
    """
    Whether Copilot reviewed, or is asked to review, the head a push would replace.

    ``pr_review``'s state A is the one "no": a fix reported before the round was
    triggered can go out without spending it. Unknown counts as engaged - a
    miscount spends the round early, while the other way a failed lookup would
    lift the cap.
    """
    pr_review = _load_pr_review()
    if pr_review is None:
        return True
    try:
        owner, repo = pr_review._repo_info()
        return (
            pr_review._detect_state(owner, repo, pr_review._auto_pr())["state"] != "A"
        )
    except (SystemExit, Exception):
        return True


def open_threads() -> list[dict] | None:
    """
    Every unresolved thread on this branch's PR, outdated ones included.

    Outdated threads count. Filtering them out treats "already outdated" as
    "already handled", which is the opposite of true: an outdated thread is one
    an earlier force-push hid from ``pr_review.py state``, so it is *more* likely
    to have been missed than a fresh one, not less.

    Returns None when the question could not be answered - no installed skill, no
    ``gh``, an auth failure, no PR on the branch. None means "unknown" and ``[]``
    means "nothing is open"; collapsing the two would report a failed lookup as
    a clean PR, which is the exact defect this check exists to remove.
    """
    pr_review = _load_pr_review()
    if pr_review is None:
        return None
    try:
        return pr_review.unresolved_for_current_pr()
    # AttributeError: an installed copy older than the helper.
    except (SystemExit, AttributeError):
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
    # No address-pr-review skill means no way to ask, and nothing to warn about.
    still_open = open_threads() if check_threads and PR_REVIEW_SCRIPT.is_file() else []
    decisions = post_decision_log(state)
    integration = trigger_integration()
    delete_backup(state["version"])
    _wipe_state_dir()
    print(message)
    print(json.dumps({"decisions": decisions, "integration": integration}, indent=2))
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


def rules_added(state: dict) -> list[str]:
    """The bold labels of ``### Author decisions`` bullets this release added."""

    def labels(rev: str, path: str) -> list[str]:
        text = git(["show", f"{rev}:{path}"], check=False)
        section = re.search(
            r"^### Author decisions\n(.*?)(?=^#{1,3} |\Z)", text, re.M | re.S
        )
        return (
            re.findall(r"^- \*\*(.+?)\*\*", section.group(1), re.M) if section else []
        )

    base = state.get("last_tag")
    if not base:
        return []
    # Read the base at every place the rules have lived, so a moved rule is not
    # counted as an added one.
    before = {
        label
        for path in (RULES_FILE, "REVIEW.md", ".claude/REVIEW-BRIEF.md")
        for label in labels(base, path)
    }
    return [label for label in labels("HEAD", RULES_FILE) if label not in before]


def post_decision_log(state: dict) -> str:
    """
    Post the decisions and reviews logs as the PR's ``## Review decisions`` comment.

    Returns ``posted``, ``updated`` or ``none`` (nothing logged). Once the threads
    are resolved this comment is the only record of why each finding was fixed or
    declined, so a failed post raises before ``_finish`` wipes ``.release/``, and
    the retry edits the comment through ``run_id`` instead of posting it twice.
    """
    # Before loading the skill: a run that logged nothing (--skip-review) must not
    # depend on an installed address-pr-review having these helpers.
    if not DECISION_LOG.is_file() and not REVIEWS_LOG.is_file():
        return "none"
    pr_review = _load_pr_review()
    if pr_review is None:
        # No retry can post it either, so print every log rather than keep a run
        # that could never finish.
        for log in (DECISION_LOG, REVIEWS_LOG):
            if log.is_file():
                print(
                    f"WARNING: address-pr-review is not installed, so {log} cannot "
                    "be posted; post it by hand:\n" + log.read_text(),
                    file=sys.stderr,
                )
        return "none"
    try:
        data = {"decisions": [], "notes": []}
        if DECISION_LOG.is_file():
            data = pr_review._load_decisions(str(DECISION_LOG))
            if data is None:
                raise ReleaseError(
                    f"the decision log {DECISION_LOG} is invalid (see above); fix it "
                    f"and run `{CLI} push --done` again"
                )
        reviews = pr_review.load_reviews(REVIEWS_LOG)
        if not data["decisions"] and not reviews:
            return "none"
        notes = [str(n) for n in data.get("notes") or []]
        added = rules_added(state)
        if added and not any(n.startswith("Rules added to REVIEW.md") for n in notes):
            notes.append(f"Rules added to REVIEW.md: {'; '.join(added)}.")
        started = state.get("started_at")
        body = pr_review.decisions_comment(
            {**data, "notes": notes},
            reviews,
            time.time() - started if isinstance(started, int | float) else None,
        )
        owner, repo = pr_review._repo_info()
        action, _url = pr_review.post_decisions(
            owner, repo, pr_review._auto_pr(), body, run_id=state.get("run_id")
        )
    # SystemExit: pr_review reports every gh failure that way. AttributeError: an
    # installed address-pr-review older than these helpers.
    except (SystemExit, AttributeError) as exc:
        raise ReleaseError(
            f"the decisions comment did not post ({exc!r}); the run is kept - run "
            f"`{CLI} push --done` again"
        ) from exc
    return action


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
    result = _run_gh(args)
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


def _claude_code(asked: bool) -> bool:
    """
    Whether ``/code-review`` can run: it is a Claude Code skill.

    Copilot CLI started from a Claude Code shell inherits ``CLAUDECODE`` and sets
    ``COPILOT_CLI``, which wins.
    """
    ok = os.environ.get("CLAUDECODE") == "1" and "COPILOT_CLI" not in os.environ
    if asked and not ok:
        print(
            "release-auto: claude-review needs Claude Code; running the other "
            "reviews without it",
            file=sys.stderr,
        )
    return ok


def review_layers(state: dict) -> list[str]:
    """The Copilot review coda, unless skipped or address-pr-review is missing."""
    if state.get("skip_review") or not PR_REVIEW_SCRIPT.is_file():
        return []
    return ["copilot-review"]


def _skip_missing(script: Path) -> int | None:
    """Report a review layer whose skill is not installed as skipped."""
    if script.is_file():
        return None
    print(json.dumps({"skipped": "skill not installed", "detail": str(script)}))
    return EXIT_OK


def cmd_second_opinion(args: argparse.Namespace) -> int:
    """
    Handle ``release.py second-opinion`` - a different model family, twice at most.

    Delegates to ``review_brief.py run``, which picks the model from the brief
    (the other family to ``--caller``; larger or security-sensitive diffs get a
    stronger model) and reviews a commit against the working tree through its
    lenses. Each run appends its model, time and credits to ``REVIEWS_LOG``.
    At phase 1 the commit is ``<last-tag>``, so the uncommitted bump and
    CHANGELOG are in it. With ``--fixes`` it is the
    published head Copilot reviewed, so only the round's uncommitted fixes are,
    and the agent's notes - what each fix is for, what was declined - follow the
    CHANGELOG section in the intent. A ``--requirements`` ledger given at phase 1
    is kept and passed to both runs, where second-opinion checks every
    ``-> Approach`` row. Each kind runs once. A missing Copilot CLI (its exit 4)
    skips the layer rather than blocking the release.
    """
    if (skipped := _skip_missing(BRIEF_SCRIPT)) is not None:
        return skipped
    if args.fixes and args.requirements:
        raise ReleaseError(
            "--requirements belongs to the phase-1 run; the fix review reuses it"
        )
    for flag, path in (("--requirements", args.requirements), ("--fixes", args.fixes)):
        if path and not Path(path).is_file():
            raise ReleaseError(f"{flag} {path}: no such file")
    state = load_state()
    if args.fixes:
        # One fix review per published head: fixes pushed ahead of the Copilot
        # round leave the round's own fixes a review of their own.
        base = git(["rev-parse", f"refs/remotes/origin/{current_branch()}"])
        kind = f"fixes:{base}"
    else:
        base = state["last_tag"]
        kind = "release"
    done = state.get("second_opinion", [])
    if kind in done:
        raise ReleaseError(
            f"second-opinion already reviewed this {kind.split(':')[0]} - "
            "triage what it found"
        )
    STATE_DIR.mkdir(exist_ok=True)
    if args.requirements:
        shutil.copyfile(args.requirements, REQUIREMENTS_FILE)
    intent = changelog_section(state["version"]) + "\n"
    if args.fixes:
        intent += "\n" + Path(args.fixes).read_text()
    INTENT_FILE.write_text(intent)
    cmd = [
        str(BRIEF_SCRIPT),
        "run",
        base,
        "--intent",
        str(INTENT_FILE),
        "--timeout",
        str(args.timeout),
        "--reviews-log",
        str(REVIEWS_LOG),
        "--stage",
        "fixes" if args.fixes else "pre-push",
    ]
    # review_brief.py picks the other model family from the caller's own id and
    # assumes a Claude caller without one.
    if args.caller:
        cmd += ["--caller", args.caller]
    # review_brief.py keeps no state, so the driver hands the phase-1 ledger to
    # the fix review as well.
    if REQUIREMENTS_FILE.is_file():
        cmd += ["--requirements", str(REQUIREMENTS_FILE)]
    # Each lens pass has its own --timeout and they run concurrently, so the
    # whole run ends a few seconds of git past it.
    result = subprocess.run(
        cmd, capture_output=True, text=True, check=False, timeout=args.timeout + 30
    )
    if result.returncode in (3, 4):
        reason = "nothing to review" if result.returncode == 3 else "no Copilot CLI"
        try:
            detail = json.loads(result.stdout)
        except json.JSONDecodeError:
            detail = result.stdout.strip()
        print(json.dumps({"skipped": reason, "detail": detail}, indent=2))
        return EXIT_OK
    if result.returncode != 0:
        tail = (result.stderr.strip() or result.stdout.strip())[-2000:]
        raise ReleaseError(f"{BRIEF_SCRIPT} run failed:\n{tail}")
    report = json.loads(result.stdout)
    state["second_opinion"] = [*done, kind]
    save_state(state)
    # Everything but the diff summary, so a key run adds later still reaches
    # the agent.
    dropped = ("trunk", "trunk_ref", "commits", "diffstat")
    kept = {k: v for k, v in report.items() if k not in dropped}
    print(json.dumps({"reviewed": kind, **kept}, indent=2))
    return EXIT_OK


def _pr_review(args: list[str]) -> dict:
    """Run a ``pr_review.py`` verb; its stderr (poll progress) passes through."""
    result = subprocess.run(
        ["python3", str(PR_REVIEW_SCRIPT), *args],
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )
    # `drive` exits 0, 1, 3, 4 or 5 by its `result`, but an error also exits 1 -
    # with no JSON on stdout, which is what tells the two apart.
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        payload = None
    if result.returncode not in range(6) or not isinstance(payload, dict):
        raise ReleaseError(
            f"pr_review.py {args[0]} failed (exit {result.returncode}), see stderr"
        )
    return payload


def cmd_copilot_review(args: argparse.Namespace) -> int:
    """
    Handle ``release.py copilot-review`` - coda 4b, the Copilot PR review.

    One ``pr_review.py drive`` call requests the review only when nobody has (a
    force-push usually does not re-request it), waits, and lists every open
    thread, outdated ones included; its ``result`` decides, never its exit code
    alone. Exits 0 when clean, ``EXIT_PENDING`` when the wait timed out,
    ``EXIT_GATE`` with threads to triage or a review that cannot run.
    """
    if (skipped := _skip_missing(PR_REVIEW_SCRIPT)) is not None:
        return skipped
    state = load_state()
    review = _pr_review(
        [
            "drive",
            "--timeout",
            str(args.timeout),
            "--reviews-log",
            str(REVIEWS_LOG),
            "--stage",
            "PR review",
        ]
    )
    result = review.get("result")
    if result == "timeout":
        print(json.dumps({"result": result, "pending": True}, indent=2))
        return EXIT_PENDING
    if result == "clean":
        print(json.dumps({"result": result, "threads": []}, indent=2))
        return EXIT_OK
    if result != "triage":
        # trigger-failed: pr_review.py's message on stderr is the only thing
        # that tells a repo without Copilot code review apart from an auth or
        # network failure. not-requested: somebody removed the request.
        return emit_gate(
            "review_unavailable",
            {
                "result": result,
                "instructions": (
                    "trigger-failed: read the pr_review.py message above. If it "
                    "says Copilot code review is not available for this "
                    "repository, say so in one line; any other error, stop and "
                    "surface it to the user. not-requested: Copilot's review "
                    "request was removed; say so in one line. Either way, unless "
                    f"stopped: {_finish_steps(state)}."
                ),
            },
            ["finish", "stop"],
        )
    threads = review["unresolved"]
    capped = state.get("coda_pushes", 0) >= CODA_PUSH_CAP
    return emit_gate(
        "review_triage",
        {
            "threads": threads,
            "fix_cycle_cap_reached": capped,
            "instructions": (
                "Triage every thread, outdated ones included, yourself and never "
                f"asking mid-loop: {TRIAGE_SUMMARY}. Full rules between the "
                f"triage-rules markers in {TRIAGE_RULES['copilot-review']}. Add one "
                f"decision per thread to {DECISION_LOG}: round 'PR review', its "
                "'thread' id, and a why that is also the thread's reply - what "
                "changed for a fix, why not for a decline, why it no longer "
                "applies for a resolve-only; an escalate leaves why empty and its "
                f"thread open. Then run `{PR_REVIEW_SCRIPT} settle {DECISION_LOG}` "
                "before any recut - the force-push outdates a thread it has not "
                "resolved - and re-run it at once if anything failed. "
                + (
                    "The Copilot round is spent: a thread you would fix is an "
                    f"escalation instead. Then {_finish_steps(state)}."
                    if capped
                    else "If you fixed anything, write .release/fixes-notes.md - "
                    "each finding you fixed, as what that fix is for, then every "
                    "finding declined so far with its reason under an 'Already "
                    f"decided' heading - and run `{CLI} second-opinion --caller "
                    "<your own model id> --fixes .release/fixes-notes.md`. Triage "
                    "it the same way, logging its rows under round 'fixes', then "
                    f"`{CLI} recut` + `{CLI} push`: that is the one round, so run no "
                    "second copilot-review. A round with no fix ends the review: "
                    f"`{CLI} recut` + `{CLI} push` if a decline added a REVIEW.md "
                    f"rule, then {_finish_steps(state)}."
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
    return phase_start(args.version, args.skip_review, args.reopen, args.claude_review)


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
    # A push that sends nothing asks for no review, so it is not a fix cycle, and
    # neither is one replacing a head Copilot never reviewed or was asked to: it
    # carries a fix reported ahead of the round, which still runs. Checked before
    # the push, which moves the head. The count is saved before the PR update can
    # fail: a retry finds the branch in sync and would not count it again.
    engaged = "copilot-review" not in review_layers(state) or copilot_engaged()
    pushed = _do_push()
    if pushed and engaged:
        state["coda_pushes"] = state.get("coda_pushes", 0) + 1
    state["head_sha"] = head_sha()
    save_state(state)
    _upsert_pr(state["version"])
    left = max(0, CODA_PUSH_CAP - state.get("coda_pushes", 0))
    print(
        json.dumps(
            {
                "pushed": state["version"] if pushed else None,
                "pr": "updated",
                "fix_cycles_left": left,
                "next": _coda_next(left, review_layers(state), state),
            },
            indent=2,
        )
    )
    return EXIT_OK


def _finish_steps(state: dict) -> str:
    """
    The end of a reviewed release: escalations, the rules audit, ``push --done``.

    The rules are audited again here because a rule a decline added during the
    Copilot round arrived after the phase-1 audit, and only now does the PR
    number exist for its citation.
    """
    audit = (
        f"audit the review rules again - run `{RULES_AUDIT_SCRIPT} audit`, fix "
        f"each stale-path or stale-symbol finding in {RULES_FILE}, replace this "
        "branch's '(<branch> branch)' citations with '(#<PR>)' (never another "
        "branch's), add a 'Rules audit: N stale rules fixed' note when it changed "
        "anything; "
        if state.get("audit_rules")
        else ""
    )
    return (
        f"ask the held escalations ({HELD}); {audit}if an answered fix, the audit "
        f"or a rule added this round changed any file, run `{CLI} recut` + "
        f"`{CLI} push`, with no further review round; then finish with "
        f"`{CLI} push --done` (`--force` when a thread is deliberately left "
        "open), which posts the decision log"
    )


def _coda_next(left: int, layers: list[str], state: dict) -> str:
    """What the coda does after a push, given its fix cycles and review layers."""
    finish = _finish_steps(state)
    if "copilot-review" not in layers:
        return finish[0].upper() + finish[1:] + "."
    # An answered escalation is the author's decision; another round would only
    # raise findings nobody is left to answer.
    answered = (
        " After a push that only applied answered escalations or the finish "
        f"audit, skip it: {finish}."
    )
    if left:
        return f"Run `{CLI} copilot-review`.{answered}"
    # Said here, not only at triage: a second round mostly reviews the first
    # round's own fixes, which second-opinion has already checked.
    return f"That was the Copilot round - do not run copilot-review again: {finish}."


def _done(state: dict, *, force: bool) -> int:
    """
    Finish a reviewed release: nothing left to push and no thread left open.

    Pushing here would hand unreviewed commits to the integration run, so an
    unpublished HEAD is refused. Open threads - outdated ones included - gate
    before the state is wiped, so they can still be triaged; ``--force``
    finishes anyway (e.g. GitHub unreachable), with the warning.
    """
    if not head_is_published():
        raise ReleaseError(f"HEAD is not pushed - run `{CLI} push` before finishing")
    # Without the Copilot review layer there are no threads this run asked for.
    threads = open_threads() if "copilot-review" in review_layers(state) else []
    if threads != [] and not force:
        return emit_gate(
            "unresolved_threads",
            {
                "threads": threads,
                "instructions": (
                    "null threads = the lookup failed. A thread escalated and left "
                    f"open by the user: finish with `{CLI} push --done --force`. "
                    "Any other thread (outdated ones too): triage it by the same "
                    f"rules, add its decision with its 'thread' id to {DECISION_LOG} "
                    f"unless the log holds it, run `{PR_REVIEW_SCRIPT} settle "
                    f"{DECISION_LOG}`, `{CLI} recut` + `{CLI} push` after any fix, "
                    f"then re-run `{CLI} push --done`."
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
        "--claude-review",
        action="store_true",
        help="Add Claude's /code-review after second-opinion; Claude Code only",
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
        "second-opinion", help="Heterogeneous-model review: phase 1, or --fixes"
    )
    p_second.add_argument(
        "--fixes",
        metavar="NOTES",
        help="Review the Copilot round's fixes alone; NOTES says what each is for",
    )
    p_second.add_argument(
        "--requirements",
        metavar="FILE",
        help="Phase 1: the work's requirements ledger, kept for the fix review too",
    )
    p_second.add_argument(
        "--caller",
        metavar="MODEL",
        help="Your own model id; the review runs on the other model family",
    )
    p_second.add_argument(
        "--timeout", type=int, default=540, help="Seconds per lens pass (default 540)"
    )
    p_second.set_defaults(func=cmd_second_opinion)

    p_copilot = sub.add_parser(
        "copilot-review", help="Coda: Copilot PR review + triage"
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
    # File arguments name the caller's directory; resolve them before the chdir.
    if getattr(args, "decision", "-") != "-":
        args.decision = str(Path(args.decision).resolve())
    for name in ("requirements", "fixes"):
        if getattr(args, name, None):
            setattr(args, name, str(Path(getattr(args, name)).resolve()))
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
