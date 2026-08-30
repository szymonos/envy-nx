"""
Unit tests for the address-pr-review driver's pure logic.

Network-free: every test drives the thread-filtering and state-classification
helpers directly, monkeypatching the two functions that talk to GitHub
(`_fetch_all_threads`, `_repo_info`/`_auto_pr`).

The centre of gravity is the fresh-vs-all distinction. `state` filters threads
to the ones describing the current diff, which is right for triage and wrong
for deciding a PR is done; `unresolved` is the completeness check. Getting
those two confused shipped a release with two open threads on PR #74.

# :example
uv run pytest tests/skills/test_pr_review_pure.py -q
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

# pr_review.py lives under the skill, not on the package path - load it directly.
_PR_REVIEW = (
    Path(__file__).resolve().parents[2]
    / ".claude/skills/address-pr-review/scripts/pr_review.py"
)
_spec = importlib.util.spec_from_file_location("pr_review", _PR_REVIEW)
assert _spec and _spec.loader
pr_review = importlib.util.module_from_spec(_spec)
sys.modules["pr_review"] = pr_review
_spec.loader.exec_module(pr_review)


def _thread(
    tid: str,
    *,
    resolved: bool,
    outdated: bool,
    path: str = "a.sh",
    body: str | None = None,
) -> dict:
    """A GraphQL thread node shaped the way _fetch_all_threads returns them."""
    return {
        "id": tid,
        "isResolved": resolved,
        "isOutdated": outdated,
        "comments": {
            "nodes": [
                {
                    "path": path,
                    "line": 1,
                    "originalLine": 1,
                    "author": {"login": "copilot-pull-request-reviewer"},
                    "body": body if body is not None else f"finding on {path}",
                }
            ]
        },
    }


# -- _flatten_thread ------------------------------------------------------------


def test_flatten_thread_exposes_the_fields_triage_needs() -> None:
    """The agent triages off this dict, so id/path/body must survive flattening."""
    flat = pr_review._flatten_thread(
        _thread("PRRT_1", resolved=False, outdated=True, path="nix/setup.sh")
    )

    assert flat["id"] == "PRRT_1"
    assert flat["path"] == "nix/setup.sh"
    assert flat["isOutdated"] is True
    assert flat["author"] == "copilot-pull-request-reviewer"
    assert "finding on nix/setup.sh" in flat["body"]


def test_flatten_thread_falls_back_to_original_line() -> None:
    """
    An outdated thread has `line: null` - the anchor moved.

    Without the originalLine fallback the triage output says `path:None`, which
    is exactly the case most in need of a locator.
    """
    node = _thread("PRRT_2", resolved=False, outdated=True)
    node["comments"]["nodes"][0]["line"] = None
    node["comments"]["nodes"][0]["originalLine"] = 42

    assert pr_review._flatten_thread(node)["line"] == 42


def test_flatten_thread_survives_a_thread_with_no_comments() -> None:
    """A thread whose comments were deleted must not crash the whole triage run."""
    flat = pr_review._flatten_thread(
        {
            "id": "PRRT_3",
            "isResolved": False,
            "isOutdated": False,
            "comments": {"nodes": []},
        }
    )

    assert flat["id"] == "PRRT_3"
    assert flat["path"] == ""


# -- state exit codes -----------------------------------------------------------


@pytest.mark.parametrize(("state", "code"), [("D", 0), ("C", 1), ("B", 2), ("A", 3)])
def test_state_exit_code_mapping(state: str, code: int) -> None:
    """Callers branch on the exit code, so the mapping is a contract."""
    assert pr_review._state_exit_code(state) == code


# -- cmd_unresolved: the completeness check --------------------------------------


def _run_unresolved(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    threads: list[dict],
) -> tuple[int, dict]:
    """Drive cmd_unresolved against a fixed thread set, returning (rc, payload)."""
    monkeypatch.setattr(pr_review, "_repo_info", lambda: ("szymonos", "envy-nx"))
    monkeypatch.setattr(pr_review, "_fetch_all_threads", lambda o, r, p: threads)
    rc = pr_review.cmd_unresolved(argparse.Namespace(pr=74))
    return rc, json.loads(capsys.readouterr().out)


def test_unresolved_includes_outdated_threads(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """
    The whole point of the verb: `state` cannot see these.

    A force-push moves the head SHA and flips every existing thread to
    isOutdated, dropping it from unresolvedFreshThreads - so an unactioned
    comment goes invisible precisely when the agent decides it is finished.
    """
    rc, out = _run_unresolved(
        monkeypatch,
        capsys,
        [_thread("PRRT_old", resolved=False, outdated=True)],
    )

    assert rc == 1, "must exit non-zero so it can gate a release finish"
    assert out["unresolved"] == 1
    assert out["threads"][0]["id"] == "PRRT_old"


def test_unresolved_excludes_resolved_threads_however_stale(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Resolved is the only thing that closes a thread; outdated is not."""
    rc, out = _run_unresolved(
        monkeypatch,
        capsys,
        [
            _thread("PRRT_done_fresh", resolved=True, outdated=False),
            _thread("PRRT_done_old", resolved=True, outdated=True),
        ],
    )

    assert rc == 0
    assert out["unresolved"] == 0


