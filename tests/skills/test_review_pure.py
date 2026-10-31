"""
Pure-function unit tests for the /review skill's script (``review.py``).

The ownership check over the real tree runs in the ``check-arch-drift`` hook and
its bats tests; this module covers the logic that takes plain data in and gives
plain data out - glob precedence, the rotation pick, history.md parsing and
rendering, and the finish gate.

Run via ``uv run pytest`` (or ``make test-unit``, which includes it).
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_REVIEW = (
    Path(__file__).resolve().parents[2] / ".claude/skills/review/scripts/review.py"
)
_spec = importlib.util.spec_from_file_location("review", _REVIEW)
assert _spec and _spec.loader
review = importlib.util.module_from_spec(_spec)
sys.modules["review"] = review
_spec.loader.exec_module(review)

MANIFEST = {
    "skip": ["modules/vendored/*"],
    "unowned_ok": ["docs/*"],
    "shards": [
        {"name": "lib", "owns": [".assets/lib/*"]},
        {
            "name": "doctor",
            "owns": [".assets/lib/nx_doctor.sh", "tests/bats/test_nx_doctor.bats"],
        },
        {"name": "nx", "owns": ["tests/bats/test_nx_*.bats"]},
    ],
}


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        (".assets/lib/helpers.sh", ["lib"]),
        (".assets/lib/nx_doctor.sh", ["doctor"]),  # exact path beats the glob
        ("tests/bats/test_nx_doctor.bats", ["doctor"]),
        ("tests/bats/test_nx_pkgs.bats", ["nx"]),
        ("modules/vendored/a.ps1", []),  # skip owns nothing
        ("docs/index.md", []),
        ("wsl/new.ps1", []),
    ],
)
def test_owners_most_specific_glob_wins(path: str, expected: list[str]) -> None:
    """The most specific matching glob owns a path; skip owns nothing."""
    assert review.owners(path, MANIFEST) == expected


def test_owners_tie_returns_both() -> None:
    """Two shards tying at one specificity both come back."""
    manifest = {
        "shards": [{"name": "a", "owns": ["x/*"]}, {"name": "b", "owns": ["x/*"]}]
    }
    assert review.owners("x/f.sh", manifest) == ["a", "b"]


def test_coverage_reports_unowned_but_excuses_skip_and_unowned_ok() -> None:
    """Only a file nothing owns or excuses is reported."""
    files = [".assets/lib/a.sh", "docs/x.md", "modules/vendored/v.ps1", "wsl/new.ps1"]
    unowned, ambiguous = review.coverage(files, MANIFEST)
    assert unowned == ["wsl/new.ps1"]
    assert ambiguous == {}


def test_nearest_shard_uses_closest_directory() -> None:
    """The suggested owner comes from the closest directory with owned files."""
    files = [".assets/lib/a.sh", ".assets/lib/b.sh", "tests/bats/test_nx_x.bats"]
    assert review.nearest_shard(".assets/lib/new.sh", MANIFEST, files) == "lib"
    assert review.nearest_shard("wsl/new.ps1", MANIFEST, files) is None


def _row(shard: str, **kw) -> dict:
    row = {
        "shard": shard,
        "blast": "medium",
        "last": "2026-10-01",
        "commits": 0,
        "followups": 0,
        "charter_changed": False,
    }
    return {**row, **kw}


def test_rotation_order() -> None:
    """Never-reviewed, then hand-offs, then charter change, churn, age."""
    rows = [
        _row("busy", commits=12),
        _row("quiet", last="2026-01-01"),
        _row("handed", followups=1),
        _row("new-low", last=None, blast="low", commits=None),
        _row("new-high", last=None, blast="high", commits=None),
        _row("recharted", charter_changed=True),
    ]
    order = [r["shard"] for r in sorted(rows, key=review._pick_key)]
    assert order == ["new-high", "new-low", "handed", "recharted", "busy", "quiet"]


HISTORY = """# Review history

## Runs

| Date | Shard | Charter | Found | Fixed | Declined | Escalated | Handed off | Branch |
| ---- | ----- | ------- | ----- | ----- | -------- | --------- | ---------- | ------ |
| 2026-11-01 | certs | aaaa1111 | 2 | 1 | 1 | 0 | 1 | review/certs-2026-11-01 |

## Open follow-ups

| ID | For | Where | Finding | From |
| -- | --- | ----- | ------- | ---- |
| FU-001 | wsl | wsl/x.ps1:3 | drops the cert | certs 2026-11-01 |

## Decision logs

### 2026-11-01 certs

