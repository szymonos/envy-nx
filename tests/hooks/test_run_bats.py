"""Unit tests for the interrupt handling in ``run_bats.py``."""

from __future__ import annotations

import run_bats  # pytest prepends this directory to sys.path


def test_no_child_starts_after_kill_live(tmp_path, monkeypatch):
    """A worker that reaches Popen after Ctrl-C cleanup must not start a child."""
    monkeypatch.setattr(run_bats, "_CANCELLED", False)
    marker = tmp_path / "started"

    run_bats._kill_live()
    proc = run_bats._run(["touch", str(marker)], env={}, capture=True)

    assert proc.returncode == 130
    assert not marker.exists()
    assert not run_bats._LIVE