def test_unresolved_is_a_superset_of_the_fresh_filter(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """
    Everything `state` would report must also appear here.

    The two filters are allowed to differ in one direction only - if `state`
    ever surfaced a thread `unresolved` did not, the gate would be unsound.
    """
    threads = [
        _thread("PRRT_fresh", resolved=False, outdated=False),
        _thread("PRRT_old", resolved=False, outdated=True),
        _thread("PRRT_done", resolved=True, outdated=False),
    ]
    fresh = {t["id"] for t in threads if not t["isResolved"] and not t["isOutdated"]}

    _, out = _run_unresolved(monkeypatch, capsys, threads)
    reported = {t["id"] for t in out["threads"]}

    assert fresh <= reported
    assert reported == {"PRRT_fresh", "PRRT_old"}


def test_unresolved_reports_the_pr_it_checked(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The PR number is echoed so a wrong auto-detect is visible in the output."""
    _, out = _run_unresolved(monkeypatch, capsys, [])

    assert out["pr"] == 74


# -- _copilot_requested: the A-vs-B discriminator --------------------------------


def _request(login: str) -> dict:
    """One GraphQL `reviewRequests` node."""
    return {"requestedReviewer": {"login": login}}


def test_a_pending_copilot_request_is_detected() -> None:
    """
    Copilot is a Bot, and only GraphQL `reviewRequests` reports it.

    The REST endpoint returns empty `users`/`teams` for a genuinely pending
    Copilot request, which makes state B unreachable.
    """
    login = next(iter(pr_review.COPILOT_REQUESTED_LOGINS))

    assert (
        pr_review._copilot_requested({"reviewRequests": {"nodes": [_request(login)]}})
        is True
    )


def test_request_matching_is_case_insensitive() -> None:
    """GitHub logins vary in case between API surfaces."""
    login = next(iter(pr_review.COPILOT_REQUESTED_LOGINS)).upper()

    assert (
        pr_review._copilot_requested({"reviewRequests": {"nodes": [_request(login)]}})
        is True
    )


def test_a_human_reviewer_is_not_copilot() -> None:
    """Requesting a colleague must not read as "Copilot is already working"."""
    assert (
        pr_review._copilot_requested(
            {"reviewRequests": {"nodes": [_request("a-human")]}}
        )
        is False
    )


@pytest.mark.parametrize(
    "node",
    [
        {},
        {"reviewRequests": None},
        {"reviewRequests": {"nodes": []}},
        {"reviewRequests": {"nodes": [{"requestedReviewer": None}]}},
    ],
)
def test_missing_request_data_is_not_a_request(node: dict) -> None:
    """
    GraphQL omits or nulls these fields routinely.

    Raising here would abort the whole review loop on a well-formed response.
    """
    assert pr_review._copilot_requested(node) is False


# -- _detect_state: A/B/C/D classification ---------------------------------------

HEAD = "abc123"


def _review(sha: str | None, *, login: str | None = None, at: str = "") -> dict:
    """One `reviews` node, optionally against a commit."""
    who = pr_review.COPILOT_REVIEWER_LOGIN if login is None else login
    return {
        "author": {"login": who},
        "commit": None if sha is None else {"oid": sha},
        "submittedAt": at,
    }


def _state_response(
    reviews: list[dict] | None = None, requests: list[dict] | None = None
) -> dict:
    """A `STATE_QUERY` payload for a PR sitting at HEAD."""
    return {
        "data": {
            "repository": {
                "pullRequest": {
                    "headRefOid": HEAD,
                    "reviews": {"nodes": reviews or []},
                    "reviewRequests": {"nodes": requests or []},
                }
            }
        }
    }


def _threads_response(nodes: list[dict], *, next_cursor: str | None = None) -> dict:
    """A `THREADS_PAGE_QUERY` payload, optionally with another page to come."""
    return {
        "data": {
            "repository": {
                "pullRequest": {
                    "reviewThreads": {
                        "nodes": nodes,
                        "pageInfo": {
                            "hasNextPage": next_cursor is not None,
                            "endCursor": next_cursor,
                        },
                    }
                }
            }
        }
    }


def _stub_graphql(monkeypatch: pytest.MonkeyPatch, *responses: dict) -> list[dict]:
    """Serve *responses* in order (repeating the last); return the calls made."""
    calls: list[dict] = []
    queue = list(responses)

    def fake(query: str, **variables: object) -> dict:
        calls.append({"query": query, **variables})
        return queue.pop(0) if len(queue) > 1 else queue[0]

    monkeypatch.setattr(pr_review, "_graphql", fake)
    return calls


def test_state_a_when_nothing_is_requested_or_reviewed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A fresh PR has no Copilot review and no pending request: trigger one."""
    _stub_graphql(monkeypatch, _state_response())

    assert pr_review._detect_state("o", "r", 1)["state"] == "A"


def test_state_b_when_a_review_is_queued(monkeypatch: pytest.MonkeyPatch) -> None:
    """
    A queued request is the difference between waiting and re-triggering.

    Getting this wrong makes the skill request a second review on every poll.
    """
    login = next(iter(pr_review.COPILOT_REQUESTED_LOGINS))
    _stub_graphql(monkeypatch, _state_response(requests=[_request(login)]))

    result = pr_review._detect_state("o", "r", 1)

    assert (result["state"], result["copilotRequested"]) == ("B", True)


def test_state_c_when_a_fresh_review_has_open_threads(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Unresolved, not-outdated threads on the current HEAD are the work to do."""
    _stub_graphql(
        monkeypatch,
        _state_response(reviews=[_review(HEAD)]),
        _threads_response(
            [_thread("PRRT_1", resolved=False, outdated=False, body="open")]
        ),
    )

    result = pr_review._detect_state("o", "r", 1)

    assert result["state"] == "C"
    assert [t["body"] for t in result["unresolvedFreshThreads"]] == ["open"]


@pytest.mark.parametrize(
    "settled",
    [
        _thread("PRRT_done", resolved=True, outdated=False),
        _thread("PRRT_old", resolved=False, outdated=True),
    ],
)
def test_state_d_when_no_thread_is_left_to_triage(
    monkeypatch: pytest.MonkeyPatch, settled: dict
) -> None:
    """
    D is the triage-clean exit: neither a resolved nor an outdated thread is work.

    This is deliberately *not* "nothing is open" - an outdated thread is still
    unresolved on the PR, and `unresolved` is the check that sees it.
    """
    _stub_graphql(
        monkeypatch,
        _state_response(reviews=[_review(HEAD)]),
        _threads_response([settled]),
    )

    result = pr_review._detect_state("o", "r", 1)

    assert result["state"] == "D"
    assert result["unresolvedFreshThreads"] == []


def test_a_review_against_an_older_commit_is_not_fresh(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Freshness is by commit SHA, not by existence.

    Accepting a stale review would declare the PR clean while the newest push
    is unreviewed.
    """
    _stub_graphql(monkeypatch, _state_response(reviews=[_review("older")]))

    result = pr_review._detect_state("o", "r", 1)

    assert (result["state"], result["freshReviewSha"]) == ("A", None)


@pytest.mark.parametrize(
    "node",
    [
        {"author": None, "commit": {"oid": HEAD}, "submittedAt": ""},
        {"author": {"login": "a-human"}, "commit": {"oid": HEAD}, "submittedAt": ""},
        {"author": {"login": pr_review.COPILOT_REVIEWER_LOGIN}, "commit": None},
    ],
)
def test_reviews_that_are_not_a_fresh_copilot_review_are_ignored(
    monkeypatch: pytest.MonkeyPatch, node: dict
) -> None:
    """A deleted author, a human review and a null commit must not raise."""
    _stub_graphql(monkeypatch, _state_response(reviews=[node]))

    assert pr_review._detect_state("o", "r", 1)["state"] == "A"


def test_the_newest_copilot_review_wins(monkeypatch: pytest.MonkeyPatch) -> None:
    """Copilot reviews the same PR repeatedly; only the latest one is current."""
    _stub_graphql(
        monkeypatch,
        _state_response(
            reviews=[_review("old", at="2024-01-01"), _review(HEAD, at="2024-06-01")]
        ),
        _threads_response([]),
    )

    assert pr_review._detect_state("o", "r", 1)["freshReviewSha"] == HEAD


def test_threads_are_not_fetched_without_a_fresh_review(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Skipping the paginated fetch in A/B is what keeps `wait` off the rate limit.

    Each poll would otherwise walk every review thread on the PR.
    """
    calls = _stub_graphql(monkeypatch, _state_response())
    pr_review._detect_state("o", "r", 1)

    assert len(calls) == 1


def test_threads_are_paginated_to_the_end(monkeypatch: pytest.MonkeyPatch) -> None:
    """
    A `first: N` cap would silently drop findings past the first page.

    Both pages have to end up in the result.
    """
    queue = [
        _state_response(reviews=[_review(HEAD)]),
        _threads_response(
            [_thread("PRRT_p1", resolved=False, outdated=False, body="page one")],
            next_cursor="CUR",
        ),
        _threads_response(
            [_thread("PRRT_p2", resolved=False, outdated=False, body="page two")]
        ),
    ]
    calls: list[dict] = []
    monkeypatch.setattr(
        pr_review,
        "_graphql",
        lambda _q, **variables: (calls.append(variables), queue.pop(0))[1],
    )

    result = pr_review._detect_state("o", "r", 1)

    assert [t["body"] for t in result["unresolvedFreshThreads"]] == [
        "page one",
        "page two",
    ]
    assert calls[-1]["cursor"] == "CUR"


@pytest.mark.parametrize(
    "response",
    [
        {"data": {"repository": {"pullRequest": None}}},
        {"data": {"repository": None}},
        {"data": None},
    ],
)
def test_an_unknown_pr_exits_rather_than_crashing(
    monkeypatch: pytest.MonkeyPatch, response: dict, capsys: pytest.CaptureFixture[str]
) -> None:
    """A bad `--pr` is a user error; a TypeError traceback would hide that."""
    _stub_graphql(monkeypatch, response)

    with pytest.raises(SystemExit) as exit_info:
        pr_review._detect_state("o", "r", 99)

    assert exit_info.value.code == 1
    assert "not found" in capsys.readouterr().err


def test_fetching_threads_from_an_unknown_pr_exits_the_same_way(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """
    `unresolved` reaches the thread fetch without `_detect_state` vetting the PR.

    `state` validates the node before ever paginating, so the blind indexing in
    `_fetch_all_threads` was unreachable until a second caller arrived. Both
    entry points have to fail the same readable way.
    """
    monkeypatch.setattr(pr_review, "_repo_info", lambda: ("o", "r"))
    monkeypatch.setattr(
        pr_review, "_graphql", lambda *_a, **_k: {"data": {"repository": None}}
    )

    with pytest.raises(SystemExit) as exit_info:
        pr_review.main(["unresolved", "--pr", "99"])

    assert exit_info.value.code == 1
    assert "not found" in capsys.readouterr().err


# -- gh invocation ---------------------------------------------------------------


def _stub_run(
    monkeypatch: pytest.MonkeyPatch, stdout: str, code: int = 0, stderr: str = ""
) -> None:
    """Stand in for `subprocess.run`."""

    def fake(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess([], code, stdout, stderr)

    monkeypatch.setattr(pr_review.subprocess, "run", fake)


def _stub_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    """Simulate a `gh` call that blocks past GH_TIMEOUT, asserting it was bounded."""

    def boom(*_args: object, **kwargs: object) -> None:
        assert kwargs.get("timeout") == pr_review.GH_TIMEOUT
        raise subprocess.TimeoutExpired(cmd="gh", timeout=pr_review.GH_TIMEOUT)

    monkeypatch.setattr(pr_review.subprocess, "run", boom)


def test_a_failing_gh_command_exits_with_a_readable_message(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """
    A traceback for "not logged in" is noise the skill cannot act on.

    The stderr detail is what tells the user what to fix.
    """
    _stub_run(monkeypatch, "", code=1, stderr="gh: not authenticated")

    with pytest.raises(SystemExit) as exit_info:
        pr_review._run_gh(["gh", "repo", "view"])

    assert exit_info.value.code == 1
    assert "not authenticated" in capsys.readouterr().err


@pytest.mark.parametrize("call", ["_run_gh", "_auto_pr"])
def test_a_missing_gh_binary_is_reported(
    monkeypatch: pytest.MonkeyPatch, call: str, capsys: pytest.CaptureFixture[str]
) -> None:
    """Both entry points into `gh` have to say the same thing when it is absent."""

    def boom(*_args: object, **_kwargs: object) -> None:
        raise FileNotFoundError("gh")

    monkeypatch.setattr(pr_review.subprocess, "run", boom)
    invoke = {
        "_run_gh": lambda: pr_review._run_gh(["gh"]),
        "_auto_pr": pr_review._auto_pr,
    }[call]

    with pytest.raises(SystemExit):
        invoke()

    assert "gh CLI not found" in capsys.readouterr().err


@pytest.mark.parametrize("call", ["_run_gh", "_auto_pr"])
def test_a_hanging_gh_call_is_cut_off(
    monkeypatch: pytest.MonkeyPatch, call: str, capsys: pytest.CaptureFixture[str]
) -> None:
    """
    `wait` polls, so a single call that blocks would overrun its own deadline.

    `_auto_pr` is included because omitting `--pr` is the normal path: an
    unbounded call there stalls `state`/`trigger`/`wait` alike while the rest
    of the script looks well-behaved.
    """
    _stub_timeout(monkeypatch)
    invoke = {
        "_run_gh": lambda: pr_review._run_gh(["gh", "api", "graphql"]),
        "_auto_pr": pr_review._auto_pr,
    }[call]

    with pytest.raises(SystemExit) as exit_info:
        invoke()

    assert exit_info.value.code == 1
    assert "timed out" in capsys.readouterr().err


def test_repo_info_is_read_from_gh(monkeypatch: pytest.MonkeyPatch) -> None:
    """Owner and name feed every GraphQL call."""
    _stub_run(
        monkeypatch, json.dumps({"owner": {"login": "szymonos"}, "name": "envy-nx"})
    )

    assert pr_review._repo_info() == ("szymonos", "envy-nx")


def test_auto_pr_reads_the_current_branch(monkeypatch: pytest.MonkeyPatch) -> None:
    """Omitting `--pr` is the normal path, so detection has to work."""
    _stub_run(monkeypatch, "71\n")

    assert pr_review._auto_pr() == 71


@pytest.mark.parametrize(("stdout", "code"), [("", 0), ("", 1)])
def test_auto_pr_without_an_open_pr_exits(
    monkeypatch: pytest.MonkeyPatch,
    stdout: str,
    code: int,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Guessing a PR number would resolve threads on somebody else's review."""
    _stub_run(monkeypatch, stdout, code)

    with pytest.raises(SystemExit):
        pr_review._auto_pr()

    assert "No open PR" in capsys.readouterr().err


def test_a_non_numeric_pr_number_is_reported_not_raised(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A ValueError traceback would undo every other guard in this function."""
    _stub_run(monkeypatch, "not-a-number")

    with pytest.raises(SystemExit) as exit_info:
        pr_review._auto_pr()

    assert exit_info.value.code == 1
    assert "could not read a PR number" in capsys.readouterr().err


def test_graphql_passes_integers_with_the_numeric_flag(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    `gh api -f` sends everything as a string, and `pr` is declared `Int!`.

    Using `-f` for the PR number makes every query fail type validation.
    """
    seen: list[str] = []
    monkeypatch.setattr(pr_review, "_run_gh", lambda cmd: seen.extend(cmd) or "{}")

    pr_review._graphql("query", owner="o", pr=7)

    assert seen[seen.index("-F") + 1] == "pr=7"
    assert seen[seen.index("-f", seen.index("query=query")) + 1] == "owner=o"


# -- subcommand dispatch ---------------------------------------------------------


def _stub_state(monkeypatch: pytest.MonkeyPatch, *states: dict) -> None:
    """Serve prepared `_detect_state` results (repeating the last), and pin the repo."""
    queue = list(states)
    monkeypatch.setattr(pr_review, "_repo_info", lambda: ("o", "r"))
    monkeypatch.setattr(
        pr_review,
        "_detect_state",
        lambda *_: queue.pop(0) if len(queue) > 1 else queue[0],
    )


def _result(state: str) -> dict:
    """A minimal `_detect_state` return value."""
    return {
        "state": state,
        "headSha": HEAD,
        "freshReviewSha": HEAD,
        "copilotRequested": False,
        "unresolvedFreshThreads": [],
    }


def test_state_command_prints_json_and_exits_with_the_state(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The skill reads both the code and the payload."""
    _stub_state(monkeypatch, _result("C"))

    assert pr_review.main(["state", "--pr", "1"]) == 1
    assert json.loads(capsys.readouterr().out)["state"] == "C"


def test_a_command_without_a_pr_falls_back_to_auto_detection(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """`--pr` is optional precisely so the skill can run with no arguments."""
    _stub_state(monkeypatch, _result("D"))
    monkeypatch.setattr(pr_review, "_auto_pr", lambda: 42)

    assert pr_review.main(["state"]) == 0
    assert json.loads(capsys.readouterr().out)["state"] == "D"


def test_unresolved_falls_back_to_auto_detection(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The finish step runs with no arguments, so this path has to work too."""
    monkeypatch.setattr(pr_review, "_repo_info", lambda: ("o", "r"))
    monkeypatch.setattr(pr_review, "_fetch_all_threads", lambda *_: [])
    monkeypatch.setattr(pr_review, "_auto_pr", lambda: 42)

    assert pr_review.main(["unresolved"]) == 0
    assert json.loads(capsys.readouterr().out)["pr"] == 42


def test_unresolved_includes_human_threads(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A check that skipped humans would miss the comments that matter most."""
    human = _thread("PRRT_h", resolved=False, outdated=False)
    human["comments"]["nodes"][0]["author"] = {"login": "a-human"}
    monkeypatch.setattr(pr_review, "_repo_info", lambda: ("o", "r"))
    monkeypatch.setattr(pr_review, "_fetch_all_threads", lambda *_: [human])

    assert pr_review.main(["unresolved", "--pr", "1"]) == 1
    assert json.loads(capsys.readouterr().out)["threads"][0]["author"] == "a-human"


def test_trigger_adds_copilot_as_a_reviewer(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The command must name Copilot, not just any reviewer."""
    seen: list[str] = []
    monkeypatch.setattr(pr_review, "_run_gh", lambda cmd: seen.extend(cmd) or "")

    assert pr_review.main(["trigger", "--pr", "5"]) == 0
    assert pr_review.COPILOT_REVIEWER_LOGIN in seen
    assert json.loads(capsys.readouterr().out) == {"triggered": True, "pr": 5}


def test_wait_returns_as_soon_as_the_review_lands(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Polling past a settled state wastes the whole timeout budget."""
    _stub_state(monkeypatch, _result("B"), _result("C"))
    monkeypatch.setattr(pr_review.time, "sleep", lambda _: None)

    assert (
        pr_review.main(["wait", "--pr", "1", "--interval", "0", "--timeout", "60"]) == 1
    )
    assert json.loads(capsys.readouterr().out)["state"] == "C"


def test_wait_exits_four_on_timeout(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """
    A distinct code is what lets the skill say "still queued" rather than "clean".

    The last-known state is still printed so the caller can decide.
    """
    _stub_state(monkeypatch, _result("B"))
    monkeypatch.setattr(pr_review.time, "sleep", lambda _: None)

    assert (
        pr_review.main(["wait", "--pr", "1", "--interval", "0", "--timeout", "0"]) == 4
    )
    assert json.loads(capsys.readouterr().out)["state"] == "B"


@pytest.mark.parametrize(("resolved", "code"), [(True, 0), (False, 1)])
def test_resolve_reports_whether_the_thread_closed(
    monkeypatch: pytest.MonkeyPatch,
    resolved: bool,
    code: int,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A thread GitHub declined to resolve must not be reported as done."""
    monkeypatch.setattr(
        pr_review,
        "_graphql",
        lambda *_a, **_k: {
            "data": {"resolveReviewThread": {"thread": {"isResolved": resolved}}}
        },
    )

    assert pr_review.main(["resolve", "PRRT_x"]) == code
    assert json.loads(capsys.readouterr().out) == {"resolved": resolved}