| ID | Where | Finding | Call | Owner | Why |
| -- | ----- | ------- | ---- | ----- | --- |
| F-001 | .assets/lib/certs.sh:10 | wrong bundle | fix | certs | real bug |
| R-001 | .assets/lib/certs.sh:20 | add a retry | decline | certs | cannot happen |
| R-002 | wsl/x.ps1:3 | drops the cert | handoff | wsl | FU-001: needs the wsl charter |
"""


def test_parse_history() -> None:
    """Runs, follow-ups and decision logs parse from history.md."""
    parsed = review.parse_history(HISTORY)
    assert parsed["runs"] == [
        {"date": "2026-11-01", "shard": "certs", "charter": "aaaa1111"}
    ]
    assert [fu["id"] for fu in parsed["followups"]] == ["FU-001"]
    assert parsed["followups"][0]["for"] == "wsl"
    assert [r["call"] for r in parsed["logs"][0]["rows"]] == [
        "fix",
        "decline",
        "handoff",
    ]


def test_earlier_declines_only_for_the_shard() -> None:
    """Only the shard's own declines are carried into its next run."""
    parsed = review.parse_history(HISTORY)
    assert [d["id"] for d in review.earlier_declines(parsed, "certs")] == ["R-001"]
    assert review.earlier_declines(parsed, "wsl") == []


def test_next_followup_id_counts_every_mention() -> None:
    """Follow-up ids continue past every FU-NNN in the file."""
    assert review.next_followup_id(HISTORY) == 2
    assert review.next_followup_id("") == 1


STATE = {
    "shard": "wsl",
    "branch": "review/wsl-2026-11-05",
    "charter": "bbbb2222",
    "date": "2026-11-05",
    "carried": ["FU-001"],
}


def test_render_history_closes_carried_and_opens_handoffs() -> None:
    """A decided carried-in row closes; a handoff opens the next id."""
    rows = [
        {
            "id": "FU-001",
            "where": "wsl/x.ps1:3",
            "finding": "drops the cert",
            "call": "fix",
            "owner": "wsl",
            "why": "confirmed",
        },
        {
            "id": "F-001",
            "where": "wsl/y.ps1:9",
            "finding": "proxy unset",
            "call": "handoff",
            "owner": "certs",
            "why": "cert code",
        },
    ]
    counts = {"found": 1, "fix": 1, "decline": 0, "escalate": 0, "handoff": 1}
    text = review.render_history(HISTORY, STATE, rows, counts)
    parsed = review.parse_history(text)
    assert [fu["id"] for fu in parsed["followups"]] == ["FU-002"]
    assert parsed["followups"][0]["for"] == "certs"
    assert parsed["runs"][-1]["shard"] == "wsl"
    # The earlier run's log still names FU-001: closing touches only the open table.
    assert "FU-001: needs the wsl charter" in text
    log = parsed["logs"][-1]["rows"]
    assert log[1]["why"] == "FU-002: cert code"


def test_render_history_bootstraps_an_empty_file() -> None:
    """A first run creates the file with every section."""
    state = {**STATE, "carried": []}
    rows = [
        {
            "id": "R-001",
            "where": "a:1",
            "finding": "x",
            "call": "decline",
            "owner": "wsl",
            "why": "y",
        }
    ]
    counts = {"found": 1, "fix": 0, "decline": 1, "escalate": 0, "handoff": 0}
    parsed = review.parse_history(review.render_history("", state, rows, counts))
    assert parsed["runs"][0]["shard"] == "wsl"
    assert parsed["logs"][0]["rows"][0]["call"] == "decline"


SHARDS = {
    "shards": [
        {"name": "wsl", "owns": ["wsl/*"]},
        {"name": "certs", "owns": ["certs/*"]},
    ]
}


def _log(*rows: tuple[str, str, str]) -> list[dict]:
    return [
        {"id": i, "where": "a:1", "finding": "x", "call": c, "owner": o, "why": "y"}
        for i, c, o in rows
    ]


def test_log_problems_clean() -> None:
    """A complete decision log raises nothing."""
    rows = _log(
        ("F-001", "fix", "wsl"),
        ("FU-001", "decline", "wsl"),
        ("R-001", "escalate", "wsl"),
        ("R-001", "answered", "wsl"),
    )
    rows[-1]["why"] = "leave: not worth it"
    assert review.log_problems(rows, ["F-001", "R-001"], STATE, SHARDS) == []


