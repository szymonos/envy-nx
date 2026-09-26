"""
Pure-function unit tests for the /release-auto orchestrator (``release.py``).

Scope split: the git-integration behaviour (recut, safety-ref restore, resume
staleness guard) lives in ``tests/bats/test_release_auto.bats`` because it needs
a real isolated git repo. This module covers the *logic* pieces that take plain
data in and give plain data out - glob assignment, reconcile set-diff, CHANGELOG
parsing, plan validation - where pytest parametrization reads far better than a
heredoc-in-bash.

Run via ``uv run pytest`` (or ``make test-unit``, which includes it).
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

# release.py lives under the skill, not on the package path - load it directly.
_RELEASE = (
    Path(__file__).resolve().parents[2]
    / ".claude/skills/release-auto/scripts/release.py"
)
_spec = importlib.util.spec_from_file_location("release", _RELEASE)
assert _spec and _spec.loader
release = importlib.util.module_from_spec(_spec)
sys.modules["release"] = release
_spec.loader.exec_module(release)


PLAN = {
    "groups": [
        {"globs": [".assets/**", "*.sh"], "prefix": "feat", "message": "feat(x): y"},
        {
            "globs": ["CHANGELOG.md", "project-words.txt", "pyproject.toml", "uv.lock"],
            "prefix": "docs",
            "message": "docs(changelog): cut",
        },
    ]
}


# -- match_group / assign_paths ----------------------------------------------


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        (".assets/setup/foo.sh", 0),  # deep glob
        ("build.sh", 0),  # root *.sh
        ("CHANGELOG.md", 1),
        ("pyproject.toml", 1),
        ("README.md", None),  # orphan
        ("docs/index.md", None),
    ],
)
def test_match_group(path: str, expected: int | None) -> None:
    """Each path resolves to the first group whose glob matches, else None."""
    assert release.match_group(path, PLAN) == expected


def test_match_group_first_wins() -> None:
    """Overlapping globs resolve to the earliest group (file-granularity rule)."""
    plan = {
        "groups": [
            {"globs": ["**"], "message": "a"},
            {"globs": ["CHANGELOG.md"], "message": "b"},
        ]
    }
    # group 0's ``**`` claims everything, so CHANGELOG.md lands in 0, not 1.
    assert release.match_group("CHANGELOG.md", plan) == 0


def test_assign_paths_partitions_and_reports_orphans() -> None:
    """assign_paths splits into {group: [paths]} plus a sorted orphan list."""
    paths = [
        ".assets/setup/foo.sh",
        "CHANGELOG.md",
        "pyproject.toml",
        "README.md",
    ]
    assigned, orphans = release.assign_paths(paths, PLAN)
    assert assigned[0] == [".assets/setup/foo.sh"]
    assert set(assigned[1]) == {"CHANGELOG.md", "pyproject.toml"}
    assert orphans == ["README.md"]


def test_assign_paths_orphans_are_sorted() -> None:
    """Orphans come back sorted regardless of input order (deterministic gates)."""
    paths = ["zeta.md", "alpha.md", "mid.md"]  # none match PLAN globs
    _, orphans = release.assign_paths(paths, PLAN)
    assert orphans == ["alpha.md", "mid.md", "zeta.md"]


# -- commit_message -----------------------------------------------------------


def test_commit_message_no_trailers() -> None:
    """A group without trailers yields just the subject."""
    assert release.commit_message({"message": "fix: z"}) == "fix: z"


def test_commit_message_with_trailers() -> None:
    """Trailers are appended as a blank-line-separated block (never re-typed)."""
    msg = release.commit_message(
        {
            "message": "feat: x",
            "trailers": ["Codified-Learning: L-1", "Co-Authored-By: C <c@x>"],
        }
    )
    assert msg == "feat: x\n\nCodified-Learning: L-1\nCo-Authored-By: C <c@x>"


# -- backup_ref ---------------------------------------------------------------


def test_backup_ref_is_version_keyed() -> None:
    """The safety ref namespaces by version so parallel releases never collide."""
    assert release.backup_ref("1.16.0") == "refs/release-backup/1.16.0"


# -- changelog parsing (fixture file, no git) --------------------------------


CHANGELOG = """\
# Changelog

