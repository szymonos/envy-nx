#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "~=3.14.0"
# dependencies = []
# ///
r"""
Periodic standing-code review of one shard: the deterministic half of /review.

The agent decides what each finding is; this script owns everything that has a
right answer - which shard is next, which files it owns, what was decided about
it before, and whether a run is complete enough to record.

Verbs:
  prepare [SHARD|next]  resolve the shard, cut the branch, write the intent file
                        and print the reviewer prompt
  second-opinion        review the shard's files with second-opinion, base = an
                        empty root commit, so the "diff" is the whole files
  status                rotation table, unowned files, over-budget shards
  owner PATH...         the shard that owns each path
  finish                refuse while a finding, a carried-in follow-up or an
                        escalation lacks a decision; then run the unit tests,
                        record the run in design/reviews/history.md and commit

Exit codes: 0 done, 1 error, 2 usage, 10 decisions missing (finish).

# :example
.claude/skills/review/scripts/review.py status
.claude/skills/review/scripts/review.py prepare next
.claude/skills/review/scripts/review.py owner .assets/lib/nx_doctor.sh
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
MANIFEST = Path("design/reviews/shards.json")
HISTORY = Path("design/reviews/history.md")
STATE_DIR = Path(".review")
STATE_FILE = STATE_DIR / "state.json"
INTENT_FILE = STATE_DIR / "intent.md"
DECISION_LOG = STATE_DIR / "decision-log.md"
FINDINGS_DIR = STATE_DIR / "findings"
CLI = ".claude/skills/review/scripts/review.py"

# second-opinion is installed per user, not vendored here; without it the
# charter-driven reviewer runs alone.
BRIEF_SCRIPT = Path.home() / ".claude/skills/second-opinion/scripts/review_brief.py"
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

EXIT_OK, EXIT_ERR, EXIT_USAGE, EXIT_GATE = 0, 1, 2, 10
TRUNK = "main"
BLAST_ORDER = {"high": 0, "medium": 1, "low": 2}
# One reviewer reads every owned file in full; past this a shard should split.
LINE_BUDGET = 6500

CALLS = ("fix", "decline", "resolve-only", "handoff", "escalate")
ANSWER = "answered"
# An answer's Why starts with one of these, so finish can act on it.
OUTCOMES = ("fix:", "decline:", "leave:")
LOG_HEADER = (
    "| ID | Where | Finding | Call | Owner | Why |\n"
    "| -- | ----- | ------- | ---- | ----- | --- |\n"
)
RUNS_HEADING = "## Runs"
FOLLOWUPS_HEADING = "## Open follow-ups"
LOGS_HEADING = "## Decision logs"


class ReviewError(Exception):
    """A failure the agent should surface verbatim."""


# -- git ----------------------------------------------------------------------


def git(*args: str, check: bool = True) -> str:
    """Run git in the repo; raise with its stderr on failure."""
    result = subprocess.run(
        ["git", *args], cwd=REPO, capture_output=True, text=True, timeout=60
    )
    if check and result.returncode != 0:
        raise ReviewError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def tracked_files(root: Path = REPO) -> list[str]:
    """Every file git tracks under *root*."""
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, capture_output=True, text=True, timeout=60
    )
    if out.returncode != 0:
        raise ReviewError(f"git ls-files failed in {root}: {out.stderr.strip()}")
    return [f for f in out.stdout.split("\0") if f]


# -- ownership ----------------------------------------------------------------


def load_manifest(root: Path = REPO) -> dict:
    """The parsed `design/reviews/shards.json`."""
    return json.loads((root / MANIFEST).read_text(encoding="utf-8"))


def specificity(pattern: str) -> int:
    """Literal characters in a glob: an exact path beats any glob that matches it."""
    return sum(ch not in "*?[]" for ch in pattern)


def _matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


def owners(path: str, manifest: dict) -> list[str]:
    """
    Shards owning *path*: the one whose matching glob is most specific.

    More than one name back means two shards tie at the same specificity, which
    the coverage check reports. A `skip` match owns nothing.
    """
    if _matches(path, manifest.get("skip", [])):
        return []
    best, names = -1, []
    for shard in manifest["shards"]:
        for pattern in shard["owns"]:
            if not fnmatch.fnmatchcase(path, pattern):
                continue
            score = specificity(pattern)
            if score > best:
                best, names = score, [shard["name"]]
            elif score == best and shard["name"] not in names:
                names.append(shard["name"])
    return names


def coverage(
    files: list[str], manifest: dict
) -> tuple[list[str], dict[str, list[str]]]:
    """Files no shard owns and `unowned_ok` does not excuse; files two shards tie on."""
    unowned, ambiguous = [], {}
    for path in files:
        found = owners(path, manifest)
        if len(found) > 1:
            ambiguous[path] = found
        elif not found and not _matches(
            path, manifest.get("skip", []) + manifest.get("unowned_ok", [])
        ):
            unowned.append(path)
    return unowned, ambiguous


def owned_files(shard: str, files: list[str], manifest: dict) -> list[str]:
    """The files *shard* alone owns."""
    return [f for f in files if owners(f, manifest) == [shard]]


def nearest_shard(path: str, manifest: dict, files: list[str]) -> str | None:
    """The shard owning most files in the closest directory above *path*."""
    parts = path.split("/")[:-1]
    while parts:
        prefix = "/".join(parts) + "/"
        counts: dict[str, int] = {}
        for f in files:
            if f.startswith(prefix):
                for name in owners(f, manifest):
                    counts[name] = counts.get(name, 0) + 1
        if counts:
            return max(sorted(counts), key=counts.get)
        parts.pop()
    return None


def shard_entry(name: str, manifest: dict) -> dict:
    """The manifest entry for *name*, or an error listing the shards."""
    for shard in manifest["shards"]:
        if shard["name"] == name:
            return shard
    names = ", ".join(s["name"] for s in manifest["shards"])
    raise ReviewError(f"no shard named '{name}'. Shards: {names}")


def line_count(paths: list[str]) -> int:
    """Total lines across *paths*, skipping anything unreadable as text."""
    total = 0
    for p in paths:
        try:
            total += len((REPO / p).read_text(encoding="utf-8").splitlines())
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
    return total


def charter_sha(shard: dict) -> str:
    """Short hash of the shard's charter, recorded with each run."""
    return hashlib.sha256((REPO / shard["charter"]).read_bytes()).hexdigest()[:8]


