"""
Pure-function unit tests for the /second-opinion reviewer-model choice.

Covers ``premium_globs`` and ``choose_model`` in ``review_brief.py``.

Run via ``uv run pytest`` (or ``make test-unit``, which includes it).
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_SCRIPT = (
    Path(__file__).resolve().parents[2]
    / ".claude/skills/second-opinion/scripts/review_brief.py"
)
_spec = importlib.util.spec_from_file_location("review_brief", _SCRIPT)
assert _spec and _spec.loader
review_brief = importlib.util.module_from_spec(_spec)
sys.modules["review_brief"] = review_brief
_spec.loader.exec_module(review_brief)

BRIEF = """# Brief

## Premium review triggers

Some prose with a `backticked_word` that is not a glob.

- `.assets/lib/certs.sh`
- `.assets/provision/*`

## Known patterns - do NOT flag

- `not/a/trigger.sh`
"""
GLOBS = [".assets/lib/certs.sh", ".assets/provision/*"]


def test_premium_globs_reads_only_its_section():
    """Globs come only from the triggers section, not other backticks."""
    assert review_brief.premium_globs(BRIEF) == GLOBS


def test_premium_globs_empty_without_section():
    """A brief without the section yields no triggers."""
    assert review_brief.premium_globs("# Brief\n\n## Focus areas\n") == []


@pytest.mark.parametrize(
    ("numstat", "model"),
    [
        ("10\t2\t.assets/lib/nx_scope.sh\n", review_brief.DEFAULT_MODEL),
        ("1\t0\t.assets/lib/certs.sh\n", review_brief.PREMIUM_MODEL),
        # `*` crosses directories, so a nested file under a trigger dir counts
        ("3\t1\t.assets/provision/sub/install_x.sh\n", review_brief.PREMIUM_MODEL),
        # docs and binaries never count toward the size threshold
        (
            f"{review_brief.COMPLEX_LINES + 1}\t0\tdocs/big.md\n-\t-\timg.bin\n",
            review_brief.DEFAULT_MODEL,
        ),
        (f"{review_brief.COMPLEX_LINES}\t1\tsrc/big.sh\n", review_brief.PREMIUM_MODEL),
        ("", review_brief.DEFAULT_MODEL),
    ],
)
def test_choose_model(numstat, model):
    """Trigger paths and the size threshold both select the premium model."""
    assert review_brief.choose_model(numstat, GLOBS)["model"] == model


def test_choose_model_reports_reasons():
    """The result names the trigger path and counts code lines."""
    result = review_brief.choose_model("1\t0\t.assets/lib/certs.sh\n", GLOBS)
    assert result["reasons"] == ["touches trigger paths: .assets/lib/certs.sh"]
    assert result["code_lines"] == 1
