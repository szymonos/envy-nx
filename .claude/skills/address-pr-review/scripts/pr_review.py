#!/usr/bin/env -S uv run python3
"""
pr_review.py - state-aware GitHub PR review thread management.

Shared by the /address-pr-review and /prepare-pr skills, which each vendor a
copy. Handles Copilot review lifecycle: detect current state, trigger reviews,
wait for completion, and resolve threads via GraphQL.

Review states
-------------
A = no fresh Copilot review exists, none requested  -> trigger + wait
B = no fresh Copilot review exists, one is queued   -> wait
C = fresh Copilot review exists, unresolved threads -> process them
D = fresh Copilot review exists, no unresolved      -> DONE (only clean-exit)

"Fresh" means a review whose commit SHA matches the PR's current HEAD SHA.
"In progress" means Copilot sits in the PR's pending review requests.

States C and D are about *triage*: they count only threads that still describe
the current code, so D means "nothing left to triage", not "nothing left open".
Finishing is a different question, and `unresolved` is what answers it.

Subcommands
-----------
state --pr N
    Detect the current state. Prints JSON; exit code = state-specific:
      0 = D (triage-clean), 1 = C (threads to triage), 2 = B (in progress),
      3 = A (none). Exit 0 here is not "nothing is open" - see `unresolved`.

unresolved --pr N
    List every unresolved thread, outdated or not. Exit 1 while any remain.
    The finish-time completeness check; see `cmd_unresolved`.

trigger --pr N
    Request Copilot review (gh pr edit --add-reviewer). Idempotent.

wait --pr N [--interval 30] [--timeout 480]
    Poll until state resolves to C or D. Same JSON shape as `state`.
    Exit 1 = C, 0 = D, 4 = timeout.

resolve <thread-id>
    Resolve a single review thread via GraphQL.

# :example
.claude/skills/address-pr-review/scripts/pr_review.py state --pr 37
.claude/skills/address-pr-review/scripts/pr_review.py unresolved --pr 37
.claude/skills/address-pr-review/scripts/pr_review.py trigger --pr 37
.claude/skills/address-pr-review/scripts/pr_review.py wait --pr 37 --timeout 480
.claude/skills/address-pr-review/scripts/pr_review.py resolve PRRT_xxx
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from collections.abc import Sequence

COPILOT_REVIEWER_LOGIN = "copilot-pull-request-reviewer"  # author of submitted reviews
# Logins a pending Copilot request can carry. It is a Bot named
# `copilot-pull-request-reviewer`; older payloads exposed it as a user "Copilot".
# Compared case-insensitively.
COPILOT_REQUESTED_LOGINS = frozenset({COPILOT_REVIEWER_LOGIN, "copilot"})

#: Ceiling for a single `gh` invocation. Generous, because a GraphQL page over
#: a large PR is not instant, but finite so `wait` cannot overrun its deadline.
GH_TIMEOUT = 120

STATE_QUERY = """
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      headRefOid
      reviews(last: 50) {
        nodes {
          author { login }
          submittedAt
          commit { oid }
        }
      }
      reviewRequests(first: 50) {
        nodes {
          requestedReviewer {
            __typename
            ... on User { login }
            ... on Bot { login }
          }
        }
      }
    }
  }
}
"""

THREADS_PAGE_QUERY = """
query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { endCursor hasNextPage }
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 1) {
            nodes {
              body
              path
              line
              originalLine
              author { login }
            }
          }
        }
      }
    }
  }
}
"""

RESOLVE_MUTATION = """
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}
"""


def _run_gh(cmd: list[str]) -> str:
    """
    Run a gh command, returning stdout. Exit with a concise message on failure.

    Using check=True here would raise CalledProcessError and dump a Python
    traceback on common, expected failures (gh not installed, not logged in,
    missing scopes). Surface a readable one-line error the calling skill can
    show the user instead.

    The timeout matters because `wait` polls: a single `gh` call that blocks on
    a network stall or an auth prompt would otherwise hang the whole pipeline
    past its own deadline, with nothing on stderr to act on.
    """
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=GH_TIMEOUT)
    except FileNotFoundError:
        print("gh CLI not found on PATH. Install and authenticate gh.", file=sys.stderr)
        raise SystemExit(1) from None
    except subprocess.TimeoutExpired:
        print(
            f"gh command timed out after {GH_TIMEOUT}s: {' '.join(cmd[:3])} ...",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown error"
        print(f"gh command failed ({' '.join(cmd[:3])} ...): {detail}", file=sys.stderr)
        raise SystemExit(1)
    return result.stdout


def _repo_info() -> tuple[str, str]:
    """Return (owner, repo_name) from gh."""
    data = json.loads(_run_gh(["gh", "repo", "view", "--json", "owner,name"]))
    return data["owner"]["login"], data["name"]


def _auto_pr() -> int:
    """
    Auto-detect PR number from current branch.

    Bounded by the same timeout as every other `gh` call: omitting `--pr` is
    the normal path, so an unbounded call here would hang `state`, `trigger`
    and `wait` alike while the rest of the script looked well-behaved.
    """
    try:
        result = subprocess.run(
            ["gh", "pr", "view", "--json", "number", "--jq", ".number"],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT,
        )
    except FileNotFoundError:
        print("gh CLI not found on PATH. Install and authenticate gh.", file=sys.stderr)
        raise SystemExit(1) from None
    except subprocess.TimeoutExpired:
        print(f"gh pr view timed out after {GH_TIMEOUT}s.", file=sys.stderr)
        raise SystemExit(1) from None
    if result.returncode != 0 or not result.stdout.strip():
        print("No open PR on this branch. Push first or specify --pr.", file=sys.stderr)
        raise SystemExit(1)
    try:
        return int(result.stdout.strip())
    except ValueError:
        # Anything non-numeric here is gh printing something unexpected. A
        # ValueError traceback would undo the point of every other branch in
        # this function.
        print(
            f"could not read a PR number from gh: {result.stdout.strip()[:200]}",
            file=sys.stderr,
        )
        raise SystemExit(1) from None


def _graphql(query: str, **variables: str | int) -> dict:
    """Run a GraphQL query via gh api."""
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in variables.items():
        flag = "-F" if isinstance(v, int) else "-f"
        cmd.extend([flag, f"{k}={v}"])
    return json.loads(_run_gh(cmd))


def _copilot_requested(pr_node: dict) -> bool:
    """
    Check whether Copilot sits in the PR's pending review requests.

    Read from the GraphQL `reviewRequests` connection, NOT from REST
    `/pulls/{n}/requested_reviewers`: that endpoint reports only `users` and
    `teams`, and Copilot is a Bot, so a genuinely pending Copilot request
    renders there as `{"users": [], "teams": []}` no matter which login you
    match against. Using it made state detection report A ("nothing requested")
    for a review that was already queued, so state B was unreachable.
    """
    logins = {
        ((node.get("requestedReviewer") or {}).get("login") or "").lower()
        for node in (pr_node.get("reviewRequests") or {}).get("nodes", [])
    }
    return bool(logins & COPILOT_REQUESTED_LOGINS)


def _flatten_thread(thread: dict) -> dict:
    """Flatten a thread node into a simple dict for Claude to consume."""
    comments = thread["comments"]["nodes"]
    first = comments[0] if comments else {}
    return {
        "id": thread["id"],
        "isOutdated": thread["isOutdated"],
        "path": first.get("path", ""),
        "line": first.get("line") or first.get("originalLine"),
        "author": (first.get("author") or {}).get("login", "unknown"),
        "body": first.get("body", ""),
    }


def _pull_request(data: dict, owner: str, repo: str, pr: int) -> dict:
    """
    Pull the `pullRequest` node out of a response, or exit with a readable message.

    Every query here nests under `repository.pullRequest`, and either level can
    come back null on a 200 - an unreadable repo, a number that resolves to
    nothing. Indexing straight through turns that into a TypeError traceback the
    caller cannot act on, which is the one thing `_run_gh` exists to avoid.
    """
    repository = (data.get("data") or {}).get("repository") or {}
    pr_node = repository.get("pullRequest")
    if pr_node is None:
        print(
            f"PR #{pr} not found in {owner}/{repo} (invalid number or no access).",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return pr_node


def _fetch_all_threads(owner: str, repo: str, pr: int) -> list[dict]:
    """Fetch all review threads via cursor pagination (no first:N cap)."""
    all_threads: list[dict] = []
    cursor: str | None = None
    while True:
        kwargs: dict[str, str | int] = {"owner": owner, "repo": repo, "pr": pr}
        if cursor is not None:
            kwargs["cursor"] = cursor
        data = _graphql(THREADS_PAGE_QUERY, **kwargs)
        block = _pull_request(data, owner, repo, pr)["reviewThreads"]
        all_threads.extend(block["nodes"])
        if not block["pageInfo"]["hasNextPage"]:
            break
        cursor = block["pageInfo"]["endCursor"]
    return all_threads


def _detect_state(owner: str, repo: str, pr: int) -> dict:
    """Run state detection. Returns a dict for JSON output + exit-code decisions."""
    data = _graphql(STATE_QUERY, owner=owner, repo=repo, pr=pr)
    pr_node = _pull_request(data, owner, repo, pr)
    head_sha = pr_node["headRefOid"]

    # Find the most-recent Copilot review matching HEAD SHA. GraphQL can return
    # author: null (deleted user) or commit: null (edge cases), so guard both
    # rather than indexing blindly.
    copilot_reviews = [
        r
        for r in pr_node["reviews"]["nodes"]
        if (r.get("author") or {}).get("login") == COPILOT_REVIEWER_LOGIN
    ]
    copilot_reviews.sort(key=lambda r: r.get("submittedAt") or "", reverse=True)
    fresh_review = next(
        (r for r in copilot_reviews if (r.get("commit") or {}).get("oid") == head_sha),
        None,
    )
    fresh_review_sha = (
        (fresh_review.get("commit") or {}).get("oid") if fresh_review else None
    )

    # Reported in every state: once a review is submitted the request is
    # consumed, so this is False in C/D and the flag only classifies A vs B.
    copilot_requested = _copilot_requested(pr_node)

    # Only fetch review threads when a fresh review exists (states C/D). Without
    # one (states A/B), the threads are irrelevant to classification, so skip the
    # paginated fetch - it would add unnecessary GitHub API calls to every `wait`
    # poll and risk rate limits.
    fresh_threads: list[dict] = []
    if fresh_review_sha is not None:
        all_threads = _fetch_all_threads(owner, repo, pr)
        fresh_threads = [
            _flatten_thread(t)
            for t in all_threads
            if not t["isResolved"] and not t["isOutdated"]
        ]
        # Outdated threads are excluded because triage wants comments that still
        # describe the current code. That makes D "nothing left to triage" and
        # NOT "nothing left open" - `unresolved` is the check for the latter,
        # and skipping it is how an unactioned comment reaches a merged PR.
        state = "C" if fresh_threads else "D"
    else:
        state = "B" if copilot_requested else "A"

    return {
        "state": state,
        "headSha": head_sha,
        "freshReviewSha": fresh_review_sha,
        "copilotRequested": copilot_requested,
        "unresolvedFreshThreads": fresh_threads,
    }


def _state_exit_code(state: str) -> int:
    """Map state letter to exit code (D=0, C=1, B=2, A=3)."""
    return {"D": 0, "C": 1, "B": 2, "A": 3}[state]


def cmd_state(args: argparse.Namespace) -> int:
    """Detect and print current review state."""
    pr = args.pr or _auto_pr()
    owner, repo = _repo_info()
    result = _detect_state(owner, repo, pr)
    json.dump(result, sys.stdout, indent=2)
    print()
    return _state_exit_code(result["state"])


def unresolved_threads(owner: str, repo: str, pr: int) -> list[dict]:
    """Every unresolved thread on the PR, outdated ones included."""
    return [
        _flatten_thread(t)
        for t in _fetch_all_threads(owner, repo, pr)
        if not t["isResolved"]
    ]


def cmd_unresolved(args: argparse.Namespace) -> int:
    """
    Print every unresolved thread, outdated or not - the finish-time check.

    `state` reports only threads that are unresolved *and* not outdated, and in
    states A/B it skips the thread fetch entirely so `wait` polling stays cheap.
    Both are right for triage and wrong for finishing, because a force-push
    moves the head SHA and flips every thread anchored to the old diff to
    `isOutdated`. A comment nobody actioned therefore drops out of `state` at
    exactly the moment you are deciding you are done, and state D cannot tell
    "no threads are open" from "the open ones stopped being visible".

    Outdated does not mean settled: it means the diff moved underneath the
    comment. Judge each on its merits, fix or dismiss, then resolve it.

    Exit 1 while any remain, so this can gate a finish step.
    """
    pr = args.pr or _auto_pr()
    owner, repo = _repo_info()
    threads = unresolved_threads(owner, repo, pr)
    payload = {
        "pr": pr,
        "unresolved": len(threads),
        "outdated": sum(1 for t in threads if t["isOutdated"]),
        "threads": threads,
    }
    json.dump(payload, sys.stdout, indent=2)
    print()
    return 1 if threads else 0


def cmd_trigger(args: argparse.Namespace) -> int:
    """Request Copilot review (idempotent)."""
    pr = args.pr or _auto_pr()
    # route through _run_gh for consistent, traceback-free errors (missing gh,
    # auth failure, etc.) - it exits with a concise message on failure
    _run_gh(["gh", "pr", "edit", str(pr), "--add-reviewer", COPILOT_REVIEWER_LOGIN])
    print(json.dumps({"triggered": True, "pr": pr}))
    return 0


def cmd_wait(args: argparse.Namespace) -> int:
    """Poll until state resolves to C or D, or timeout."""
    pr = args.pr or _auto_pr()
    owner, repo = _repo_info()
    deadline = time.monotonic() + args.timeout
    attempt = 0

    while time.monotonic() < deadline:
        attempt += 1
        result = _detect_state(owner, repo, pr)

        if result["state"] in ("C", "D"):
            json.dump(result, sys.stdout, indent=2)
            print()
            return _state_exit_code(result["state"])

        remaining = int(deadline - time.monotonic())
        print(
            f"Poll #{attempt}: state={result['state']} "
            f"(requested={result['copilotRequested']}, {remaining}s remaining)...",
            file=sys.stderr,
        )
        time.sleep(args.interval)

    # Timeout: emit the last-known state and exit 4.
    final = _detect_state(owner, repo, pr)
    json.dump(final, sys.stdout, indent=2)
    print()
    return 4


def cmd_resolve(args: argparse.Namespace) -> int:
    """Resolve a single thread."""
    data = _graphql(RESOLVE_MUTATION, threadId=args.thread_id)
    resolved = data["data"]["resolveReviewThread"]["thread"]["isResolved"]
    json.dump({"resolved": resolved}, sys.stdout)
    print()
    return 0 if resolved else 1


def main(argv: Sequence[str] | None = None) -> int:
    """Parse args, dispatch to state/trigger/wait/resolve."""
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[1])
    sub = parser.add_subparsers(dest="command", required=True)

    p_state = sub.add_parser("state", help="Detect current review state")
    p_state.add_argument("--pr", type=int, help="PR number (auto-detect if omitted)")

    p_unresolved = sub.add_parser(
        "unresolved", help="List ALL unresolved threads (incl. outdated); exit 1 if any"
    )
    p_unresolved.add_argument(
        "--pr", type=int, help="PR number (auto-detect if omitted)"
    )

    p_trigger = sub.add_parser("trigger", help="Request Copilot review")
    p_trigger.add_argument("--pr", type=int, help="PR number (auto-detect if omitted)")

    p_wait = sub.add_parser("wait", help="Poll until state resolves to C or D")
    p_wait.add_argument("--pr", type=int, help="PR number (auto-detect if omitted)")
    p_wait.add_argument(
        "--interval", type=int, default=30, help="Seconds between polls"
    )
    p_wait.add_argument(
        "--timeout", type=int, default=480, help="Total timeout in seconds"
    )

    p_resolve = sub.add_parser("resolve", help="Resolve a review thread")
    p_resolve.add_argument("thread_id", help="GraphQL node ID (PRRT_*)")

    args = parser.parse_args(argv)
    handlers = {
        "state": cmd_state,
        "unresolved": cmd_unresolved,
        "trigger": cmd_trigger,
        "wait": cmd_wait,
        "resolve": cmd_resolve,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