# -- history.md ---------------------------------------------------------------


def _table_rows(text: str) -> list[list[str]]:
    """Data rows of every markdown table in *text*, cells stripped."""
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("|") or re.fullmatch(r"\|[\s:|-]+\|", line):
            continue
        rows.append([c.strip() for c in line.strip("|").split("|")])
    return rows


def _section(text: str, heading: str) -> str:
    """Body of a `## ` section, up to the next `## ` heading."""
    match = re.search(rf"^{re.escape(heading)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return match.group(1) if match else ""


def parse_history(text: str) -> dict:
    """Runs, open follow-ups and per-run decision logs from history.md."""
    runs = []
    for row in _table_rows(_section(text, RUNS_HEADING))[1:]:
        if len(row) >= 4:
            runs.append({"date": row[0], "shard": row[1], "charter": row[2]})
    followups = []
    for row in _table_rows(_section(text, FOLLOWUPS_HEADING))[1:]:
        if len(row) >= 5:
            followups.append(dict(zip(("id", "for", "where", "finding", "from"), row)))
    logs = [
        {
            "date": match.group(1),
            "shard": match.group(2),
            "rows": parse_log(match.group(3)),
        }
        for match in re.finditer(
            r"^### (\S+) (\S+)\s*$(.*?)(?=^### |^## |\Z)",
            _section(text, LOGS_HEADING),
            re.M | re.S,
        )
    ]
    return {"runs": runs, "followups": followups, "logs": logs}


def read_history() -> dict:
    """The parsed history.md, empty when the file does not exist."""
    path = REPO / HISTORY
    if not path.is_file():
        return {"runs": [], "followups": [], "logs": []}
    return parse_history(path.read_text(encoding="utf-8"))


def earlier_declines(history: dict, shard: str) -> list[dict]:
    """Every finding an earlier review of *shard* declined, the user's included."""
    declines = []
    for log in history["logs"]:
        if log["shard"] != shard:
            continue
        answers = {r["id"]: r["why"] for r in log["rows"] if r["call"] == ANSWER}
        for row in log["rows"]:
            if row["call"] == "decline":
                declines.append(row)
            elif row["call"] == "escalate" and not answers.get(
                row["id"], ""
            ).lower().startswith("fix:"):
                declines.append({**row, "why": answers.get(row["id"], row["why"])})
    return declines


def next_followup_id(history_text: str) -> int:
    """One past the highest `FU-NNN` mentioned anywhere in the history."""
    ids = [int(n) for n in re.findall(r"\bFU-(\d+)\b", history_text)]
    return max(ids, default=0) + 1


# -- rotation -----------------------------------------------------------------


def last_runs(history: dict) -> dict[str, dict]:
    """Each shard's most recent run."""
    latest: dict[str, dict] = {}
    for run in history["runs"]:
        if run["shard"] not in latest or run["date"] >= latest[run["shard"]]["date"]:
            latest[run["shard"]] = run
    return latest


def commits_since(day: str, paths: list[str]) -> int:
    """Commits touching *paths* after the day *day*."""
    if not paths:
        return 0
    # The review's own commit lands on its date; count what came after that day.
    out = git("rev-list", "--count", f"--since={day} 23:59:59", "HEAD", "--", *paths)
    return int(out or 0)


def rotation(manifest: dict, history: dict, files: list[str]) -> list[dict]:
    """
    Every shard with what the pick weighs, in pick order.

    Never-reviewed first, high blast radius first among them; then a shard with
    follow-ups handed to it; then the most commits touching its files since its
    last review; then the oldest review.
    """
    latest = last_runs(history)
    open_for: dict[str, int] = {}
    for fu in history["followups"]:
        open_for[fu["for"]] = open_for.get(fu["for"], 0) + 1
    table = []
    for shard in manifest["shards"]:
        name = shard["name"]
        mine = owned_files(name, files, manifest)
        run = latest.get(name)
        table.append(
            {
                "shard": name,
                "blast": shard["blast_radius"],
                "files": len(mine),
                "lines": line_count(mine),
                "last": run["date"] if run else None,
                "commits": commits_since(run["date"], mine) if run else None,
                "followups": open_for.get(name, 0),
                "charter_changed": bool(run) and run["charter"] != charter_sha(shard),
            }
        )
    return sorted(table, key=_pick_key)


def _pick_key(row: dict) -> tuple:
    never = row["last"] is None
    return (
        0 if never else 1,
        BLAST_ORDER.get(row["blast"], 3) if never else 0,
        -row["followups"],
        0 if row["charter_changed"] else 1,
        -(row["commits"] or 0),
        row["last"] or "",
        row["shard"],
    )


# -- state --------------------------------------------------------------------


def load_state() -> dict:
    """The open run's state, or an error saying none is open."""
    path = REPO / STATE_FILE
    if not path.is_file():
        raise ReviewError(f"no review in progress - run `{CLI} prepare [SHARD|next]`")
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(state: dict) -> None:
    """Write the run state atomically."""
    (REPO / STATE_DIR).mkdir(exist_ok=True)
    tmp = REPO / STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    tmp.replace(REPO / STATE_FILE)


# -- prepare ------------------------------------------------------------------


def _intent(shard: dict, declines: list[dict], carried: list[dict]) -> str:
    parts = [
        f"# Standing review of the `{shard['name']}` shard\n",
        "This is not a change review. The base is an empty commit, so the diff is "
        "every file this shard owns: review the code as it stands. Report defects "
        "a user or contributor would hit, not style.\n",
        "## Charter\n",
        (REPO / shard["charter"]).read_text(encoding="utf-8"),
    ]
    if carried:
        parts.append("\n## Carried in\n")
        parts.append(
            "Follow-ups another shard's review handed to this one. Confirm or "
            "refute each against the code as it is now.\n"
        )
        parts.extend(
            f"- **{fu['id']}** `{fu['where']}` - {fu['finding']}\n" for fu in carried
        )
    if declines:
        parts.append("\n## Already decided\n")
        parts.append(
            "Declined in earlier reviews of this shard. Do not report again.\n"
        )
        parts.extend(
            f"- `{d['where']}` - {d['finding']} Declined: {d['why']}\n"
            for d in declines
        )
    return "".join(parts)


def _reviewer_prompt(shard: dict, files: list[str], intent: Path) -> str:
    return (
        f"Review shard: {shard['name']}\n"
        f"Charter: {shard['charter']}\n"
        f"Intent (charter, carried-in follow-ups, already decided): {intent}\n"
        f"Output path: {FINDINGS_DIR / 'reviewer.json'}\n"
        f"Owned files ({len(files)}):\n"
        + "".join(f"  {f}\n" for f in files)
        + "Context files (read for understanding; report only interaction defects):\n"
        + "".join(f"  {f}\n" for f in shard.get("context", []))
    )


def cmd_prepare(args: argparse.Namespace) -> int:
    """Handle `prepare`: start a review of one shard."""
    if (REPO / STATE_FILE).is_file():
        open_run = load_state()
        raise ReviewError(
            f"a review of '{open_run['shard']}' is open: finish it with "
            f"`{CLI} finish`, or delete {STATE_DIR}/ to drop it"
        )
    if git("status", "--porcelain"):
        raise ReviewError(
            "the working tree has uncommitted changes. Commit or stash them first: "
            "finish commits everything the review changes"
        )
    manifest = load_manifest()
    files = tracked_files()
    history = read_history()
    name = args.shard
    if name == "next":
        name = rotation(manifest, history, files)[0]["shard"]
    shard = shard_entry(name, manifest)
    mine = owned_files(name, files, manifest)
    if not mine:
        raise ReviewError(f"shard '{name}' owns no tracked files - fix its globs")

    branch = git("branch", "--show-current")
    # A release branch is already cut; review fixes go to a later release.
    if branch == TRUNK or branch.startswith("release/"):
        branch = f"review/{name}-{date.today().isoformat()}"
        git("switch", "-c", branch)

    carried = [fu for fu in history["followups"] if fu["for"] == name]
    declines = earlier_declines(history, name)
    (REPO / FINDINGS_DIR).mkdir(parents=True, exist_ok=True)
    (REPO / INTENT_FILE).write_text(_intent(shard, declines, carried), encoding="utf-8")
    (REPO / DECISION_LOG).write_text(LOG_HEADER, encoding="utf-8")
    save_state(
        {
            "shard": name,
            "branch": branch,
            "base": git("rev-parse", "HEAD"),
            "charter": charter_sha(shard),
            "date": date.today().isoformat(),
            "carried": [fu["id"] for fu in carried],
        }
    )
    lines = line_count(mine)
    payload = {
        "shard": name,
        "title": shard["title"],
        "branch": branch,
        "files": len(mine),
        "lines": lines,
        "carried_in": carried,
        "already_decided": len(declines),
        "intent": str(INTENT_FILE),
        "decision_log": str(DECISION_LOG),
        "reviewer_prompt": _reviewer_prompt(shard, mine, INTENT_FILE),
        "next": (
            f"Run `{CLI} second-opinion` in the background (Bash timeout 600000) and "
            "spawn the reviewer subagent with reviewer_prompt at the same time. Then "
            f"triage every finding into {DECISION_LOG}."
        ),
    }
    if lines > LINE_BUDGET:
        payload["warning"] = (
            f"{lines} lines is over the {LINE_BUDGET}-line budget one reviewer reads "
            "in full; consider splitting the shard"
        )
    print(json.dumps(payload, indent=2))
    return EXIT_OK


# -- second-opinion -----------------------------------------------------------


def _skip_second_opinion(out: Path, reason: str) -> int:
    """Record that second-opinion did not run, so finish can tell it from missing."""
    out.write_text(json.dumps({"skipped": reason, "findings": []}) + "\n")
    print(json.dumps({"skipped": reason, "saved": str(out.relative_to(REPO))}))
    return EXIT_OK


def cmd_second_opinion(args: argparse.Namespace) -> int:
    """Handle `second-opinion`: review the shard's files from an empty base."""
    state = load_state()
    out = REPO / FINDINGS_DIR / "second-opinion.json"
    if not BRIEF_SCRIPT.is_file():
        return _skip_second_opinion(out, "second-opinion not installed")
    manifest = load_manifest()
    files = owned_files(state["shard"], tracked_files(), manifest)
    base = git("commit-tree", EMPTY_TREE, "-m", "empty base for a standing review")
    cmd = [
        str(BRIEF_SCRIPT),
        "run",
        base,
        "--intent",
        str(REPO / INTENT_FILE),
        "--timeout",
        str(args.timeout),
        "--files",
        *files,
    ]
    result = subprocess.run(
        cmd, cwd=REPO, capture_output=True, text=True, timeout=args.timeout + 60
    )
    if result.returncode in (3, 4):
        reason = "nothing to review" if result.returncode == 3 else "no Copilot CLI"
        return _skip_second_opinion(out, reason)
    if result.returncode != 0:
        tail = (result.stderr.strip() or result.stdout.strip())[-2000:]
        raise ReviewError(f"second-opinion failed:\n{tail}")
    report = json.loads(result.stdout)
    kept = {
        k: report.get(k)
        for k in ("model", "model_reasons", "failed", "unparsed", "count", "findings")
        if k in report
    }
    out.write_text(json.dumps(kept, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"saved": str(out.relative_to(REPO)), **kept}, indent=2))
    return EXIT_OK


