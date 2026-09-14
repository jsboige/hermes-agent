"""Tests for ``cron.github_review_guard`` (issue #3476 atomic guard).

Coverage goals:

1. **Attribution marker is appended exactly once**, with the right
   lane / host / cycle format, and is idempotent across calls.
2. **The guard's subprocess is one ``sh -c`` call**, not two — the
   atomicity invariant that closes the race window (datapoint #15 §4
   shows only 6/46 cron POSTs were atomic before this module shipped).
3. **GET-reviews skipping** is honored: when the ``gh api`` GET returns
   a list containing a same-``commit_id`` entry, the POST is NOT issued.
4. **GET-reviews empty** path: POST is issued with the payload file
   contents, and the response is parsed for the review id.
5. **Pre-existing GitHub errors** (subprocess non-zero) surface as
   :class:`PostResult` with ``posted=False, reason="error"`` and never
   raise — the guard is fail-closed but never throws into the cron tick.
6. **Cycle label format** matches the convention documented in
   datapoint #16 §2 (interactive Hermes po-2026 tracked lane).
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from unittest import mock

import pytest

# Make the worktree importable when the test runner is invoked from the repo
# root or from ``tests/``.  ``tests/cron/__init__.py`` is empty so we add the
# repo root explicitly.
_HERE = Path(__file__).resolve()
_REPO_ROOT = _HERE.parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from cron import github_review_guard as guard  # noqa: E402


# --- Attribution marker ----------------------------------------------------


def test_append_attribution_marker_basic_format():
    body = "Verdict: LGTM-side. Table impact recomputed."
    out = guard.append_attribution_marker(
        body,
        lane="hermes-pr-review",
        host="myia-po-2026",
        cycle=":07 06/09",
    )
    assert "[Hermes hermes-pr-review, cycle :07 06/09, host myia-po-2026]" in out
    # The marker is the LAST non-blank line in the body.
    assert out.rstrip().endswith(
        "[Hermes hermes-pr-review, cycle :07 06/09, host myia-po-2026]"
    )


def test_append_attribution_marker_idempotent_when_already_marked():
    body = "Body text\n\n[Hermes foo, cycle :07 06/09, host bar]\n"
    out = guard.append_attribution_marker(
        body,
        lane="other-lane",
        host="other-host",
        cycle=":08 06/09",
    )
    # No second marker line, original marker preserved verbatim.
    markers = re.findall(r"\[Hermes[^\]]*\]", out)
    assert len(markers) == 1
    assert markers[0] == "[Hermes foo, cycle :07 06/09, host bar]"


def test_append_attribution_marker_handles_empty_body():
    out = guard.append_attribution_marker(
        "", lane="L", host="H", cycle=":01 01/01"
    )
    assert "[Hermes L, cycle :01 01/01, host H]" in out


def test_append_attribution_marker_default_lane_and_host(monkeypatch):
    monkeypatch.setenv("HERMES_LANE", "hermes-inbox-poll")
    monkeypatch.setenv("HERMES_HOSTNAME", "myia-po-2026-container")
    out = guard.append_attribution_marker("hello")
    assert "[Hermes hermes-inbox-poll," in out
    assert "host myia-po-2026-container]" in out


def test_cycle_label_format_matches_datapoint16():
    """Datapoint #16 §2: tracked Hermes uses ``:XX DD/MM`` cycle markers."""
    fixed = _dt.datetime(2026, 9, 13, 21, 7, 32, tzinfo=_dt.timezone.utc)
    assert guard._cycle_label(now=fixed) == ":21 13/09"


# --- Atomicity invariant ---------------------------------------------------


def test_atomic_invoking_uses_one_sh_subprocess(monkeypatch):
    """The atomic guard issues ONE ``sh -c`` call, not two."""
    captured: list[tuple] = []

    class _FakeCompleted:
        def __init__(self, returncode=0, stdout="{}", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    def _fake_run(cmd, **kwargs):
        captured.append((tuple(cmd), kwargs))
        return _FakeCompleted(stdout='{"id": 999}')

    monkeypatch.setattr(guard.subprocess, "run", _fake_run)
    monkeypatch.setattr(guard.shutil, "which", lambda _: "/usr/bin/gh")

    guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict LGTM-side",
        lane="L", host="H", cycle=":01 01/01",
    )

    # Exactly one subprocess invocation — the atomic sh -c call.
    assert len(captured) == 1, (
        f"guard must invoke ONE subprocess; saw {len(captured)}"
    )
    cmd, kwargs = captured[0]
    assert cmd[0] == "sh"
    assert cmd[1] == "-c"
    # The shell snippet must contain BOTH the GET-reviews and the POST.
    snippet = cmd[2]
    assert "/reviews" in snippet
    assert "X POST" in snippet
    # timeout is forwarded so a hung gh doesn't block the cron tick.
    assert "timeout" in kwargs


