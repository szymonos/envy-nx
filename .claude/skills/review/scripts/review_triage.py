#!/usr/bin/env -S uv run python3
"""
review_triage.py - write a triage decision to the findings JSON.

Handles the atomic JSON update for each finding's triage_decision and
triage_rationale. Also closes the corresponding followup entry when a
finding prefixed with [FU-NNN] is triaged.

Usage
-----
    python3 .claude/skills/review/scripts/review_triage.py
        <findings-path> <finding-id> <decision> [rationale]

    decision: apply | defer | dispute
    rationale: required for defer/dispute, ignored for apply

Exit codes: 0 = success, 1 = error. Status message on stdout.
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    """Write a triage decision to the findings JSON."""
    if len(sys.argv) < 4:
        print(
            "usage: review_triage.py <findings-path>"
            " <finding-id> <decision> [rationale]",
            file=sys.stderr,
        )
        return 1

    findings_rel = sys.argv[1]
    finding_id = sys.argv[2]
    decision = sys.argv[3]
    rationale = " ".join(sys.argv[4:]) if len(sys.argv) > 4 else None

    if decision not in ("apply", "defer", "dispute"):
        print(
            f"error: decision must be apply|defer|dispute, got '{decision}'",
            file=sys.stderr,
        )
        return 1

    if decision in ("defer", "dispute") and not rationale:
        print(f"error: rationale required for '{decision}'", file=sys.stderr)
        return 1

    repo = Path(__file__).resolve().parents[4]
    findings_path = (repo / findings_rel).resolve()

    if not findings_path.is_relative_to(repo):
        print("error: findings path must be repo-relative", file=sys.stderr)
        return 1

    if not findings_path.exists():
        print(f"error: findings file not found: {findings_rel}", file=sys.stderr)
        return 1

    data = json.loads(findings_path.read_text())
    finding = next((f for f in data["findings"] if f["id"] == finding_id), None)
    if finding is None:
        ids = [f["id"] for f in data["findings"]]
        print(
            f"error: finding '{finding_id}' not found. available: {', '.join(ids)}",
            file=sys.stderr,
        )
        return 1

    if "triage_decision" in finding:
        print(
            f"warning: {finding_id} already triaged as"
            f" '{finding['triage_decision']}', overwriting",
            file=sys.stderr,
        )

    finding["triage_decision"] = decision
    if decision in ("defer", "dispute") and rationale:
        finding["triage_rationale"] = rationale
    elif "triage_rationale" in finding:
        del finding["triage_rationale"]

    _atomic_write(findings_path, data)

    fu_match = re.match(r"^\[FU-(\d+)\]", finding.get("finding", ""))
    if fu_match:
        shard = data.get("shard", "")
        fu_id = f"FU-{fu_match.group(1)}"
        closed = _close_followup(repo, shard, fu_id, decision)
        if closed:
            print(f"{finding_id}: {decision} (closed {fu_id})")
        else:
            print(f"{finding_id}: {decision}")
            print(
                f"warning: {fu_id} not found or already closed",
                file=sys.stderr,
            )
    else:
        print(f"{finding_id}: {decision}")

    return 0


def _close_followup(
    repo: Path,
    shard: str,
    fu_id: str,
    decision: str,
) -> bool:
    fu_path = repo / ".wolf" / "follow-ups" / f"{shard}.json"
    if not fu_path.exists():
        return False

    data = json.loads(fu_path.read_text())
    closed = False
    for entry in data.get("entries", []):
        if entry["id"] == fu_id and entry.get("status") == "open":
            entry["status"] = "closed"
            entry["closed_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            entry["closed_via"] = f"triage-{decision}"
            closed = True
            break

    if closed:
        _atomic_write(fu_path, data)
    return closed


def _atomic_write(path: Path, data: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with open(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        Path(tmp).replace(path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