# -- status / owner -----------------------------------------------------------


def cmd_status(_args: argparse.Namespace) -> int:
    """Handle `status`: print the rotation table and coverage problems."""
    manifest = load_manifest()
    files = tracked_files()
    table = rotation(manifest, read_history(), files)
    header = (
        f"{'shard':22} {'blast':7} {'files':>5} {'lines':>6}  "
        f"{'last review':11} {'commits':>7} {'FUs':>3}  note"
    )
    print(header)
    for row in table:
        notes = []
        if row["charter_changed"]:
            notes.append("charter changed")
        if row["lines"] > LINE_BUDGET:
            notes.append(f"over {LINE_BUDGET}-line budget")
        commits = "-" if row["commits"] is None else str(row["commits"])
        print(
            f"{row['shard']:22} {row['blast']:7} {row['files']:>5} {row['lines']:>6}  "
            f"{row['last'] or 'never':11} {commits:>7} {row['followups']:>3}  "
            f"{', '.join(notes)}"
        )
    print(f"\nnext: {table[0]['shard']}")
    unowned, ambiguous = coverage(files, manifest)
    for path in unowned:
        print(
            f"unowned: {path} (nearest shard: {nearest_shard(path, manifest, files)})"
        )
    for path, names in ambiguous.items():
        print(f"two owners: {path} ({', '.join(names)})")
    return EXIT_OK


