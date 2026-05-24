#!/usr/bin/env -S uv run python3
"""
review_prepare.py - gather all inputs needed to spawn the reviewer agent.

Consolidates /review <shard> steps 1-5: shard lookup, charter verification,
date/sha/sha256 computation, and followup loading. Outputs a single JSON
object the orchestrating agent can pass directly to the reviewer prompt.

Usage
-----
    python3 .claude/skills/review/scripts/review_prepare.py <shard-name>

Exit codes: 0 = success (JSON on stdout), non-zero = error.
Human-readable errors go to stderr.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    """Gather all inputs needed to spawn the reviewer agent."""
    if len(sys.argv) != 2:
        print("usage: review_prepare.py <shard-name>", file=sys.stderr)
        return 1

    shard_name = sys.argv[1]
    repo = Path(__file__).resolve().parents[4]
    shards_path = repo / "design" / "reviews" / "shards.json"

    if not shards_path.exists():
        print("error: design/reviews/shards.json not found", file=sys.stderr)
        return 1

    shards = json.loads(shards_path.read_text())["shards"]
    entry = next((s for s in shards if s["name"] == shard_name), None)
    if entry is None:
        available = [s["name"] for s in shards]
        print(
            f"error: shard '{shard_name}' not found. available: {', '.join(available)}",
            file=sys.stderr,
        )
        return 1

    charter_path = repo / entry["charter"]
    if not charter_path.exists():
        print(f"error: charter file not found: {entry['charter']}", file=sys.stderr)
        print("write the charter first (see design/reviews/README.md)", file=sys.stderr)
        return 2

    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    reviewed_at = now.isoformat(timespec="seconds")
    charter_sha = hashlib.sha256(charter_path.read_bytes()).hexdigest()

    try:
        git_sha = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
            cwd=repo,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"error: git rev-parse HEAD failed: {exc}", file=sys.stderr)
        return 1

    followups: list[dict] = []
    followups_path = repo / ".wolf" / "follow-ups" / f"{shard_name}.json"
    if followups_path.exists():
        data = json.loads(followups_path.read_text())
        followups = [
            {
                "id": e["id"],
                "description": e["description"],
                "source_cycle": e["source_cycle"],
                "source_shard": e["source_shard"],
            }
            for e in data.get("entries", [])
            if e.get("status") == "open"
        ]

    output_path = f".wolf/reviews/{today}-{shard_name}.json"

    result = {
        "shard": shard_name,
        "charter_path": entry["charter"],
        "charter_sha": charter_sha,
        "globs": entry["globs"],
        "output_path": output_path,
        "git_sha": git_sha,
        "reviewed_at": reviewed_at,
        "today": today,
        "open_followups": followups,
    }

    json.dump(result, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
