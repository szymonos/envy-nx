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


@pytest.fixture(autouse=True)
def _gate_in_tmp(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep ``emit_gate`` from writing into the real repo's ``.release/``."""
    monkeypatch.setattr(release, "STATE_DIR", tmp_path / ".release")
    monkeypatch.setattr(release, "GATE_FILE", tmp_path / ".release" / "gate.json")
    monkeypatch.setattr(
        release, "DECISION_LOG", tmp_path / ".release" / "decision-log.md"
    )
    monkeypatch.setattr(
        release, "REQUIREMENTS_FILE", tmp_path / ".release" / "requirements.md"
    )
    # No review skill installed unless a test installs one with _install_skills.
    skills = tmp_path / "skills"
    monkeypatch.setattr(release, "BRIEF_SCRIPT", skills / "second-opinion.py")
    monkeypatch.setattr(release, "PR_REVIEW_SCRIPT", skills / "address-pr-review.py")


def _install_skills(*scripts: Path) -> None:
    """Create the review skills' scripts, as if installed in ~/.claude/skills."""
    for script in scripts:
        script.parent.mkdir(parents=True, exist_ok=True)
        script.touch()


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
        "decision-log.md",
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
        def unresolved_for_current_pr() -> list[dict]:
            if boom:
                raise SystemExit(1)
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


def test_open_threads_with_a_skill_older_than_the_helper_is_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An installed copy without unresolved_for_current_pr degrades too."""

    class Older:
        pass

    monkeypatch.setattr(release, "_load_pr_review", lambda: Older)

    assert release.open_threads() is None


def test_open_threads_without_the_sibling_skill_is_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A missing vendored copy must degrade to "unknown", not take the finish down."""
    monkeypatch.setattr(release, "_load_pr_review", lambda: None)

    assert release.open_threads() is None


BOTH = ["second-opinion", "copilot-review"]


def test_review_scripts_live_in_the_user_skills_dir() -> None:
    """The review skills are installed per user, never vendored in the repo."""
    skills = Path.home() / ".claude" / "skills"
    assert release.SKILLS_DIR == skills


@pytest.mark.parametrize(
    ("installed", "skip", "layers"),
    [
        ((), False, []),
        (("BRIEF_SCRIPT",), False, []),  # second-opinion runs at phase 1
        (("PR_REVIEW_SCRIPT",), False, ["copilot-review"]),
        (("BRIEF_SCRIPT", "PR_REVIEW_SCRIPT"), False, ["copilot-review"]),
        (("BRIEF_SCRIPT", "PR_REVIEW_SCRIPT"), True, []),
    ],
)
def test_review_layers_follow_the_installed_skills(
    installed: tuple[str, ...], skip: bool, layers: list[str]
) -> None:
    """address-pr-review adds the coda; --skip-review still turns it off."""
    _install_skills(*(getattr(release, name) for name in installed))

    assert release.review_layers({"skip_review": skip}) == layers


@pytest.mark.parametrize("verb", ["second-opinion", "copilot-review"])
def test_a_layer_without_its_skill_is_skipped(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], verb: str
) -> None:
    """Running a layer whose skill is missing skips it rather than failing."""
    import json

    monkeypatch.setattr(release, "load_state", lambda: pytest.fail("ran"))
    func = release.build_parser().parse_args([verb])

    assert func.func(func) == 0
    assert json.loads(capsys.readouterr().out)["skipped"] == "skill not installed"


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
    paths = [".assets/lib/nx.sh"]
    assert (
        release.changelog_problems(version, body, "v1.26.1", paths)["suggest_version"]
        == expected
    )


@pytest.mark.parametrize(
    ("version", "sections", "expected"),
    [
        ("1.26.2", ("Added",), None),  # a new agent skill verb is still a patch
        ("1.26.2", ("Removed",), None),
        ("1.27.0", ("Added",), "1.26.2"),  # a minor with no product change
        ("1.27.0", ("Changed",), "1.26.2"),
        ("1.27.0", (), "1.26.2"),  # no headings at all
    ],
)
def test_changelog_problems_version_without_a_product_change(
    version: str, sections: tuple[str, ...], expected: str | None
) -> None:
    """Agent skills, tests and CI ship nothing to a user's machine: never a minor."""
    paths = [".claude/skills/x/SKILL.md", "tests/test_x.py", "CHANGELOG.md"]
    body = _section(*sections)
    assert (
        release.changelog_problems(version, body, "v1.26.1", paths)["suggest_version"]
        == expected
    )


