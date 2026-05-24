#!/usr/bin/env -S uv run python3
"""
review_status.py - print the review rotation table.

Reads .wolf/reviews/state.json and design/reviews/shards.json, computes
days-since-last-run for each shard, and prints a box-drawn table sorted
by staleness (never-reviewed first, then oldest).

Usage
-----
    python3 .claude/skills/review/scripts/review_status.py

Output goes to stdout as a fixed-width box-drawn table.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HEADERS = ("Shard", "Last run", "Days since", "Findings", "Blast radius")


def main() -> int:
    """Print the review rotation table sorted by staleness."""
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
    rows: list[tuple[str, ...]] = []

    for shard in shards:
        name = shard["name"]
        blast = shard.get("blast_radius", "?")
        info = state.get(name)
        if info and info.get("last_run"):
            last = datetime.fromisoformat(
                info["last_run"].replace("Z", "+00:00"),
            )
            days = max(0, (now - last).days)
            date_str = last.strftime("%Y-%m-%d")
            count = str(info.get("last_finding_count", "?"))
            rows.append((name, date_str, str(days), count, blast))
        else:
            rows.append((f"{name} [never]", "never", "--", "--", blast))

    rows.sort(
        key=lambda r: (
            0 if r[1] == "never" else 1,
            -(int(r[2]) if r[2] not in ("--",) else 0),
        ),
    )

    all_rows = [HEADERS, *rows]
    widths = [max(len(r[i]) for r in all_rows) for i in range(len(HEADERS))]

    def hline(left: str, mid: str, right: str) -> str:
        return left + mid.join("─" * (w + 2) for w in widths) + right

    def row_str(row: tuple[str, ...], bold: bool = False) -> str:
        cells = [f" {row[i].ljust(widths[i])} " for i in range(len(HEADERS))]
        line = "│" + "│".join(cells) + "│"
        return f"\033[1m{line}\033[0m" if bold else line

    print(hline("┌", "┬", "┐"))
    print(row_str(HEADERS, bold=True))
    for row in rows:
        print(hline("├", "┼", "┤"))
        print(row_str(row))
    print(hline("└", "┴", "┘"))

    reviewed = sum(1 for r in rows if r[1] != "never")
    never = len(rows) - reviewed
    print()
    if never:
        print(f"{reviewed} reviewed, {never} never reviewed.")
    else:
        print(f"All {reviewed} shards reviewed.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