def cmd_owner(args: argparse.Namespace) -> int:
    """Handle `owner`: print the shard owning each path."""
    manifest = load_manifest()
    for path in args.paths:
        found = owners(path, manifest)
        print(f"{path}: {', '.join(found) if found else 'none'}")
    return EXIT_OK


# -- finish -------------------------------------------------------------------


def parse_log(text: str) -> list[dict]:
    """Rows of the run's decision log."""
    keys = ("id", "where", "finding", "call", "owner", "why")
    return [dict(zip(keys, r)) for r in _table_rows(text)[1:] if len(r) >= 6]


REPORTS = ("reviewer.json", "second-opinion.json")


def read_reports(findings_dir: Path) -> dict[str, dict]:
    """Both reviewers' reports; a missing or unreadable one is an error."""
    reports = {}
    for name in REPORTS:
        path = findings_dir / name
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data.get("findings"), list):
                raise ValueError("no findings list")
            ids = [f["id"] for f in data["findings"]]
        except FileNotFoundError:
            hint = (
                "spawn the reviewer subagent"
                if name == "reviewer.json"
                else f"run `{CLI} second-opinion`"
            )
            raise ReviewError(f"{path.relative_to(REPO)} is missing - {hint}") from None
        except (ValueError, TypeError, KeyError, AttributeError, OSError) as exc:
            raise ReviewError(
                f"{path.relative_to(REPO)} is not a findings report: {exc}"
            ) from None
        reports[name] = {**data, "ids": ids}
    return reports