def test_changelog_problems_flags_only_bullets_over_the_cap() -> None:
    """Exactly 40 words passes; 41 is flagged."""
    at_cap = "- " + " ".join(["w"] * 40)
    over = "- " + " ".join(["w"] * 41)
    body = f"### Fixed\n\n{at_cap}\n{over}\n"

    assert release.changelog_problems("1.26.2", body, "v1.26.1", [])[
        "long_bullets"
    ] == [over]


# -- copilot-review: the agent triages; a trigger failure is judged, not raised --


def test_copilot_trigger_failure_gates_with_the_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Only the message tells "no Copilot review here" from an auth failure."""
    import json

    _install_skills(release.PR_REVIEW_SCRIPT)
    monkeypatch.setattr(release, "load_state", lambda: {"coda_pushes": 0})

    def pr_review(args: list[str]) -> dict:
        if args[0] == "trigger":
            raise release.ReleaseError("pr_review.py trigger failed (exit 1)")
        return {"state": "A"}

    monkeypatch.setattr(release, "_pr_review", pr_review)
    args = release.build_parser().parse_args(["copilot-review"])

    assert release.cmd_copilot_review(args) == release.EXIT_GATE
    gate = json.loads(release.GATE_FILE.read_text())
    assert gate["kind"] == "review_unavailable"
    assert "exit 1" in gate["context"]["error"]
    assert "rows whose call is escalate" in gate["context"]["instructions"]


@pytest.mark.parametrize(("pushes", "capped"), [(0, False), (1, True)])
def test_copilot_triage_turns_fixes_into_escalations_at_the_cap(
    monkeypatch: pytest.MonkeyPatch, pushes: int, capped: bool
) -> None:
    """Past the cap no fix goes in unasked; before it a fix earns another round."""
    import json

    _install_skills(release.PR_REVIEW_SCRIPT)
    monkeypatch.setattr(release, "load_state", lambda: {"coda_pushes": pushes})
    thread = {"id": "PRRT_x", "path": "a.sh", "body": "b"}
    monkeypatch.setattr(
        release,
        "_pr_review",
        lambda _a: {"state": "C", "unresolvedFreshThreads": [thread]},
    )
    args = release.build_parser().parse_args(["copilot-review"])

    assert release.cmd_copilot_review(args) == release.EXIT_GATE
    ctx = json.loads(release.GATE_FILE.read_text())["context"]
    assert ctx["fix_cycle_cap_reached"] is capped
    assert ("is an escalation instead" in ctx["instructions"]) is capped
    assert "rows whose call is escalate" in ctx["instructions"]
    assert "Show the user" not in ctx["instructions"]


# -- post_decision_log: the run's only record once threads are resolved ---------


def test_decision_log_is_posted_under_a_table_header(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The agent appends rows; the driver adds the header and posts one comment."""
    release.STATE_DIR.mkdir()
    release.DECISION_LOG.write_text("| 1 | a.sh:3 x | decline | style |\n")
    posted: list[str] = []
    monkeypatch.setattr(
        release,
        "_gh",
        lambda a: posted.append(Path(a[a.index("--body-file") + 1]).read_text()),
    )

    release.post_decision_log()

    assert posted[0].startswith("### Review decisions")
    assert "| 1 | a.sh:3 x | decline | style |" in posted[0]
    release.post_decision_log()  # `push --done` retried after a failed label
    assert len(posted) == 1