## [Unreleased]

## [1.16.0] - 2026-07-24

### Added

- A shiny thing.

### Fixed

- A broken thing.

## [1.15.0] - 2026-07-20

### Added

- Old thing.
"""


@pytest.fixture
def changelog_file(tmp_path: Path) -> Path:
    """Write the sample CHANGELOG to a temp file and return its path."""
    p = tmp_path / "CHANGELOG.md"
    p.write_text(CHANGELOG)
    return p


def test_changelog_section_extracts_target_body(changelog_file: Path) -> None:
    """changelog_section returns only the requested version's body."""
    body = release.changelog_section("1.16.0", str(changelog_file))
    assert "A shiny thing." in body
    assert "A broken thing." in body
    assert "Old thing." not in body  # stops at the next ## header
    assert "1.15.0" not in body


def test_changelog_section_missing_version(changelog_file: Path) -> None:
    """An absent version yields an empty string, not an error."""
    assert release.changelog_section("9.9.9", str(changelog_file)) == ""


def test_version_exists_true_and_false(changelog_file: Path) -> None:
    """version_exists distinguishes a present block from an absent one."""
    assert release.version_exists("1.16.0", str(changelog_file)) is True
    assert release.version_exists("9.9.9", str(changelog_file)) is False


def test_version_exists_empty_block(tmp_path: Path) -> None:
    """A header with no body still counts as existing (re-run detection)."""
    p = tmp_path / "CHANGELOG.md"
    p.write_text("# Changelog\n\n## [2.0.0] - 2026-07-24\n\n## [1.0.0] - 2026-01-01\n")
    assert release.version_exists("2.0.0", str(p)) is True


# -- _wipe_state_dir ----------------------------------------------------------