def finding_ids(reports: dict[str, dict]) -> list[str]:
    """Every finding's id; a carried-in follow-up is decided under its FU-NNN."""
    return [
        f.get("carried") or f["id"]
        for report in reports.values()
        for f in report["findings"]
    ]


def log_problems(
    rows: list[dict], ids: list[str], state: dict, manifest: dict
) -> list[str]:
    """Everything that stops a run being recorded, one line each."""
    shards = [s["name"] for s in manifest["shards"]]
    problems = []
    decided = {r["id"] for r in rows if r["call"] in CALLS}
    answered = {r["id"] for r in rows if r["call"] == ANSWER}
    for kind, calls in (("decision", CALLS), ("answer", (ANSWER,))):
        seen = [r["id"] for r in rows if r["call"] in calls]
        problems.extend(
            f"{i}: {seen.count(i)} {kind} rows - keep one"
            for i in sorted(set(seen))
            if seen.count(i) > 1
        )
    for row in rows:
        if row["call"] not in (*CALLS, ANSWER):
            problems.append(
                f"{row['id']}: unknown call '{row['call']}' "
                f"(use {', '.join(CALLS)} or {ANSWER})"
            )
        if row["call"] == "handoff" and row["owner"] not in shards:
            problems.append(
                f"{row['id']}: handoff needs Owner set to a shard, got '{row['owner']}'"
            )
        if row["call"] == "handoff" and row["owner"] == state["shard"]:
            problems.append(
                f"{row['id']}: handoff to this shard - "
                "fix, decline or escalate it instead"
            )
        if row["call"] == "handoff":
            found = owners(row["where"].split(":", 1)[0], manifest)
            if found and row["owner"] not in found:
                problems.append(
                    f"{row['id']}: {row['where']} is owned by {', '.join(found)}, "
                    f"not {row['owner']} - hand it off there, or decide it here"
                )
        if row["call"] == "escalate" and row["id"] not in answered:
            problems.append(
                f"{row['id']}: escalation not answered - "
                f"ask it, then add an `{ANSWER}` row"
            )
        if row["call"] == ANSWER and not row["why"].lower().startswith(OUTCOMES):
            problems.append(
                f"{row['id']}: an answer's Why starts with {', '.join(OUTCOMES)} - "
                "the outcome, not the option label"
            )
    problems.extend(
        f"{i}: finding has no decision row" for i in ids if i not in decided
    )
    problems.extend(
        f"{fu}: carried-in follow-up has no decision row"
        for fu in state["carried"]
        if fu not in decided
    )
    return problems