# --- Subprocess dispatch: skip vs post -------------------------------------


def _run_with(monkeypatch, *, returncode, stdout, stderr=""):
    monkeypatch.setattr(guard.shutil, "which", lambda _: "/usr/bin/gh")

    def _fake_run(cmd, **kwargs):
        class _C:
            pass

        c = _C()
        c.returncode = returncode
        c.stdout = stdout
        c.stderr = stderr
        return c

    monkeypatch.setattr(guard.subprocess, "run", _fake_run)


def test_skip_when_duplicate_review_exists(monkeypatch):
    _run_with(monkeypatch, returncode=0, stdout="SKIP_DUP:2\n")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "skipped_duplicate"
    assert result.commit_id == (
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4"
    )
    # Attribution marker is still appended for downstream logs even on skip.
    assert "[Hermes L," in result.body_with_marker


def test_post_when_no_duplicate(monkeypatch):
    payload = {"id": 5124644669, "commit_id": "38287ac4"}
    _run_with(monkeypatch, returncode=0, stdout=json.dumps(payload))
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True
    assert result.reason == "posted"
    assert result.review_id == 5124644669


def test_subprocess_nonzero_returns_error_not_raises(monkeypatch):
    _run_with(
        monkeypatch, returncode=1,
        stdout="",
        stderr="gh: API request failed (404)",
    )
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "error"
    assert "404" in result.stderr


# --- Validation -----------------------------------------------------------


def test_invalid_event_raises_value_error():
    with pytest.raises(ValueError):
        guard.post_review_if_unique(
            "o", "r", 1, "deadbeef", "b", event="BANANA",
        )


def test_missing_gh_binary_raises_runtime_error(monkeypatch):
    monkeypatch.setattr(guard.shutil, "which", lambda _: None)
    with pytest.raises(RuntimeError, match="gh.*not on PATH"):
        guard.post_review_if_unique(
            "o", "r", 1, "deadbeef", "b",
        )


# --- Convenience wrapper --------------------------------------------------


def test_post_review_resolves_head_and_delegates(monkeypatch):
    """``post_review`` looks up headRefOid then calls the guard."""
    calls: list[tuple] = []

    def _fake_run(cmd, **kwargs):
        calls.append((tuple(cmd), kwargs))

        class _C:
            returncode = 0

        c = _C()
        # First call: gh pr view -> head SHA.
        # Second call: sh -c atomic snippet -> POST.
        if cmd and cmd[0] == "gh" and "pr" in cmd and "view" in cmd:
            c.stdout = "38287ac491cc8b9edcd792a6b4856e6e377dcba4\n"
        else:
            c.stdout = json.dumps({"id": 1001})
        c.stderr = ""
        return c

    monkeypatch.setattr(guard.subprocess, "run", _fake_run)
    monkeypatch.setattr(guard.shutil, "which", lambda _: "/usr/bin/gh")

    result = guard.post_review(
        "jsboige", "CoursIA", 14863, "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True
    assert result.review_id == 1001
    # Two subprocess calls: head lookup + atomic POST.
    assert len(calls) == 2
    # First call resolves the PR head SHA via `gh pr view`.
    assert calls[0][0][0].endswith("gh")
    assert list(calls[0][0][1:4]) == ["pr", "view", "14863"]
    # Second call is the atomic sh -c snippet.
    assert calls[1][0][0] == "sh"
    assert calls[1][0][1] == "-c"


def test_post_review_propagates_head_lookup_failure(monkeypatch):
    def _fake_run(cmd, **kwargs):
        class _C:
            returncode = 1
            stdout = ""
            stderr = "gh: not found"
        return _C()

    monkeypatch.setattr(guard.subprocess, "run", _fake_run)
    monkeypatch.setattr(guard.shutil, "which", lambda _: "/usr/bin/gh")

    result = guard.post_review(
        "jsboige", "CoursIA", 14863, "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "error"
    assert "not found" in result.stderr