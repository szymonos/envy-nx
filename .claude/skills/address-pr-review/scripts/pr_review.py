#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "~=3.14.0"
# dependencies = []
# ///
"""
scripts/pr_review.py - state-aware GitHub PR review thread management.

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

resolve <thread-id> [<thread-id> ...]
    Resolve review threads via GraphQL. Exit 1 when any stays unresolved.

reply <thread-id> --body TEXT|-
    Post a reply to a review thread; `-` reads the body from stdin.

api <gh api args...>
    Run `gh api` with the arguments verbatim, retried like every other call.
    For any call no verb above covers; relays gh's output and exit code.

Every thread carries its opening comment and `replies`: the latest
REPLIES_SHOWN replies (with `replyCount` for the total), so an earlier
"won't fix" or a question back to the reviewer is visible without `gh api`.

# :example
.claude/skills/address-pr-review/scripts/pr_review.py state --pr 37
.claude/skills/address-pr-review/scripts/pr_review.py unresolved --pr 37
.claude/skills/address-pr-review/scripts/pr_review.py trigger --pr 37
.claude/skills/address-pr-review/scripts/pr_review.py wait --pr 37 --timeout 480
.claude/skills/address-pr-review/scripts/pr_review.py resolve PRRT_xxx PRRT_yyy
.claude/skills/address-pr-review/scripts/pr_review.py reply PRRT_xxx --body 'Intentional.'
.claude/skills/address-pr-review/scripts/pr_review.py reply PRRT_xxx --body - < /tmp/reply.md
.claude/skills/address-pr-review/scripts/pr_review.py api repos/{owner}/{repo}/pulls/37/comments
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

#: `gh` errors raised before the request reached GitHub - the TCP connect or the
#: TLS handshake never completed - so replaying any call, a mutation included,
#: cannot apply it twice. A TLS-intercepting corporate proxy produces the
#: handshake timeout in bursts that clear within seconds.
TRANSIENT_GH_ERRORS = ("TLS handshake timeout", "dial tcp", "proxyconnect tcp")
GH_ATTEMPTS = 3
GH_BACKOFF = 2.0

#: `gh api` options that take a value (`gh api --help`). The argument after one
#: is its value, never an option.
GH_API_VALUE_OPTIONS = frozenset(
    {
        *("-F", "--field", "-f", "--raw-field", "-H", "--header", "-X", "--method"),
        *("-q", "--jq", "-t", "--template", "-p", "--preview"),
        *("--input", "--cache", "--hostname"),
    }
)

#: Latest replies shown per thread. The newest is where a conversation stands.
REPLIES_SHOWN = 3

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

THREADS_PAGE_QUERY = (
    """
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
          latest: comments(last: %d) {
            totalCount
            nodes {
              body
              author { login }
            }
          }
        }
      }
    }
  }
}
"""
    % REPLIES_SHOWN
)

RESOLVE_MUTATION = """
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}
"""

REPLY_MUTATION = """
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment { url }
  }
}
"""


def _gh(
    cmd: list[str], stdin: bytes | None = None, *, binary: bool = False
) -> subprocess.CompletedProcess:
    """
    Run a gh command, retrying the failures in TRANSIENT_GH_ERRORS.

    Exits with a concise message when gh is missing or a call hangs. The
    timeout matters because `wait` polls: a single `gh` call that blocks on a
    network stall or an auth prompt would otherwise hang the whole pipeline
    past its own deadline, with nothing on stderr to act on.

    `binary` returns stdout and stderr as bytes, untouched by decoding or
    newline translation.
    """
    for attempt in range(1, GH_ATTEMPTS + 1):
        try:
            result = subprocess.run(
                cmd, input=stdin, capture_output=True, text=not binary, timeout=GH_TIMEOUT
            )
        except FileNotFoundError:
            print("gh CLI not found on PATH. Install and authenticate gh.", file=sys.stderr)
            raise SystemExit(1) from None
        except subprocess.TimeoutExpired:
            print(
                f"gh command timed out after {GH_TIMEOUT}s: {' '.join(cmd[:3])} ...",
                file=sys.stderr,
            )
            raise SystemExit(1) from None
        stderr = result.stderr.decode(errors="replace") if binary else result.stderr
        transient = any(token in stderr for token in TRANSIENT_GH_ERRORS)
        if result.returncode == 0 or not transient or attempt == GH_ATTEMPTS:
            return result
        print(
            f"gh: network error before reaching GitHub, retrying ({attempt}/{GH_ATTEMPTS - 1})",
            file=sys.stderr,
        )
        time.sleep(GH_BACKOFF * attempt)
    raise AssertionError("unreachable")  # pragma: no cover


def _run_gh(cmd: list[str]) -> str:
    """
    Run a gh command, returning stdout. Exit with a concise message on failure.

    Using check=True here would raise CalledProcessError and dump a Python
    traceback on common, expected failures (gh not installed, not logged in,
    missing scopes). Surface a readable one-line error the calling skill can
    show the user instead.
    """
    result = _gh(cmd)
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

    Goes through `_gh` like every other call: omitting `--pr` is the normal
    path, so an unbounded call here would hang `state`, `trigger` and `wait`
    alike. A network error that outlasts the retries is reported as one -
    "No open PR" would send the caller off to push a branch that is pushed.

    Only an OPEN PR counts: a reused branch name otherwise finds its merged or
    closed PR, and every later verb would act on that review instead.
    """
    result = _gh(
        [
            "gh",
            "pr",
            "view",
            "--json",
            "number,state",
            "--jq",
            'select(.state == "OPEN") | .number',
        ]
    )
    if result.returncode != 0 and any(t in result.stderr for t in TRANSIENT_GH_ERRORS):
        print(f"gh pr view failed: {result.stderr.strip()}", file=sys.stderr)
        raise SystemExit(1)
    if result.returncode != 0 or not result.stdout.strip():
        detail = f" (gh: {result.stderr.strip()})" if result.returncode else ""
        print(f"No open PR on this branch. Push first or specify --pr.{detail}", file=sys.stderr)
        raise SystemExit(1)
    try:
        return int(result.stdout.strip())
    except ValueError:
        # Anything non-numeric here is gh printing something unexpected. A
        # ValueError traceback would undo the point of every other branch in
        # this function.
        print(
            f"could not read a PR number from gh: {result.stdout.strip()[:200]}", file=sys.stderr
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
    latest = thread.get("latest") or {
        "totalCount": len(comments),
        "nodes": comments[-REPLIES_SHOWN:],
    }
    # `latest` counts the opening comment too; its tail is replies only once
    # it starts past position 0.
    skip = max(0, 1 - (latest["totalCount"] - len(latest["nodes"])))
    return {
        "id": thread["id"],
        "isOutdated": thread["isOutdated"],
        "path": first.get("path", ""),
        "line": first.get("line") or first.get("originalLine"),
        "author": (first.get("author") or {}).get("login", "unknown"),
        "body": first.get("body", ""),
        "replyCount": max(0, latest["totalCount"] - 1),
        "replies": [
            {"author": (c.get("author") or {}).get("login", "unknown"), "body": c.get("body", "")}
            for c in latest["nodes"][skip:]
        ],
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
    fresh_review_sha = (fresh_review.get("commit") or {}).get("oid") if fresh_review else None

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
            _flatten_thread(t) for t in all_threads if not t["isResolved"] and not t["isOutdated"]
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
    return [_flatten_thread(t) for t in _fetch_all_threads(owner, repo, pr) if not t["isResolved"]]


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
    """Resolve each thread; report which resolved, exit 1 when any did not."""
    resolved, failed = [], []
    for thread_id in args.thread_ids:
        # _run_gh exits on a gh failure; one bad id must not hide the others' outcome.
        try:
            data = _graphql(RESOLVE_MUTATION, threadId=thread_id)
        except SystemExit:
            failed.append(thread_id)
            continue
        thread = ((data.get("data") or {}).get("resolveReviewThread") or {}).get("thread") or {}
        (resolved if thread.get("isResolved") else failed).append(thread_id)
    json.dump({"resolved": resolved, "failed": failed}, sys.stdout)
    print()
    return 1 if failed else 0


def cmd_reply(args: argparse.Namespace) -> int:
    """Post a reply to one review thread."""
    body = sys.stdin.read() if args.body == "-" else args.body
    if not body.strip():
        print("reply body is empty", file=sys.stderr)
        return 2
    data = _graphql(REPLY_MUTATION, threadId=args.thread_id, body=body)
    reply = (data.get("data") or {}).get("addPullRequestReviewThreadReply") or {}
    url = (reply.get("comment") or {}).get("url")
    if not url:
        print(f"reply not posted to {args.thread_id}: {json.dumps(data)[:300]}", file=sys.stderr)
        return 1
    print(json.dumps({"replied": args.thread_id, "url": url}))
    return 0


def _api_reads_stdin(gh_args: list[str]) -> bool:
    """
    Whether `gh api` would read stdin: `--input -`, or a typed field set to `@-`.

    Parses the way gh's flag library (pflag) does, so an option's value is
    never read as an option itself (`--template '--input=-'` is template text).
    Every spelling counts: `-F k=@-`, `-Fk=@-`, `-F=k=@-`, `-iF k=@-`,
    `--field k=@-`, `--field=k=@-`. `-f`/`--raw-field` take `@-` literally,
    and a repeated `--input` keeps its last value.
    """
    input_value = ""
    typed_stdin = False
    args = iter(gh_args)
    for arg in args:
        if arg == "--":
            break
        if arg.startswith("--"):
            name, eq, value = arg.partition("=")
            if name not in GH_API_VALUE_OPTIONS:
                continue
            if not eq:
                value = next(args, "")
        elif arg.startswith("-") and len(arg) > 1:
            # A shorthand group (`-iF`) runs to its first value-taking flag,
            # which takes the rest of the group or else the next argument. Flag
            # names end at `=`: in `-i=f` the `f` is the value of boolean `-i`.
            group = arg[1:]
            names = group.partition("=")[0]
            at = next((i for i, c in enumerate(names) if f"-{c}" in GH_API_VALUE_OPTIONS), None)
            if at is None:
                continue
            name, rest = f"-{group[at]}", group[at + 1 :]
            value = rest.removeprefix("=") if rest else next(args, "")
        else:
            continue
        if name == "--input":
            input_value = value
        # gh splits key=value on the first `=`; only a value of exactly `@-` reads stdin.
        elif name in ("-F", "--field") and value.partition("=")[2] == "@-":
            typed_stdin = True
    return typed_stdin or input_value == "-"


def cmd_api(gh_args: list[str]) -> int:
    """
    Run `gh api` with `gh_args` verbatim, relaying its stdout, stderr and exit code.

    Stdin is read up front only when gh would read it: an agent's shell can
    leave stdin open with nothing on it, and an unconditional read would block
    until the timeout. gh never inherits stdin, so a retry gets the same input.
    Output is relayed as bytes, so a binary response survives.
    """
    stdin = sys.stdin.buffer.read() if _api_reads_stdin(gh_args) else b""
    result = _gh(["gh", "api", *gh_args], stdin=stdin, binary=True)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


def main(argv: Sequence[str] | None = None) -> int:
    """Parse args, dispatch to a subcommand."""
    argv = list(sys.argv[1:] if argv is None else argv)
    # argparse.REMAINDER rejects a leading option (`api --method POST ...`), so
    # `api` takes its arguments before argparse sees them.
    if argv[:1] == ["api"]:
        return cmd_api(argv[1:])
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[1])
    sub = parser.add_subparsers(dest="command", required=True)

    p_state = sub.add_parser("state", help="Detect current review state")
    p_state.add_argument("--pr", type=int, help="PR number (auto-detect if omitted)")

    p_unresolved = sub.add_parser(
        "unresolved", help="List ALL unresolved threads (incl. outdated); exit 1 if any"
    )
    p_unresolved.add_argument("--pr", type=int, help="PR number (auto-detect if omitted)")

    p_trigger = sub.add_parser("trigger", help="Request Copilot review")
    p_trigger.add_argument("--pr", type=int, help="PR number (auto-detect if omitted)")

    p_wait = sub.add_parser("wait", help="Poll until state resolves to C or D")
    p_wait.add_argument("--pr", type=int, help="PR number (auto-detect if omitted)")
    p_wait.add_argument("--interval", type=int, default=30, help="Seconds between polls")
    p_wait.add_argument("--timeout", type=int, default=480, help="Total timeout in seconds")

    p_resolve = sub.add_parser("resolve", help="Resolve review threads")
    p_resolve.add_argument("thread_ids", nargs="+", help="GraphQL node IDs (PRRT_*)")

    p_reply = sub.add_parser("reply", help="Reply to a review thread")
    p_reply.add_argument("thread_id", help="GraphQL node ID (PRRT_*)")
    p_reply.add_argument("--body", required=True, help="Reply text, or - to read stdin")

    sub.add_parser("api", help="Run `gh api ARGS...` verbatim, with retries")

    args = parser.parse_args(argv)
    handlers = {
        "state": cmd_state,
        "unresolved": cmd_unresolved,
        "trigger": cmd_trigger,
        "wait": cmd_wait,
        "resolve": cmd_resolve,
        "reply": cmd_reply,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