@pytest.mark.parametrize(
    ("rows", "ids", "needle"),
    [
        (
            _log(("FU-001", "fix", "wsl")),
            ["F-001"],
            "F-001: finding has no decision row",
        ),
        (_log(("F-001", "fix", "wsl")), ["F-001"], "FU-001: carried-in follow-up"),
        (_log(("FU-001", "escalate", "wsl")), [], "escalation not answered"),
        (_log(("FU-001", "handoff", "nowhere")), [], "handoff needs Owner"),
        (_log(("FU-001", "handoff", "wsl")), [], "handoff to this shard"),
        (_log(("FU-001", "maybe", "wsl")), [], "unknown call 'maybe'"),
        (
            [{**_log(("FU-001", "handoff", "certs"))[0], "where": "wsl/x.ps1:3"}],
            [],
            "wsl/x.ps1:3 is owned by wsl, not certs",
        ),
    ],
)
def test_log_problems_flags(rows: list[dict], ids: list[str], needle: str) -> None:
    """Each gap in the decision log is named."""
    problems = review.log_problems(rows, ids, STATE, SHARDS)
    assert any(needle in p for p in problems), problems


def test_intent_carries_charter_followups_and_declines(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The intent file holds the charter, carried-in rows and declines."""
    charter = tmp_path / "c.md"
    charter.write_text("# Charter body\n")
    monkeypatch.setattr(review, "REPO", tmp_path)
    shard = {"name": "wsl", "charter": "c.md"}
    carried = [{"id": "FU-001", "where": "wsl/x.ps1:3", "finding": "drops the cert"}]
    declines = [{"where": "a:1", "finding": "add a retry.", "why": "cannot happen"}]
    text = review._intent(shard, declines, carried)
    assert "# Charter body" in text
    assert "## Carried in" in text and "FU-001" in text
    assert "## Already decided" in text and "cannot happen" in text


def test_render_history_never_reuses_a_closed_followup_id() -> None:
    """Closing a follow-up never frees its number."""
    # FU-001 appears only in the open table; closing it must not free its number.
    text = HISTORY.replace("FU-001: needs the wsl charter", "needs the wsl charter")
    rows = [
        {
            "id": "FU-001",
            "where": "a:1",
            "finding": "x",
            "call": "fix",
            "owner": "wsl",
            "why": "done",
        },
        {
            "id": "F-001",
            "where": "b:2",
            "finding": "y",
            "call": "handoff",
            "owner": "certs",
            "why": "z",
        },
    ]
    counts = {"found": 1, "fix": 1, "decline": 0, "escalate": 0, "handoff": 1}
    parsed = review.parse_history(review.render_history(text, STATE, rows, counts))
    assert [fu["id"] for fu in parsed["followups"]] == ["FU-002"]


def test_render_history_keeps_two_same_day_runs_of_one_shard() -> None:
    """A second run of a shard on the same day is recorded, not skipped."""
    state = {**STATE, "shard": "certs", "date": "2026-11-01", "carried": []}
    rows = [_row_log("R-001", "decline")]
    counts = review.tally(rows, ["R-001"])
    parsed = review.parse_history(review.render_history(HISTORY, state, rows, counts))
    same_day = [
        x for x in parsed["logs"] if (x["date"], x["shard"]) == ("2026-11-01", "certs")
    ]
    assert len(same_day) == 2
    assert [d["id"] for d in review.earlier_declines(parsed, "certs")] == [
        "R-001",
        "R-001",
    ]


def _row_log(i: str, call: str, why: str = "y") -> dict:
    return {
        "id": i,
        "where": "a:1",
        "finding": "x",
        "call": call,
        "owner": "wsl",
        "why": why,
    }


def test_tally_counts_an_answered_fix_as_a_fix() -> None:
    """An escalation the user answered with fix counts toward tests and the commit."""
    rows = [
        _row_log("R-001", "escalate"),
        _row_log("R-001", "answered", "fix: drop it"),
    ]
    counts = review.tally(rows, ["R-001"])
    assert counts["fix"] == 1 and counts["escalate"] == 1


def test_distinct_causes_merges_rows_sharing_a_why() -> None:
    """Two reviewers' findings with one root cause count once."""
    rows = [
        _row_log("R-001", "fix", "breaks on openSUSE"),
        _row_log("F-004", "fix", "breaks on openSUSE"),
        _row_log("F-009", "fix", "wrong comment"),
        _row_log("F-010", "decline", "cannot happen"),
        _row_log("F-011", "escalate", "drops a block"),
        _row_log("F-011", "answered", "fix: the user wants it dropped"),
    ]
    assert review.distinct_causes(rows) == {
        "fix": 3,
        "decline": 1,
        "resolve-only": 0,
        "handoff": 0,
        "escalate": 1,
    }


def test_resolve_only_closes_without_becoming_a_decline() -> None:
    """A carried-in row that no longer applies closes and is not suppressed later."""
    rows = [_row_log("FU-001", "resolve-only")]
    assert review.log_problems(rows, [], STATE, SHARDS) == []
    counts = review.tally(rows, [])
    parsed = review.parse_history(review.render_history(HISTORY, STATE, rows, counts))
    assert parsed["followups"] == []
    assert review.earlier_declines(parsed, "wsl") == []


def test_log_problems_rejects_duplicate_decisions() -> None:
    """One finding gets exactly one decision."""
    rows = [
        _row_log("F-001", "fix"),
        _row_log("F-001", "decline"),
        _row_log("FU-001", "fix"),
    ]
    problems = review.log_problems(rows, ["F-001"], STATE, SHARDS)
    assert any("F-001: 2 decision rows" in p for p in problems), problems


def test_read_reports_requires_both(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A missing or malformed report stops finish; it is not zero findings."""
    monkeypatch.setattr(review, "REPO", tmp_path)
    findings = tmp_path / "f"
    findings.mkdir()
    with pytest.raises(review.ReviewError, match="reviewer.json is missing"):
        review.read_reports(findings)
    (findings / "reviewer.json").write_text('{"findings": [{"id": "R-001"}]}')
    (findings / "second-opinion.json").write_text("[]")
    with pytest.raises(review.ReviewError, match="not a findings report"):
        review.read_reports(findings)
    (findings / "second-opinion.json").write_text('{"skipped": "x", "findings": []}')
    assert review.finding_ids(review.read_reports(findings)) == ["R-001"]


def test_a_declined_escalation_is_carried_forward() -> None:
    """The user's no reaches the next review of the shard, with their reason."""
    state = {**STATE, "shard": "certs", "carried": []}
    rows = [
        {**_row_log("R-001", "escalate"), "where": "c:1", "finding": "drop blocks"},
        _row_log("R-001", "answered", "decline: users rely on them"),
        {**_row_log("R-002", "escalate"), "where": "c:2", "finding": "retry"},
        _row_log("R-002", "answered", "fix: add it"),
    ]
    text = review.render_history(HISTORY, state, rows, review.tally(rows, []))
    declines = review.earlier_declines(review.parse_history(text), "certs")
    carried = [d for d in declines if d["where"] == "c:1"]
    assert [d["why"] for d in carried] == ["decline: users rely on them"]
    assert not any(d["where"] == "c:2" for d in declines)


def test_an_answer_must_start_with_its_outcome() -> None:
    """A copied option label is refused; the outcome prefix is what finish acts on."""
    rows = [
        _row_log("FU-001", "escalate"),
        _row_log("FU-001", "answered", "Drop the static blocks (Recommended)"),
    ]
    problems = review.log_problems(rows, [], STATE, SHARDS)
    assert any("starts with fix:, decline:, leave:" in p for p in problems), problems


def test_second_opinion_passes_the_caller_and_keeps_usage(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """--files takes every argument after it, so --caller goes first; usage is kept."""
    import json

    brief = tmp_path / "review_brief.py"
    brief.touch()
    (tmp_path / review.FINDINGS_DIR).mkdir(parents=True)
    monkeypatch.setattr(review, "REPO", tmp_path)
    monkeypatch.setattr(review, "BRIEF_SCRIPT", brief)
    monkeypatch.setattr(review, "load_state", lambda: {"shard": "lib"})
    monkeypatch.setattr(review, "load_manifest", lambda: MANIFEST)
    monkeypatch.setattr(review, "owned_files", lambda *_a: ["a.sh", "b.sh"])
    monkeypatch.setattr(review, "tracked_files", lambda: [])
    monkeypatch.setattr(review, "git", lambda *_a, **_k: "base")
    seen: dict = {}
    report = {"model": "m", "usage": {"credits": 9.0}, "findings": [], "diffstat": "x"}

    def run(cmd: list[str], **_k: object) -> review.subprocess.CompletedProcess[str]:
        seen["cmd"] = cmd
        return review.subprocess.CompletedProcess(cmd, 0, json.dumps(report), "")

    monkeypatch.setattr(review.subprocess, "run", run)
    args = review.build_parser().parse_args(
        ["second-opinion", "--caller", "claude-opus-5-5"]
    )

    assert review.cmd_second_opinion(args) == review.EXIT_OK
    cmd = seen["cmd"]
    assert cmd[cmd.index("--caller") + 1] == "claude-opus-5-5"
    assert cmd[cmd.index("--files") :] == ["--files", "a.sh", "b.sh"]
    out = tmp_path / review.FINDINGS_DIR / "second-opinion.json"
    saved = json.loads(out.read_text())
    assert saved["usage"] == {"credits": 9.0} and "diffstat" not in saved
