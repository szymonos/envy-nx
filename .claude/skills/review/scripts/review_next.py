#!/usr/bin/env -S uv run python3
"""
review_next.py - pick the next shard to review.

Reads .wolf/reviews/state.json and design/reviews/shards.json, picks the
shard with the oldest last_run (never-reviewed first, ties broken by
blast_radius descending). Prints the shard name to stdout.

Usage
-----
    python3 .claude/skills/review/scripts/review_next.py

Exit codes: 0 = success (shard name on stdout), 1 = error.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BLAST_ORDER = {"high": 3, "medium": 2, "low": 1}


def main() -> int:
    """Pick the next shard to review based on staleness and blast radius."""
    repo = Path(__file__).resolve().parents[4]
    shards_path = repo / "design" / "reviews" / "shards.json"
    state_path = repo / ".wolf" / "reviews" / "state.json"

    if not shards_path.exists():
        print("error: design/reviews/shards.json not found", file=sys.stderr)
        return 1

    shards = json.loads(shards_path.read_text())["shards"]
    state = {}
    if state_path.exists():
        state = json.loads(state_path.read_text()).get("shards", {})

    now = datetime.now(timezone.utc)
    candidates: list[tuple[int, int, str]] = []

    for shard in shards:
        name = shard["name"]
        blast = BLAST_ORDER.get(shard.get("blast_radius", "low"), 0)
        info = state.get(name)
        if info and info.get("last_run"):
            last = datetime.fromisoformat(info["last_run"].replace("Z", "+00:00"))
            age = int((now - last).total_seconds())
            candidates.append((0, -blast, name))  # reviewed: sort by blast desc
            candidates[-1] = (age, -blast, name)  # older = higher priority
        else:
            candidates.append((999_999_999, -blast, name))  # never reviewed

    if not candidates:
        print(
            "error: no shards configured in design/reviews/shards.json", file=sys.stderr
        )
        return 1

    candidates.sort(key=lambda c: (-c[0], c[1]))
    print(candidates[0][2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