def tally(rows: list[dict], ids: list[str]) -> dict:
    """Counts for the run row; an escalation the user answered `fix` is a fix."""
    counts = {call: sum(r["call"] == call for r in rows) for call in CALLS}
    counts["fix"] += sum(
        r["call"] == ANSWER and r["why"].lower().startswith("fix:") for r in rows
    )
    counts["found"] = len(set(ids))
    return counts


def distinct_causes(rows: list[dict]) -> dict:
    """Root causes per call; like `tally`, an answered `fix` is a fix."""
    causes: dict[str, set] = {call: set() for call in CALLS}
    for r in rows:
        if r["call"] in causes:
            causes[r["call"]].add(r["why"])
        elif r["call"] == ANSWER and r["why"].lower().startswith("fix:"):
            causes["fix"].add(r["why"])
    return {call: len(whys) for call, whys in causes.items()}


def render_history(text: str, state: dict, rows: list[dict], counts: dict) -> str:
    """history.md with this run's row, decision log and follow-up changes applied."""
    if not text:
        text = (
            "# Review history\n\n"
            "<!-- arch-drift: record -->\n\n"
            f"Written by `{CLI} finish`. Read by `status` and `prepare`.\n\n"
            f"{RUNS_HEADING}\n\n"
            "| Date | Shard | Charter | Found | Fixed | Declined | Escalated "
            "| Handed off | Branch |\n"
            "| ---- | ----- | ------- | ----- | ----- | -------- | --------- "
            "| ---------- | ------ |\n\n"
            f"{FOLLOWUPS_HEADING}\n\n"
            "| ID | For | Where | Finding | From |\n"
            "| -- | --- | ----- | ------- | ---- |\n\n"
            f"{LOGS_HEADING}\n"
        )
    run_row = (
        f"| {state['date']} | {state['shard']} | {state['charter']} "
        f"| {counts['found']} "
        f"| {counts['fix']} | {counts['decline']} | {counts['escalate']} "
        f"| {counts['handoff']} | {state['branch']} |\n"
    )
    text = _append_to_table(text, RUNS_HEADING, run_row)

    # Numbered before closing anything, so a closed follow-up's id is never reused.
    fu_next = next_followup_id(text)
    closed = {r["id"] for r in rows if r["call"] in CALLS} & set(state["carried"])
    text = _drop_followups(text, closed)
    log_rows = []
    for row in rows:
        if row["call"] == "handoff":
            fu = f"FU-{fu_next:03d}"
            fu_next += 1
            text = _append_to_table(
                text,
                FOLLOWUPS_HEADING,
                f"| {fu} | {row['owner']} | {row['where']} | {row['finding']} "
                f"| {state['shard']} {state['date']} |\n",
            )
            row = {**row, "why": f"{fu}: {row['why']}"}
        log_rows.append(
            f"| {row['id']} | {row['where']} | {row['finding']} | {row['call']} "
            f"| {row['owner']} | {row['why']} |\n"
        )
    log = f"\n### {state['date']} {state['shard']}\n\n{LOG_HEADER}{''.join(log_rows)}"
    return text.rstrip("\n") + "\n" + log