def test_wipe_state_dir_removes_decision_and_all(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    A full wipe removes the coda's decision.json too, not just the trio.

    Regression for the 1.16.1 finalizer bug: _finish/_abort unlinked only
    state/plan/policy, leaving .release/decision.json behind, so the "state
    wiped" report lied and stale state leaked into the next `start`.

    The commit plan is the one deliberate survivor (renamed - see below);
    everything else must be gone.
    """
    monkeypatch.chdir(tmp_path)
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    for name in (
        "state.json",
        "commit-plan.json",
        "review-policy.json",
        "decision.json",
    ):
        (state_dir / name).write_text("{}")

    release._wipe_state_dir()

    assert sorted(p.name for p in state_dir.iterdir()) == ["commit-plan.prev.json"]


def test_wipe_state_dir_keeps_the_plan_under_a_different_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    The plan survives the wipe so `start --reopen` is an edit, not a re-derivation.

    Renamed rather than left in place on purpose: a leftover `commit-plan.json`
    would be picked up by load_plan() on a run that never authored one, turning
    "the phase-1 gate must author it first" into shipping last release's plan.
    """
    monkeypatch.chdir(tmp_path)
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    (state_dir / "state.json").write_text("{}")
    (state_dir / "commit-plan.json").write_text('{"groups": [{"message": "feat: x"}]}')

    release._wipe_state_dir()

    assert not (state_dir / "commit-plan.json").exists()
    assert (state_dir / "commit-plan.prev.json").read_text() == (
        '{"groups": [{"message": "feat: x"}]}'
    )


def test_wipe_state_dir_leaves_nothing_when_there_was_no_plan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An aborted run that never authored a plan still wipes to nothing."""
    monkeypatch.chdir(tmp_path)
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    (state_dir / "state.json").write_text("{}")

    release._wipe_state_dir()

    assert not state_dir.exists()


# -- seed_plan ------------------------------------------------------------------


def test_seed_plan_copies_the_previous_plan_and_reports_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    A seeded plan is announced, never applied silently.

    It is the previous release's judgment and has to be re-read against this
    release's diff before it is resumed on.
    """
    monkeypatch.chdir(tmp_path)
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    (state_dir / "commit-plan.prev.json").write_text(
        '{"groups": [{"message": "feat(nix): a"}, {"message": "docs(changelog): b"}]}'
    )

    seed = release.seed_plan()

    assert seed["seeded"] is True
    assert seed["groups"] == ["feat(nix): a", "docs(changelog): b"]
    assert "edit it" in seed["note"]
    assert (state_dir / "commit-plan.json").is_file()


def test_seed_plan_never_overwrites_a_plan_this_run_already_authored(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The live plan wins - seeding must not clobber work already done this run."""
    monkeypatch.chdir(tmp_path)
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    (state_dir / "commit-plan.prev.json").write_text('{"groups": [{"message": "old"}]}')
    (state_dir / "commit-plan.json").write_text('{"groups": [{"message": "mine"}]}')

    assert release.seed_plan() == {"seeded": False}
    assert (
        state_dir / "commit-plan.json"
    ).read_text() == '{"groups": [{"message": "mine"}]}'


def test_seed_plan_is_absent_on_a_first_ever_release(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No previous plan on disk - the gate reports seeded=false rather than failing."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".release").mkdir()

    assert release.seed_plan() == {"seeded": False}


def test_seed_plan_survives_a_corrupt_previous_plan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    A malformed leftover still seeds the file, just with no subject list.

    The plan is the agent's to fix; a truncated write from an interrupted run
    must not make the next `start` unusable.
    """
    monkeypatch.chdir(tmp_path)
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    (state_dir / "commit-plan.prev.json").write_text("{not json")

    seed = release.seed_plan()

    assert seed["seeded"] is True
    assert seed["groups"] == []


def test_wipe_state_dir_is_idempotent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Wiping an already-absent .release/ is a no-op, not an error."""
    monkeypatch.chdir(tmp_path)
    release._wipe_state_dir()  # must not raise
    assert not (tmp_path / ".release").exists()


def test_wipe_state_dir_symlink_does_not_delete_target(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    A `.release` symlink is unlinked, never followed into its target.

    is_dir() follows symlinks, so rmtree gated on it alone could delete an
    arbitrary directory a symlink points at. Only the link must be removed.
    """
    monkeypatch.chdir(tmp_path)
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "keep.txt").write_text("do not delete me")
    (tmp_path / ".release").symlink_to(victim)

    release._wipe_state_dir()

    assert not (tmp_path / ".release").exists()  # link removed
    assert victim.is_dir()  # target untouched
    assert (victim / "keep.txt").read_text() == "do not delete me"


def test_wipe_state_dir_removes_a_stray_regular_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    A regular file named `.release` is unlinked, not silently left behind.

    Otherwise it lingers as stale state and the next STATE_DIR.mkdir() fails.
    """
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".release").write_text("stray")

    release._wipe_state_dir()

    assert not (tmp_path / ".release").exists()


def test_wipe_state_dir_does_not_follow_a_symlinked_plan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    A symlinked commit-plan.json is not read through.

    Same stance the directory guard above takes: is_file() follows symlinks, so
    without this an arbitrary file's contents land under the name the next
    `start` seeds from.
    """
    monkeypatch.chdir(tmp_path)
    secret = tmp_path / "secret.txt"
    secret.write_text("do not copy me")
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    (state_dir / "state.json").write_text("{}")
    (state_dir / "commit-plan.json").symlink_to(secret)

    release._wipe_state_dir()

    assert not (state_dir / "commit-plan.prev.json").exists()
    assert secret.read_text() == "do not copy me"


def test_seed_plan_refuses_a_symlinked_destination(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    A broken symlink at commit-plan.json must not be seeded through.

    `is_file()` is False for a broken link, so it slips past an "already
    authored" check - and shutil.copyfile opens the *destination* for writing,
    which follows the link and creates the plan wherever it points.
    """
    monkeypatch.chdir(tmp_path)
    state_dir = tmp_path / ".release"
    state_dir.mkdir()
    (state_dir / "commit-plan.prev.json").write_text('{"groups": []}')
    outside = tmp_path / "outside.txt"
    (state_dir / "commit-plan.json").symlink_to(outside)

    assert release.seed_plan() == {"seeded": False}
    assert not outside.exists()


# -- open_threads: the push --done backstop -------------------------------------


def _fake_pr_review(
    monkeypatch: pytest.MonkeyPatch,
    threads: list[dict] | None = None,
    boom: bool = False,
) -> None:
    """Stand in for the sibling skill's pr_review module."""

    class Stub:
        @staticmethod
        def _repo_info() -> tuple[str, str]:
            if boom:
                raise SystemExit(1)
            return ("szymonos", "envy-nx")

        @staticmethod
        def _auto_pr() -> int:
            return 74

        @staticmethod
        def unresolved_threads(_o: str, _r: str, _p: int) -> list[dict]:
            return threads or []

    monkeypatch.setattr(release, "_load_pr_review", lambda: Stub)


def test_open_threads_reports_outdated_ones(monkeypatch: pytest.MonkeyPatch) -> None:
    """
    The backstop exists for exactly the threads `state` cannot see.

    Every coda re-push force-pushes, which flips prior threads to isOutdated -
    so filtering them here would blind the terminal command to the ones most
    likely to have been missed.
    """
    _fake_pr_review(monkeypatch, [{"id": "PRRT_x", "isOutdated": True}])

    assert release.open_threads() == [{"id": "PRRT_x", "isOutdated": True}]


def test_open_threads_distinguishes_empty_from_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    `[]` means "nothing open"; None means the lookup failed.

    Collapsing them would report an auth failure as a clean PR - the same defect
    the check exists to remove, one layer down.
    """
    _fake_pr_review(monkeypatch, [])
    assert release.open_threads() == []

    _fake_pr_review(monkeypatch, boom=True)
    assert release.open_threads() is None


def test_open_threads_without_the_sibling_skill_is_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A missing vendored copy must degrade to "unknown", not take the finish down."""
    monkeypatch.setattr(release, "_load_pr_review", lambda: None)

    assert release.open_threads() is None


def test_load_pr_review_finds_the_real_sibling_script() -> None:
    """The hard-coded path must still resolve, or the backstop never fires."""
    module = release._load_pr_review()

    assert module is not None
    assert callable(module.unresolved_threads)


# -- changelog_problems: the pre-recut changelog gate ---------------------------


def _section(*sections: str, bullet: str = "- `x` now does y.") -> str:
    return "\n\n".join(f"### {s}\n\n{bullet}" for s in sections)


@pytest.mark.parametrize(
    ("version", "sections", "expected"),
    [
        ("1.26.2", ("Added",), "1.27.0"),  # feature in a patch -> minor
        ("1.26.2", ("Removed", "Fixed"), "1.27.0"),
        ("1.26.2", ("Fixed",), None),
        ("1.27.0", ("Fixed",), "1.26.2"),  # fixes only in a minor -> patch
        ("1.27.0", ("Fixed", "Security"), "1.26.2"),
        ("1.27.0", ("Added", "Fixed"), None),
        ("1.27.0", ("Changed",), None),  # a behaviour change may earn a minor
        ("next", ("Added",), None),  # not X.Y.Z: no suggestion
    ],
)
def test_changelog_problems_version(
    version: str, sections: tuple[str, ...], expected: str | None
) -> None:
    """Sections that do not match the bump suggest the version users expect."""
    body = _section(*sections)
    assert (
        release.changelog_problems(version, body, "v1.26.1")["suggest_version"]
        == expected
    )


def test_changelog_problems_flags_only_bullets_over_the_cap() -> None:
    """Exactly 40 words passes; 41 is flagged."""
    at_cap = "- " + " ".join(["w"] * 40)
    over = "- " + " ".join(["w"] * 41)
    body = f"### Fixed\n\n{at_cap}\n{over}\n"

    assert release.changelog_problems("1.26.2", body, "v1.26.1")["long_bullets"] == [
        over
    ]


# -- propose: review-policy matching ------------------------------------------

POLICY = {
    "known_false_positives": [
        {"match_body": "ubuntu-slim", "disposition": "resolve-only", "reason": "r1"}
    ],
    "path_ownership": [
        {
            "match_path": "modules/aliases-git/**",
            "disposition": "resolve-only",
            "reason": "r2",
        }
    ],
    "accepted_intentional": [
        {
            "match_path": "nix/**",
            "match_body": "flake.lock",
            "disposition": "resolve-only",
            "reason": "r3",
        }
    ],
}


@pytest.mark.parametrize(
    ("thread", "reason"),
    [
        ({"path": "a.yml", "body": "Use UBUNTU-SLIM?"}, "r1"),  # case-insensitive body
        ({"path": "modules/aliases-git/x/y.ps1", "body": "nit"}, "r2"),
        ({"path": "nix/setup.sh", "body": "commit flake.lock"}, "r3"),
        ({"path": "nix/setup.sh", "body": "unrelated"}, None),  # both keys must match
        ({"path": "wsl/x.ps1", "body": "flake.lock"}, None),
        ({"path": None, "body": "general comment"}, None),
    ],
)
def test_propose(thread: dict, reason: str | None) -> None:
    """Every key a rule names must match; body matching ignores case."""
    got = release.propose(thread, POLICY)
    assert (got or {}).get("reason") == reason


# -- _upsert_pr: only an OPEN PR is this release's ------------------------------


@pytest.mark.parametrize(("pr_state", "verb"), [("OPEN", "edit"), ("MERGED", "create")])
def test_upsert_pr_ignores_a_merged_pr(
    monkeypatch: pytest.MonkeyPatch, pr_state: str, verb: str
) -> None:
    """A reused branch name finds its merged PR; editing it would hide the release."""

    class Result:
        returncode = 0
        stdout = pr_state + "\n"

    calls: list[list[str]] = []
    monkeypatch.setattr(release, "changelog_section", lambda _v: "### Added\n\n- x")
    monkeypatch.setattr(release.subprocess, "run", lambda *_a, **_k: Result())
    monkeypatch.setattr(release, "_gh", calls.append)

    release._upsert_pr("1.2.3")

    assert calls[0][:2] == ["pr", verb]


# -- _done: push --done refuses to wipe what still needs attention ---------------


def test_done_refuses_an_unpushed_head(monkeypatch: pytest.MonkeyPatch) -> None:
    """Finishing would hand unreviewed commits to the integration run."""
    monkeypatch.setattr(release, "head_is_published", lambda: False)

    with pytest.raises(release.ReleaseError, match="not pushed"):
        release._done({"version": "1.2.3"}, force=False)


@pytest.mark.parametrize("threads", [None, [{"id": "PRRT_x", "isOutdated": True}]])
def test_done_gates_before_wiping_on_open_or_unknown_threads(
    monkeypatch: pytest.MonkeyPatch, threads: list | None
) -> None:
    """An unknown lookup gates like an open thread - state survives either way."""
    monkeypatch.setattr(release, "head_is_published", lambda: True)
    monkeypatch.setattr(release, "open_threads", lambda: threads)
    monkeypatch.setattr(release, "_finish", lambda *_a, **_k: pytest.fail("wiped"))

    assert release._done({"version": "1.2.3"}, force=False) == release.EXIT_GATE


@pytest.mark.parametrize(
    ("threads", "force", "check"), [([], False, False), (None, True, True)]
)
def test_done_finishes_when_clean_or_forced(
    monkeypatch: pytest.MonkeyPatch, threads: list | None, force: bool, check: bool
) -> None:
    """Clean finishes silently; --force finishes and keeps the warning."""
    seen: dict = {}
    monkeypatch.setattr(release, "head_is_published", lambda: True)
    monkeypatch.setattr(release, "open_threads", lambda: threads)
    monkeypatch.setattr(
        release,
        "_finish",
        lambda _s, _m, *, check_threads: seen.update(c=check_threads) or 0,
    )

    assert release._done({"version": "1.2.3"}, force=force) == 0
    assert seen["c"] is check  # a forced finish still prints the warning


# -- integration ----------------------------------------------------------------


def test_integration_workflows_detects_the_label(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Only workflows gated on the label count as integration."""
    wf = tmp_path / ".github/workflows"
    wf.mkdir(parents=True)
    (wf / "test_linux.yml").write_text("labels.*.name, 'test:integration'")
    (wf / "lint.yml").write_text("on: push")
    monkeypatch.chdir(tmp_path)

    assert release.integration_workflows() == ["test_linux.yml"]


def test_trigger_integration_re_adds_the_label(monkeypatch: pytest.MonkeyPatch) -> None:
    """`labeled` fires only on add, so a label already present is removed first."""
    calls: list[list[str]] = []
    monkeypatch.setattr(release, "integration_workflows", lambda: ["test_linux.yml"])
    monkeypatch.setattr(
        release, "_gh_json", lambda _a: {"labels": [{"name": "test:integration"}]}
    )
    monkeypatch.setattr(release, "_gh", calls.append)

    out = release.trigger_integration()

    assert calls == [
        ["pr", "edit", "--remove-label", "test:integration"],
        ["pr", "edit", "--add-label", "test:integration"],
    ]
    assert out["triggered"] and out["since"].endswith("Z")


def test_trigger_integration_without_gated_workflows(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No gated workflow means nothing to trigger, not an error."""
    monkeypatch.setattr(release, "integration_workflows", lambda: [])

    assert release.trigger_integration()["triggered"] is False


def _run(status: str, conclusion: str | None = None) -> dict:
    return {"databaseId": 1, "status": status, "conclusion": conclusion, "url": "u"}


@pytest.mark.parametrize(
    ("runs", "expected"),
    [
        (
            {
                "a.yml": _run("completed", "success"),
                "b.yml": _run("completed", "skipped"),
            },
            0,
        ),
        (
            {
                "a.yml": _run("completed", "success"),
                "b.yml": _run("completed", "failure"),
            },
            1,
        ),
        ({"a.yml": _run("completed", "success"), "b.yml": _run("in_progress")}, 4),
        ({"a.yml": _run("completed", "success")}, 4),  # b.yml has not started yet
    ],
)
def test_cmd_integration_exit_codes(
    monkeypatch: pytest.MonkeyPatch, runs: dict, expected: int
) -> None:
    """0 all passed, 1 a failure, 4 still running or not started."""
    monkeypatch.setattr(release, "integration_workflows", lambda: ["a.yml", "b.yml"])
    monkeypatch.setattr(release, "head_sha", lambda: "abc")
    monkeypatch.setattr(release, "integration_runs", lambda *_a: runs)
    monkeypatch.setattr(
        release,
        "_gh_json",
        lambda _a: {"jobs": [{"name": "j", "conclusion": "failure"}]},
    )
    args = release.build_parser().parse_args(
        ["integration", "--since", "2026-01-01T00:00:00Z", "--timeout", "0"]
    )

    assert release.cmd_integration(args) == expected


def test_integration_runs_never_selects_a_skipped_run(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An unlabelled push run concludes `skipped`; picking it would be a false pass."""
    listed = [
        {
            "createdAt": "2026-01-01T00:02:00Z",
            "conclusion": "skipped",
            "status": "completed",
        },
        {
            "createdAt": "2026-01-01T00:01:00Z",
            "conclusion": None,
            "status": "in_progress",
        },
        {
            "createdAt": "2025-12-31T00:00:00Z",
            "conclusion": "success",
            "status": "completed",
        },
    ]
    monkeypatch.setattr(release, "_gh_json", lambda _a: listed)

    runs = release.integration_runs(["a.yml"], "abc", "2026-01-01T00:00:00Z")

    assert runs["a.yml"]["status"] == "in_progress"


def test_cmd_integration_rides_out_a_github_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A transient GitHub error is a missed poll, not a failed run."""

    def boom(*_a: object) -> dict:
        raise release.ReleaseError("TLS handshake timeout")

    monkeypatch.setattr(release, "integration_workflows", lambda: ["a.yml"])
    monkeypatch.setattr(release, "head_sha", lambda: "abc")
    monkeypatch.setattr(release, "integration_runs", boom)
    args = release.build_parser().parse_args(
        ["integration", "--since", "2026-01-01T00:00:00Z", "--timeout", "0"]
    )

    assert release.cmd_integration(args) == release.EXIT_PENDING


def test_trigger_integration_only_removes_a_present_label(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Removing an absent label is not attempted, so its failure cannot be masked."""
    calls: list[list[str]] = []
    monkeypatch.setattr(release, "integration_workflows", lambda: ["test_linux.yml"])
    monkeypatch.setattr(release, "_gh_json", lambda _a: {"labels": []})
    monkeypatch.setattr(release, "_gh", calls.append)

    release.trigger_integration()

    assert calls == [["pr", "edit", "--add-label", "test:integration"]]


def test_finish_keeps_the_run_when_the_trigger_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A failed label must leave state in place so `push --done` can be retried."""

    def boom() -> dict:
        raise release.ReleaseError("gh pr edit failed")

    monkeypatch.setattr(release, "trigger_integration", boom)
    monkeypatch.setattr(release, "_wipe_state_dir", lambda: pytest.fail("wiped"))
    monkeypatch.setattr(release, "delete_backup", lambda _v: pytest.fail("deleted"))

    with pytest.raises(release.ReleaseError):
        release._finish({"version": "1.2.3"}, "done", check_threads=False)


def test_changelog_problems_counts_a_wrapped_bullet_whole() -> None:
    """A bullet wrapped onto a continuation line is still one bullet."""
    body = "### Fixed\n\n- " + " ".join(["w"] * 30) + "\n  " + " ".join(["w"] * 20)

    long_bullets = release.changelog_problems("1.26.2", body, "v1.26.1")["long_bullets"]

    assert len(long_bullets) == 1


@pytest.mark.parametrize(("code", "stdout"), [(1, ""), (1, "not json"), (7, "{}")])
def test_pr_review_error_is_a_release_error(
    monkeypatch: pytest.MonkeyPatch, code: int, stdout: str
) -> None:
    """Exit 1 is also state C, so only a JSON payload proves the call worked."""

    class Result:
        returncode = code

    Result.stdout = stdout
    monkeypatch.setattr(release.subprocess, "run", lambda *_a, **_k: Result())

    with pytest.raises(release.ReleaseError):
        release._pr_review(["state"])


def test_a_cancelled_newest_run_is_pending_not_an_older_success(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Re-adding the label cancels a run; it must not fall back to an older success."""
    listed = [
        {
            "createdAt": "2026-01-01T00:02:00Z",
            "conclusion": "cancelled",
            "status": "completed",
        },
        {
            "createdAt": "2026-01-01T00:01:00Z",
            "conclusion": "success",
            "status": "completed",
        },
    ]
    monkeypatch.setattr(release, "_gh_json", lambda _a: listed)
    runs = release.integration_runs(["a.yml"], "abc", "2026-01-01T00:00:00Z")
    assert runs["a.yml"]["conclusion"] == "cancelled"

    monkeypatch.setattr(release, "integration_workflows", lambda: ["a.yml"])
    monkeypatch.setattr(release, "head_sha", lambda: "abc")
    monkeypatch.setattr(release, "integration_runs", lambda *_a: runs)
    args = release.build_parser().parse_args(
        ["integration", "--since", "2026-01-01T00:00:00Z", "--timeout", "0"]
    )
    assert release.cmd_integration(args) == release.EXIT_PENDING


def test_main_reports_a_gh_timeout_as_an_error(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A hung `gh` call ends in the driver's ERROR line, not a traceback."""

    def hang(_args: object) -> int:
        raise release.subprocess.TimeoutExpired(["gh", "pr", "view"], 60)

    monkeypatch.setattr(release, "cmd_status", hang)
    monkeypatch.setattr(release, "git", lambda _a, **_k: ".")
    monkeypatch.setattr(release.os, "chdir", lambda _p: None)

    assert release.main(["status"]) == release.EXIT_ERROR
    assert "timed out after 60s" in capsys.readouterr().err
