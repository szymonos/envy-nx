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