def _drop_followups(text: str, closed: set[str]) -> str:
    """Remove the *closed* rows from the open follow-ups table, and only there."""
    lines = text.splitlines(keepends=True)
    inside = False
    kept = []
    for line in lines:
        if line.startswith("## "):
            inside = line.strip() == FOLLOWUPS_HEADING
        if inside and any(line.startswith(f"| {fu} |") for fu in closed):
            continue
        kept.append(line)
    return "".join(kept)


def _append_to_table(text: str, heading: str, row: str) -> str:
    """Insert *row* after the last table line of the `## ` section *heading*."""
    lines = text.splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.strip() == heading)
    end = start + 1
    while end < len(lines) and not lines[end].startswith("## "):
        end += 1
    last = max(
        (i for i in range(start, end) if lines[i].lstrip().startswith("|")),
        default=None,
    )
    if last is None:
        raise ReviewError(f"{HISTORY}: no table under '{heading}'")
    lines.insert(last + 1, row)
    return "".join(lines)


def run_unit_tests() -> None:
    """Run `make test-unit`; raise with its tail on failure."""
    result = subprocess.run(
        ["make", "test-unit"], cwd=REPO, capture_output=True, text=True, timeout=1800
    )
    if result.returncode != 0:
        tail = (result.stdout + result.stderr).strip()[-3000:]
        raise ReviewError(
            f"make test-unit failed - fix it and run finish again:\n{tail}"
        )


def run_lint() -> None:
    """Run `make lint`; one retry picks up what auto-fixing hooks rewrote."""
    for _ in range(2):
        result = subprocess.run(
            ["make", "lint"], cwd=REPO, capture_output=True, text=True, timeout=1800
        )
        if result.returncode == 0:
            return
    tail = (result.stdout + result.stderr).strip()[-3000:]
    raise ReviewError(
        f"make lint failed - fix what it names and run finish again:\n{tail}"
    )