def test_decision_log_is_printed_when_the_post_fails(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A failed post must not let the wipe take the only copy."""
    release.STATE_DIR.mkdir()
    release.DECISION_LOG.write_text("| 1 | a.sh:3 x | fix | wrong |")

    def boom(_a: list[str]) -> None:
        raise release.ReleaseError("gh pr comment failed")

    monkeypatch.setattr(release, "_gh", boom)

    release.post_decision_log()

    assert "| 1 | a.sh:3 x | fix | wrong |" in capsys.readouterr().err
    assert release.DECISION_LOG.is_file()  # a retry can still post it


def test_no_decision_log_posts_nothing(monkeypatch: pytest.MonkeyPatch) -> None:
    """A run with no review decisions leaves the PR alone."""
    monkeypatch.setattr(release, "_gh", lambda _a: pytest.fail("posted"))

    release.post_decision_log()


# -- _upsert_pr: only an OPEN PR is this release's ------------------------------


@pytest.mark.parametrize(("pr_state", "verb"), [("OPEN", "edit"), ("MERGED", "create")])
def test_upsert_pr_ignores_a_merged_pr(
    monkeypatch: pytest.MonkeyPatch, pr_state: str, verb: str
) -> None:
    """A reused branch name finds its merged PR; editing it would hide the release."""
    calls: list[list[str]] = []
    monkeypatch.setattr(release, "changelog_section", lambda _v: "### Added\n\n- x")
    monkeypatch.setattr(
        release,
        "_run_gh",
        lambda a: release.subprocess.CompletedProcess(a, 0, pr_state + "\n", ""),
    )
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
    _install_skills(release.PR_REVIEW_SCRIPT)
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
    _install_skills(release.PR_REVIEW_SCRIPT)
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


def test_done_without_the_copilot_layer_asks_about_no_threads(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No address-pr-review skill means no review threads to gate on."""
    seen: dict = {}
    monkeypatch.setattr(release, "head_is_published", lambda: True)
    monkeypatch.setattr(release, "open_threads", lambda: pytest.fail("asked"))
    monkeypatch.setattr(
        release,
        "_finish",
        lambda _s, _m, *, check_threads: seen.update(c=check_threads) or 0,
    )

    assert release._done({"version": "1.2.3"}, force=False) == 0
    assert seen["c"] is False


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

    long_bullets = release.changelog_problems("1.26.2", body, "v1.26.1", [])[
        "long_bullets"
    ]

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


# -- gh retry, gate.json, fix-cycle accounting ------------------------------------


def test_run_gh_retries_only_errors_raised_before_reaching_github(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Replaying a call that never reached GitHub cannot apply it twice."""
    seen: list[str] = []
    errors = iter(["dial tcp: i/o timeout", "Timeout trying to log in", ""])

    def run(*_a: object, **_k: object) -> release.subprocess.CompletedProcess[str]:
        err = next(errors)
        seen.append(err)
        return release.subprocess.CompletedProcess([], 1 if err else 0, "", err)

    monkeypatch.setattr(release.subprocess, "run", run)
    monkeypatch.setattr(release.time, "sleep", lambda _s: None)
    assert release._run_gh(["pr", "view"]).returncode == 0
    assert len(seen) == 3

    monkeypatch.setattr(
        release.subprocess,
        "run",
        lambda *_a, **_k: release.subprocess.CompletedProcess([], 1, "", "HTTP 403"),
    )
    with pytest.raises(release.ReleaseError, match="HTTP 403"):
        release._gh(["pr", "edit"])


def test_emit_gate_saves_the_whole_payload_and_names_it_first(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A harness that truncates the print cannot hide a field from gate.json."""
    import json

    monkeypatch.chdir(tmp_path)

    assert release.emit_gate("push", {"commits": ["a"]}, ["approve"]) == 10

    sentinel, printed = capsys.readouterr().out.splitlines()
    payload = json.loads(printed)
    assert sentinel == "DECISION_NEEDED"
    assert next(iter(payload)) == "full_context"
    saved = json.loads(Path(payload["full_context"]).read_text())
    assert saved == {
        "kind": "push",
        "context": {"commits": ["a"]},
        "options": ["approve"],
    }


@pytest.fixture
def push_run(monkeypatch: pytest.MonkeyPatch) -> dict:
    """``cmd_push`` with git, gh and the state file stubbed; returns the saves."""
    saved: dict = {}
    state = {"version": "1.2.3", "coda_pushes": 0, "head_sha": "x"}
    monkeypatch.setattr(release, "load_state", lambda: state)
    monkeypatch.setattr(release, "guard_resume", lambda _s: None)
    monkeypatch.setattr(release, "load_plan", lambda: {"groups": []})
    monkeypatch.setattr(release, "uncommitted_covered_paths", lambda _p: [])
    monkeypatch.setattr(release, "head_sha", lambda: "y")
    monkeypatch.setattr(release, "save_state", lambda s: saved.update(dict(s)))
    return saved


def test_push_that_sends_nothing_is_not_a_fix_cycle(
    push_run: dict,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Retrying a push whose PR update failed must not burn a second cycle."""
    import json

    monkeypatch.setattr(release, "_do_push", lambda: False)
    monkeypatch.setattr(release, "_upsert_pr", lambda _v: None)

    args = release.build_parser().parse_args(["push"])
    assert release.cmd_push(args) == 0
    out = json.loads(capsys.readouterr().out)
    assert push_run["coda_pushes"] == 0
    assert out["pushed"] is None
    assert out["fix_cycles_left"] == release.CODA_PUSH_CAP


def test_push_counts_the_cycle_before_the_pr_update_can_fail(
    push_run: dict, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The push landed; a failing `gh pr edit` must not leave it uncounted."""

    def fail(_v: str) -> None:
        raise release.ReleaseError("gh pr edit failed")

    monkeypatch.setattr(release, "_do_push", lambda: True)
    monkeypatch.setattr(release, "_upsert_pr", fail)

    with pytest.raises(release.ReleaseError):
        release.cmd_push(release.build_parser().parse_args(["push"]))
    assert push_run["coda_pushes"] == 1


def test_coda_next_says_when_the_last_fix_cycle_ran() -> None:
    """Once the round is spent no second Copilot round is offered."""
    layers = ["copilot-review"]
    assert "do not run copilot-review again" in release._coda_next(0, layers)
    assert "again" not in release._coda_next(1, layers)


def test_coda_next_skips_the_round_after_answered_escalations() -> None:
    """An unspent round (Copilot unavailable) still finishes after an answer."""
    assert "only applied answered escalations" in release._coda_next(
        1, ["copilot-review"]
    )


def test_push_before_copilot_engaged_keeps_the_round(
    push_run: dict, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A fix reported before the trigger goes out without spending the round."""
    _install_skills(release.PR_REVIEW_SCRIPT)
    monkeypatch.setattr(release, "copilot_engaged", lambda: False)
    monkeypatch.setattr(release, "_do_push", lambda: True)
    monkeypatch.setattr(release, "_upsert_pr", lambda _v: None)

    assert release.cmd_push(release.build_parser().parse_args(["push"])) == 0
    assert push_run["coda_pushes"] == 0


@pytest.mark.parametrize(
    ("args", "attempts"), [(["pr", "view"], 3), (["pr", "create"], 1)]
)
def test_run_gh_retries_a_dropped_connection_only_when_repeatable(
    monkeypatch: pytest.MonkeyPatch, args: list[str], attempts: int
) -> None:
    """A dropped `gh pr create` may have landed; sending it again would duplicate it."""
    seen: list[int] = []

    def run(*_a: object, **_k: object) -> release.subprocess.CompletedProcess[str]:
        seen.append(1)
        return release.subprocess.CompletedProcess([], 1, "", "Post ...: EOF")

    monkeypatch.setattr(release.subprocess, "run", run)
    monkeypatch.setattr(release.time, "sleep", lambda _s: None)

    release._run_gh(args)
    assert len(seen) == attempts


@pytest.mark.parametrize(
    ("env", "ok"),
    [
        ({"CLAUDECODE": "1"}, True),
        ({"CLAUDECODE": "1", "COPILOT_CLI": "1"}, False),
        ({}, False),
    ],
)
def test_claude_review_runs_only_inside_claude_code(
    monkeypatch: pytest.MonkeyPatch, env: dict[str, str], ok: bool
) -> None:
    """/code-review is a Claude Code skill; Copilot CLI inherits CLAUDECODE."""
    for name in ("CLAUDECODE", "COPILOT_CLI"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)

    assert release._claude_code(True) is ok


@pytest.mark.parametrize(
    ("left", "layers"), [(1, ["copilot-review"]), (0, ["copilot-review"]), (1, [])]
)
def test_coda_next_reads_held_escalations_from_the_log(
    left: int, layers: list[str]
) -> None:
    """Escalations outlive the agent's context, so every finish names their store."""
    assert "rows whose call is escalate" in release._coda_next(left, layers)


def test_coda_next_without_the_copilot_layer_finishes() -> None:
    """The next step never points at a review layer whose skill is missing."""
    text = release._coda_next(1, [])
    assert "push --done" in text and "copilot-review" not in text


# -- second-opinion: a thin wrapper over review_brief.py run --------------------


@pytest.fixture
def opinion_run(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict:
    """A release state in a scratch dir; ``seen`` collects the run command."""
    monkeypatch.chdir(tmp_path)
    _install_skills(release.BRIEF_SCRIPT)
    state = {"version": "1.2.3", "last_tag": "v1.2.2"}
    seen: dict = {"state": state}
    monkeypatch.setattr(release, "load_state", lambda: state)
    monkeypatch.setattr(release, "save_state", lambda s: seen.update(saved=dict(s)))
    monkeypatch.setattr(release, "changelog_section", lambda _v: "### Added\n\n- x")
    return seen


def _stub_run(monkeypatch: pytest.MonkeyPatch, seen: dict, code: int, out: str) -> None:
    def run(cmd: list[str], **kw: object) -> release.subprocess.CompletedProcess[str]:
        seen.update(cmd=cmd, timeout=kw.get("timeout"))
        return release.subprocess.CompletedProcess(cmd, code, out, "")

    monkeypatch.setattr(release.subprocess, "run", run)


def test_second_opinion_hands_the_changelog_section_to_run_as_intent(
    opinion_run: dict,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The release notes are the author's intent; one run per release."""
    import json

    report = {
        "model": "m",
        "findings": [{"id": "F-001", "lens": "logic"}],
        "unparsed": {"inputs": ["### F-9 - huh"]},
        "diffstat": "x",
    }
    _stub_run(monkeypatch, opinion_run, 0, json.dumps(report))
    args = release.build_parser().parse_args(["second-opinion", "--timeout", "100"])

    assert release.cmd_second_opinion(args) == 0
    cmd = opinion_run["cmd"]
    assert cmd[1:3] == ["run", "v1.2.2"]
    # No ledger given: the CHANGELOG section is the whole intent.
    assert Path(cmd[cmd.index("--intent") + 1]).read_text() == "### Added\n\n- x\n"
    assert opinion_run["timeout"] > 100  # the wrapper outlasts every lens pass
    out = json.loads(capsys.readouterr().out)
    assert out["findings"] == report["findings"] and "diffstat" not in out
    assert out["unparsed"] == report["unparsed"]  # a lens to read by hand
    assert opinion_run["saved"]["second_opinion"] == ["release"]
    with pytest.raises(release.ReleaseError, match="already reviewed"):
        release.cmd_second_opinion(args)


def test_second_opinion_fixes_reviews_from_the_published_head(
    opinion_run: dict, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The fix review sees only the round's fixes, with the notes as intent."""
    opinion_run["state"]["second_opinion"] = ["release"]
    notes = tmp_path / "notes.md"
    notes.write_text("## Already decided\n\n- F-1 declined: style")
    monkeypatch.setattr(release, "current_branch", lambda: "release/x")
    monkeypatch.setattr(
        release, "git", lambda a, **_k: "abc123" if "origin/release/x" in a[-1] else ""
    )
    _stub_run(monkeypatch, opinion_run, 0, '{"findings": []}')

    args = release.build_parser().parse_args(["second-opinion", "--fixes", str(notes)])
    assert release.cmd_second_opinion(args) == 0
    cmd = opinion_run["cmd"]
    assert cmd[1:3] == ["run", "abc123"]
    intent = Path(cmd[cmd.index("--intent") + 1]).read_text()
    assert intent.startswith("### Added") and "Already decided" in intent
    assert "--requirements" not in cmd  # no ledger given, none invented
    assert opinion_run["saved"]["second_opinion"] == ["release", "fixes:abc123"]


def test_requirements_ledger_reaches_both_reviews(
    opinion_run: dict, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Given once at phase 1, the ledger goes to the release and the fix review."""
    ledger = tmp_path / "ledger.md"
    ledger.write_text("1. Keep the round count. -> Approach 1\n")
    notes = tmp_path / "notes.md"
    notes.write_text("## Already decided\n")
    monkeypatch.setattr(release, "current_branch", lambda: "release/x")
    monkeypatch.setattr(release, "git", lambda _a, **_k: "abc123")
    _stub_run(monkeypatch, opinion_run, 0, '{"findings": []}')
    parse = release.build_parser().parse_args
    saved = str(release.REQUIREMENTS_FILE)

    release.cmd_second_opinion(parse(["second-opinion", "--requirements", str(ledger)]))
    first = opinion_run["cmd"]
    release.cmd_second_opinion(parse(["second-opinion", "--fixes", str(notes)]))
    second = opinion_run["cmd"]

    for cmd in (first, second):
        assert cmd[cmd.index("--requirements") + 1] == saved
        intent = Path(cmd[cmd.index("--intent") + 1]).read_text()
        assert "## Requirements" not in intent  # review_brief.py adds the heading
    assert release.REQUIREMENTS_FILE.read_text() == ledger.read_text()


def test_requirements_with_fixes_is_refused(opinion_run: dict, tmp_path: Path) -> None:
    """The ledger belongs to phase 1; a second copy on the fix review would drift."""
    args = release.build_parser().parse_args(
        ["second-opinion", "--fixes", "n.md", "--requirements", "r.md"]
    )
    with pytest.raises(release.ReleaseError, match="phase-1 run"):
        release.cmd_second_opinion(args)


@pytest.mark.parametrize("flag", ["--requirements", "--fixes"])
def test_missing_input_file_is_a_release_error(opinion_run: dict, flag: str) -> None:
    """A mistyped path stops with a message, not a traceback."""
    args = release.build_parser().parse_args(["second-opinion", flag, "x.md"])
    with pytest.raises(release.ReleaseError, match=f"{flag} x.md: no such file"):
        release.cmd_second_opinion(args)


def test_each_published_head_gets_its_own_fix_review(
    opinion_run: dict, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Fixes pushed ahead of the Copilot round leave the round's fixes a review."""
    notes = tmp_path / "notes.md"
    notes.write_text("## Already decided\n")
    head = {"sha": "aaa"}
    monkeypatch.setattr(release, "current_branch", lambda: "release/x")
    monkeypatch.setattr(release, "git", lambda _a, **_k: head["sha"])
    _stub_run(monkeypatch, opinion_run, 0, '{"findings": []}')
    args = release.build_parser().parse_args(["second-opinion", "--fixes", str(notes)])

    assert release.cmd_second_opinion(args) == 0
    with pytest.raises(release.ReleaseError, match="already reviewed this fixes"):
        release.cmd_second_opinion(args)
    head["sha"] = "bbb"
    assert release.cmd_second_opinion(args) == 0


def test_push_gate_refuses_an_edit_the_cut_commits_lack(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An escalation answered at the gate must be recut, not pushed past."""
    monkeypatch.setattr(release, "load_plan", lambda: {"groups": []})
    monkeypatch.setattr(release, "uncommitted_covered_paths", lambda _p: ["a.sh"])
    monkeypatch.setattr(release, "_do_push", lambda: pytest.fail("pushed"))

    with pytest.raises(release.ReleaseError, match="recut"):
        release.resume_push({"version": "1.2.3"}, {"approve": True})


@pytest.mark.parametrize(
    ("code", "reason"), [(3, "nothing to review"), (4, "no Copilot CLI")]
)
def test_second_opinion_skips_without_spending_a_run(
    opinion_run: dict,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    code: int,
    reason: str,
) -> None:
    """Parity and a missing Copilot CLI skip the layer; neither blocks the release."""
    import json

    _stub_run(monkeypatch, opinion_run, code, '{"skipped": "x"}')

    assert (
        release.cmd_second_opinion(
            release.build_parser().parse_args(["second-opinion"])
        )
        == 0
    )
    assert json.loads(capsys.readouterr().out)["skipped"] == reason
    assert "saved" not in opinion_run


def test_second_opinion_failure_is_a_release_error(
    opinion_run: dict, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Every lens failing is an error to surface, not an empty review."""
    _stub_run(monkeypatch, opinion_run, 1, "")

    with pytest.raises(release.ReleaseError, match="run failed"):
        release.cmd_second_opinion(
            release.build_parser().parse_args(["second-opinion"])
        )
    assert "saved" not in opinion_run


@pytest.mark.parametrize(
    ("installed", "finished"),
    [((), True), (("BRIEF_SCRIPT",), True), (("PR_REVIEW_SCRIPT",), False)],
)
def test_push_runs_the_coda_only_with_a_review_skill(
    monkeypatch: pytest.MonkeyPatch, installed: tuple[str, ...], finished: bool
) -> None:
    """With no review skill the spine's push ends the run; any skill adds the coda."""
    _install_skills(*(getattr(release, name) for name in installed))
    seen: dict = {}
    for name in ("_do_push", "_upsert_pr", "save_state"):
        monkeypatch.setattr(release, name, lambda *_a: None)
    monkeypatch.setattr(release, "head_sha", lambda: "abc")
    monkeypatch.setattr(release, "load_plan", lambda: {"groups": []})
    monkeypatch.setattr(release, "uncommitted_covered_paths", lambda _p: [])
    monkeypatch.setattr(
        release, "_finish", lambda _s, msg, **_k: seen.update(msg=msg) or 0
    )

    state = {"version": "1.2.3", "skip_review": False}
    assert release.resume_push(state, {"approve": True}) == 0
    assert ("msg" in seen) is finished