def committed_history() -> str:
    """history.md as HEAD has it, so a retried finish renders from a clean base."""
    out = subprocess.run(
        ["git", "show", f"HEAD:{HISTORY}"],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return out.stdout if out.returncode == 0 else ""


def cmd_finish(args: argparse.Namespace) -> int:
    """Handle `finish`: check decisions, test, lint, record and commit the run."""
    state = load_state()
    manifest = load_manifest()
    rows = parse_log((REPO / DECISION_LOG).read_text(encoding="utf-8"))
    reports = read_reports(REPO / FINDINGS_DIR)
    ids = finding_ids(reports)
    problems = log_problems(rows, ids, state, manifest)
    if problems:
        print(
            json.dumps(
                {"decisions_missing": problems, "decision_log": str(DECISION_LOG)},
                indent=2,
            )
        )
        return EXIT_GATE

    counts = tally(rows, ids)
    if counts["fix"] and not args.skip_tests:
        run_unit_tests()

    # Rendered from HEAD every time: a retry after a failed lint or test
    # records the decisions as they are now, not as they were on the first try.
    rendered = render_history(committed_history(), state, rows, counts)
    tmp = REPO / HISTORY.with_suffix(".tmp")
    tmp.write_text(rendered, encoding="utf-8")
    tmp.replace(REPO / HISTORY)
    run_lint()

    kind = "fix" if counts["fix"] else "docs"
    message = f"{kind}({state['shard']}): standing review {state['date']}"
    if args.trailer:
        message += "\n\n" + "\n".join(args.trailer)
    git("add", "-A")
    # make lint has just run the pre-commit hooks; --no-verify skips the
    # commit-msg ones too, so they run here, against the staged changes.
    msg_file = REPO / STATE_DIR / "COMMIT_MSG"
    msg_file.write_text(message + "\n", encoding="utf-8")
    hook = subprocess.run(
        ["git", "hook", "run", "--ignore-missing", "commit-msg", "--", str(msg_file)],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    if hook.returncode != 0:
        raise ReviewError(
            "commit-msg hooks failed - fix what they name and run "
            f"finish again:\n{(hook.stdout + hook.stderr).strip()[-3000:]}"
        )
    git("commit", "-q", "--no-verify", "-F", str(msg_file))
    shutil.rmtree(REPO / STATE_DIR)
    skipped = reports["second-opinion.json"].get("skipped")
    failed = reports["second-opinion.json"].get("failed")
    print(
        json.dumps(
            {
                "recorded": str(HISTORY),
                "commit": git("rev-parse", "--short", "HEAD"),
                "branch": state["branch"],
                **counts,
                "distinct": distinct_causes(rows),
                **({"second_opinion_skipped": skipped} if skipped else {}),
                **({"second_opinion_failed_lenses": failed} if failed else {}),
                "next": "Hand the branch to /release-auto once the reviews "
                "you want are in.",
            },
            indent=2,
        )
    )
    return EXIT_OK


# -- entry --------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    """The command-line parser."""
    parser = argparse.ArgumentParser(
        prog="scripts/review.py", description=__doc__.split("\n\n")[0]
    )
    sub = parser.add_subparsers(dest="verb", required=True)
    p = sub.add_parser("prepare", help="Start a review of one shard")
    p.add_argument(
        "shard", nargs="?", default="next", help="Shard name, or next (default)"
    )
    p.set_defaults(func=cmd_prepare)
    p = sub.add_parser("second-opinion", help="Review the shard with second-opinion")
    p.add_argument(
        "--timeout", type=int, default=540, help="Seconds per lens pass (default 540)"
    )
    p.set_defaults(func=cmd_second_opinion)
    p = sub.add_parser("status", help="Rotation table and coverage")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("owner", help="The shard owning each path")
    p.add_argument("paths", nargs="+")
    p.set_defaults(func=cmd_owner)
    p = sub.add_parser(
        "finish", help="Check decisions, test, record and commit the run"
    )
    p.add_argument("--trailer", action="append", help="Commit trailer line; repeatable")
    p.add_argument(
        "--skip-tests",
        action="store_true",
        help="Skip make test-unit (already run on this tree)",
    )
    p.set_defaults(func=cmd_finish)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Dispatch a verb and map failures to exit codes."""
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ReviewError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERR
    except subprocess.TimeoutExpired as exc:
        print(f"error: timed out: {' '.join(map(str, exc.cmd))}", file=sys.stderr)
        return EXIT_ERR


if __name__ == "__main__":
    raise SystemExit(main())
