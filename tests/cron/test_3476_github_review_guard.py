"""Tests for ``cron.github_review_guard`` (issue #3476 guard module).

The module is **unwired** (no lane calls it yet — wiring is follow-up work
in the po-2026 container). These tests pin its contract so the future wiring
inherits a verified primitive:

1. **Attribution marker is appended exactly once**, with the right
   lane / host / cycle format, idempotent only for a *full* marker at the
   **end** of the body (a mid-body quote, a bare ``[Hermes]``, or a partial
   marker must not suppress the fresh one).
2. **The guard's subprocess is one ``sh -c`` call** — and that call is
   exercised for real against a stub ``gh`` that records its arguments
   (issue #3476 review: the mock-only tests never ran the shell).
3. **Paginated counting** sums per-page jq results with ``awk`` (gh >=
   2.100 rejects ``--slurp`` with ``--jq``): two pages with zero matching
   review must NOT false-skip the POST.
4. **GET-reviews skipping** is honored: a same-``commit_id`` review means
   the POST is not issued.
5. **Fail-closed**: subprocess errors surface as :class:`PostResult` with
   ``posted=False, reason="error"`` and never raise into the cron tick.
6. ``GH_PATH`` override is honored, and ``elapsed_s`` is measured.
7. **Short SHAs are resolved** to the full 40-char OID before the guarded
   shell (datapoint #18 §3, roo-extensions #3476: a truncated
   ``commit_id`` 422s the POST and silently disables the GET dedup).
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import shutil
import stat
import sys
from pathlib import Path

import pytest

# Make the worktree importable when the test runner is invoked from the repo
# root or from ``tests/``.  ``tests/cron/__init__.py`` is empty so we add the
# repo root explicitly.
_HERE = Path(__file__).resolve()
_REPO_ROOT = _HERE.parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from cron import github_review_guard as guard  # noqa: E402

_HAS_SH = shutil.which("sh") is not None


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


def test_marker_not_suppressed_by_mid_body_quote():
    """A quoted ``[Hermes …]`` line in the middle of the body is NOT the
    fresh marker — idempotency must not be fooled by a citation/template."""
    body = (
        "> prior review said:\n"
        "> [Hermes quoted-lane, cycle :07 06/09, host quoted-host]\n"
        "\n"
        "New verdict text."
    )
    out = guard.append_attribution_marker(
        body, lane="L", host="H", cycle=":09 09/09"
    )
    assert out.rstrip().endswith("[Hermes L, cycle :09 09/09, host H]")
    assert "[Hermes quoted-lane, cycle :07 06/09, host quoted-host]" in out


def test_marker_not_suppressed_by_bare_hermes_tag():
    """``[Hermes]`` alone at the end lacks lane/cycle/host — not a marker."""
    body = "Verdict text\n\n[Hermes]"
    out = guard.append_attribution_marker(
        body, lane="L", host="H", cycle=":09 09/09"
    )
    assert out.rstrip().endswith("[Hermes L, cycle :09 09/09, host H]")


def test_marker_not_suppressed_when_fields_missing():
    """A partial marker (no host) at the end must not block the real one."""
    body = "Verdict text\n\n[Hermes some-lane, cycle :01 01/01]"
    out = guard.append_attribution_marker(
        body, lane="L", host="H", cycle=":09 09/09"
    )
    assert out.rstrip().endswith("[Hermes L, cycle :09 09/09, host H]")


# --- Single-subprocess invariant -------------------------------------------


def test_atomic_invoking_uses_one_sh_subprocess(monkeypatch):
    """The guard issues ONE ``sh -c`` call, not two."""
    monkeypatch.delenv("GH_PATH", raising=False)
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

    # Exactly one subprocess invocation — the single sh -c call.
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
    # The verified gh path is passed through as the snippet's $3.
    assert cmd[6] == "/usr/bin/gh"
    # timeout is forwarded so a hung gh doesn't block the cron tick.
    assert "timeout" in kwargs


# --- Subprocess dispatch: skip vs post -------------------------------------


def _run_with(monkeypatch, *, returncode, stdout, stderr=""):
    monkeypatch.delenv("GH_PATH", raising=False)
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
    monkeypatch.delenv("GH_PATH", raising=False)
    monkeypatch.setattr(guard.shutil, "which", lambda _: None)
    with pytest.raises(RuntimeError, match="GH_PATH"):
        guard.post_review_if_unique(
            "o", "r", 1, "deadbeef", "b",
        )


def test_gh_path_env_is_honored(monkeypatch):
    """``GH_PATH`` wins over ``PATH`` and must actually be resolved."""

    def _boom(_):
        raise AssertionError(
            "shutil.which must not be consulted when GH_PATH is set"
        )

    monkeypatch.setenv("GH_PATH", "/opt/fake/gh")
    monkeypatch.setattr(guard.shutil, "which", _boom)
    assert guard._require_gh() == "/opt/fake/gh"


# --- Real-shell execution against a stub gh --------------------------------

_STUB_GH = r"""#!/bin/sh
# Stub gh for the #3476 guard tests. Emulates gh's --paginate semantics:
#  - GET -> per-page jq results; $GH_STUB_COUNT per page (def 0), the
#    snippet's awk sum must aggregate them into a single integer
#  - POST              -> records the --input payload, emits a review JSON
# Every invocation's argv is appended to $GH_STUB_LOG (one arg per line,
# "---CALL---" separators).
printf '%s\n' "---CALL---" >> "$GH_STUB_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$GH_STUB_LOG"; done
case " $* " in
  *" user "*)
    # Account-identity probe (gh api user --jq .login). GH_STUB_LOGIN is the
    # login to report; GH_STUB_LOGIN_FAIL=1 simulates an auth/network
    # failure (exit 1 -> the guarded shell dies under set -eu -> refusal).
    if [ -n "${GH_STUB_LOGIN_FAIL:-}" ]; then
      echo "stub api user failure" >&2
      exit 1
    fi
    echo "${GH_STUB_LOGIN:-jsboige}"
    exit 0
    ;;
  *" -X POST "*)
    if [ -n "${GH_STUB_SLEEP:-}" ]; then sleep "$GH_STUB_SLEEP"; fi
    if [ -n "${GH_STUB_POST_FAIL:-}" ]; then
      echo "stub POST failure" >&2
      exit 1
    fi
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--input" ] && [ -n "${GH_STUB_PAYLOAD_COPY:-}" ]; then
        cp "$a" "$GH_STUB_PAYLOAD_COPY"
      fi
      prev="$a"
    done
    echo '{"id": 424242}'
    exit 0
    ;;
  *"/commits/"*)
    # SHA-resolution lookup (short sha -> full OID), datapoint #18 §3.
    echo "${GH_STUB_FULL_SHA:-}"
    exit 0
    ;;
  *)
    # GET reviews: per-page jq results, two pages -> lines. $GH_STUB_COUNT
    # (when > 0) is emitted on each page so the awk sum sees it twice.
    n="${GH_STUB_COUNT:-0}"
    i=0
    while [ "$i" -lt 2 ]; do
      printf '%s\n' "$n"
      i=$((i+1))
    done
    exit 0
    ;;
esac
"""


@pytest.fixture()
def stub_gh(tmp_path, monkeypatch):
    """Install a recording ``gh`` stub and point ``GH_PATH`` at it."""
    stub = tmp_path / "gh-stub.sh"
    log = tmp_path / "gh-calls.log"
    payload_copy = tmp_path / "posted-payload.json"
    stub.write_text(_STUB_GH, encoding="utf-8", newline="\n")
    log.write_text("", encoding="utf-8")
    os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)
    monkeypatch.setenv("GH_STUB_LOG", str(log))
    monkeypatch.setenv("GH_STUB_PAYLOAD_COPY", str(payload_copy))
    monkeypatch.setenv("GH_PATH", str(stub).replace("\\", "/"))
    monkeypatch.delenv("GH_STUB_COUNT", raising=False)
    monkeypatch.delenv("GH_STUB_SLEEP", raising=False)
    monkeypatch.delenv("GH_STUB_POST_FAIL", raising=False)
    monkeypatch.delenv("GH_STUB_FULL_SHA", raising=False)
    monkeypatch.setenv("HERMES_EXPECTED_LOGIN", "jsboige")
    monkeypatch.delenv("GH_STUB_LOGIN", raising=False)
    monkeypatch.delenv("GH_STUB_LOGIN_FAIL", raising=False)

    class _Stub:
        def __init__(self):
            self.log = log
            self.payload_copy = payload_copy

        def calls(self):
            """List of argv lists, one per recorded invocation."""
            out: list[list[str]] = []
            for block in self.log.read_text(encoding="utf-8").split(
                "---CALL---\n"
            ):
                if block.strip():
                    out.append(block.splitlines())
            return out

    return _Stub()


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_real_snippet_posts_with_stub_gh(stub_gh, monkeypatch):
    """End-to-end through the real ``sh -c`` snippet (issue #3476 review
    blocker 1): the POST must actually be reachable, must use ``--input``
    (``--input-file`` does not exist in ``gh``), and must carry the payload
    from the tempfile."""
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict LGTM-side",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True, f"reason={result.reason!r} stderr={result.stderr!r}"
    assert result.reason == "posted"
    assert result.review_id == 424242

    calls = stub_gh.calls()
    assert len(calls) == 3, f"expected identity + GET + POST, saw {calls}"
    id_args, get_args, post_args = calls
    # Identity probe: gh api user, before any review traffic.
    assert "user" in id_args
    assert "--jq" in id_args
    # GET: reviews endpoint, paginated; per-page counts summed by awk.
    assert "/repos/jsboige/CoursIA/pulls/14863/reviews" in get_args
    assert "--paginate" in get_args
    assert "--slurp" not in get_args  # gh >= 2.100 rejects --slurp with --jq
    # POST: reviews endpoint via --input (the only real gh flag).
    assert "/repos/jsboige/CoursIA/pulls/14863/reviews" in post_args
    assert "--input" in post_args
    assert "--input-file" not in post_args
    # The payload tempfile carried the body WITH the attribution marker.
    payload = json.loads(stub_gh.payload_copy.read_text(encoding="utf-8"))
    assert payload["body"].rstrip().endswith(
        "[Hermes L, cycle :01 01/01, host H]"
    )
    assert payload["commit_id"] == (
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4"
    )


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_real_snippet_two_pages_zero_match_still_posts(stub_gh, monkeypatch):
    """Issue #3476 review blocker 2: two pages with zero matching review
    must NOT false-skip. The stub emits the per-page results ``0\\n0`` on
    every GET — the exact shape that makes a naive ``[ "$N" != "0" ]``
    comparison true — so this test fails if the awk sum is dropped from the
    snippet. It also pins the gh >= 2.100 regression: ``--slurp`` combined
    with ``--jq`` is rejected by real gh, so the snippet must aggregate
    without it."""
    monkeypatch.setenv("GH_STUB_COUNT", "0")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True, (
        f"false SKIP on two empty pages: reason={result.reason!r} "
        f"stdout={result.stdout!r}"
    )
    assert result.reason == "posted"
    # Aggregation is awk-side: --slurp must NOT appear (gh >= 2.100 rejects
    # --slurp with --jq, which would make every real call fail-closed).
    assert "--slurp" not in stub_gh.calls()[0]


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_real_snippet_skips_when_aggregated_count_nonzero(stub_gh, monkeypatch):
    monkeypatch.setenv("GH_STUB_COUNT", "2")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "skipped_duplicate"
    # Two pages x count 2 -> awk sum 4 (per-page counts are summed, not
    # concatenated: "2\n2" must aggregate to 4, not read as a duplicate
    # string).
    assert result.stdout.strip() == "SKIP_DUP:4"
    # No POST call was issued at all (identity probe + GET only).
    assert len(stub_gh.calls()) == 2
    assert not any(
        "-X" in c and "POST" in c for c in stub_gh.calls()
    )


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_real_snippet_elapsed_s_is_measured(stub_gh, monkeypatch):
    """``elapsed_s`` must be measured, not a hardcoded ``0.0``."""
    monkeypatch.setenv("GH_STUB_SLEEP", "0.3")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True
    assert result.elapsed_s >= 0.2, f"elapsed_s={result.elapsed_s!r}"


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_real_snippet_post_failure_is_fail_closed(stub_gh, monkeypatch):
    monkeypatch.setenv("GH_STUB_POST_FAIL", "1")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "error"
    assert "stub POST failure" in result.stderr


# --- Short-SHA resolution (datapoint #18 §3) ---------------------------------

_FULL382 = "38287ac491cc8b9edcd792a6b4856e6e377dcba4"


def test_short_commit_sha_is_resolved_not_passed_through(monkeypatch):
    """A 12-char SHA (the 17/09 00:26Z burst shape) is resolved to the full
    40-char OID via a commits lookup BEFORE the guarded shell — both the
    GET-match and the POST ``commit_id`` must use the full OID (a truncated
    commit_id 422s on POST and never matches the dedup)."""
    monkeypatch.delenv("GH_PATH", raising=False)
    calls: list[tuple] = []

    def _fake_run(cmd, **kwargs):
        calls.append(tuple(cmd))

        class _C:
            pass

        c = _C()
        c.stderr = ""
        if any("/commits/" in a for a in cmd):  # the resolution lookup
            c.returncode = 0
            c.stdout = _FULL382 + "\n"
        else:  # the guarded sh - c
            c.returncode = 0
            c.stdout = json.dumps({"id": 777})
        return c

    monkeypatch.setattr(guard.subprocess, "run", _fake_run)
    monkeypatch.setattr(guard.shutil, "which", lambda _: "/usr/bin/gh")

    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863, "38287ac491cc",
        "verdict", lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True
    assert result.commit_id == _FULL382
    # Resolution targeted the commits endpoint with the SHORT sha.
    assert "/repos/jsboige/CoursIA/commits/38287ac491cc" in calls[0]
    # The guarded shell received the FULL sha as its $2 (cmd index 5).
    assert calls[1][5] == _FULL382


def test_short_sha_resolution_failure_fails_closed(monkeypatch):
    """Unresolvable short SHA -> PostResult error and the guarded POST is
    never issued (fail-closed; the lane must not fall into an unguarded
    POST for this cause)."""
    monkeypatch.delenv("GH_PATH", raising=False)
    calls: list[tuple] = []

    def _fake_run(cmd, **kwargs):
        calls.append(tuple(cmd))

        class _C:
            pass

        c = _C()
        c.returncode = 1
        c.stdout = ""
        c.stderr = "gh: Not Found (HTTP 404)"
        return c

    monkeypatch.setattr(guard.subprocess, "run", _fake_run)
    monkeypatch.setattr(guard.shutil, "which", lambda _: "/usr/bin/gh")

    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863, "38287ac491cc",
        "verdict", lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "error"
    assert "could not be resolved" in result.stderr
    assert "404" in result.stderr
    # Only the resolution lookup ran — no sh -c, no POST.
    assert len(calls) == 1


def test_non_hex_commit_sha_raises_value_error():
    with pytest.raises(ValueError):
        guard.post_review_if_unique(
            "jsboige", "CoursIA", 14863, "not-a-sha!", "verdict",
        )


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_real_snippet_short_sha_resolved_via_stub(stub_gh, monkeypatch):
    """End-to-end through the real shell: the resolution lookup runs via the
    stub gh, and BOTH the GET-reviews dedup match and the POST payload carry
    the FULL OID."""
    monkeypatch.setenv("GH_STUB_FULL_SHA", _FULL382)
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863, "38287ac491cc",
        "verdict LGTM-side", lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True, (
        f"reason={result.reason!r} stderr={result.stderr!r}"
    )
    calls = stub_gh.calls()
    assert len(calls) == 4, (
        f"expected resolve + identity + GET + POST, saw {calls}"
    )
    resolve_args, _id_args, get_args, post_args = calls
    assert "/repos/jsboige/CoursIA/commits/38287ac491cc" in resolve_args
    # GET dedup jq matches on the FULL OID — a short sha would never match.
    # (The jq program embeds the OID inside its select() — substring check.)
    assert any(_FULL382 in a for a in get_args)
    assert "--input" in post_args
    payload = json.loads(stub_gh.payload_copy.read_text(encoding="utf-8"))
    assert payload["commit_id"] == _FULL382


# --- Convenience wrapper --------------------------------------------------


def test_post_review_resolves_head_and_delegates(monkeypatch):
    """``post_review`` looks up headRefOid then calls the guard."""
    monkeypatch.delenv("GH_PATH", raising=False)
    calls: list[tuple] = []

    def _fake_run(cmd, **kwargs):
        calls.append((tuple(cmd), kwargs))

        class _C:
            returncode = 0

        c = _C()
        # First call: gh pr view -> head SHA. NB: cmd[0] is the RESOLVED
        # gh path (e.g. "/usr/bin/gh") — an equality check on "gh" never
        # matched and this branch silently returned review JSON as the
        # head SHA, which only passed under the old lenient validation.
        # Second call: sh -c guarded snippet -> POST.
        if (cmd and cmd[0].endswith("gh") and "pr" in cmd
                and "view" in cmd):
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
    # Two subprocess calls: head lookup + guarded POST.
    assert len(calls) == 2
    # First call resolves the PR head SHA via `gh pr view`.
    assert calls[0][0][0].endswith("gh")
    assert list(calls[0][0][1:4]) == ["pr", "view", "14863"]
    # Second call is the guarded sh -c snippet.
    assert calls[1][0][0] == "sh"
    assert calls[1][0][1] == "-c"


def test_post_review_propagates_head_lookup_failure(monkeypatch):
    monkeypatch.delenv("GH_PATH", raising=False)

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


# --- Signed markers (#3476 follow-up: forge-resistant attribution) ---------

# Hermeticity: every pre-existing test asserts the exact UNSIGNED marker
# string. Once the module signs whenever a key is loadable, those assertions
# would depend on whether the host running the tests holds the container key
# file (/opt/data/hermes-ops/guard/attribution.key exists in the po-2026
# container). Pin the env override to a guaranteed-missing path by default;
# tests that WANT a key use the ``attribution_key`` fixture below, which
# overrides this after setup (autouse fixtures instantiate first).
@pytest.fixture(autouse=True)
def _no_attribution_key_by_default(tmp_path, monkeypatch):
    absent = tmp_path / "absent-attribution.key"
    monkeypatch.setenv("HERMES_ATTRIBUTION_KEY", str(absent).replace("\\", "/"))


# Account-identity guard: every shell-exercising test needs an expected
# login (the guard fails closed without one). jsboige is also the stub's
# default reported login, so the identity check passes by default; the
# refusal tests below override either side.
@pytest.fixture(autouse=True)
def _expected_login_by_default(monkeypatch):
    monkeypatch.setenv("HERMES_EXPECTED_LOGIN", "jsboige")


@pytest.fixture()
def attribution_key(_no_attribution_key_by_default, tmp_path, monkeypatch):
    key = tmp_path / "attribution.key"
    key.write_text("ab" * 32, encoding="utf-8")  # 32 bytes — deploy shape
    monkeypatch.setenv("HERMES_ATTRIBUTION_KEY", str(key).replace("\\", "/"))
    return key


def test_signed_marker_appended_when_key_present(attribution_key):
    out = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    assert re.search(r"\[Hermes L, cycle :05 27/09, host H, sig=[0-9a-f]{8}\]$",
                     out.rstrip())
    verdict = guard.verify_attribution(out, pr=42, sha="a" * 40)
    assert verdict.marker_present and verdict.signed
    assert verdict.key_available and verdict.signature_valid
    assert verdict.lane == "L" and verdict.cycle == ":05 27/09"
    assert verdict.host == "H"


def test_verify_rejects_replay_on_other_pr_or_sha(attribution_key):
    """The anti-replay property: pr/sha are MAC inputs, not line content —
    a marker copied to another PR/commit fails verification."""
    out = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=1, sha="a" * 40,
    )
    assert not guard.verify_attribution(out, pr=2, sha="a" * 40).signature_valid
    assert not guard.verify_attribution(out, pr=1, sha="b" * 40).signature_valid
    # Omitting the MAC'd pr/sha also mismatches (empty vs original fields).
    assert not guard.verify_attribution(out).signature_valid


def test_missing_key_degrades_to_unsigned(tmp_path, monkeypatch):
    monkeypatch.setenv(
        "HERMES_ATTRIBUTION_KEY",
        str(tmp_path / "never-created.key").replace("\\", "/"),
    )
    out = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    assert out.rstrip().endswith("[Hermes L, cycle :05 27/09, host H]")
    verdict = guard.verify_attribution(out, pr=42, sha="a" * 40)
    assert verdict.marker_present and not verdict.signed


def test_garbage_key_degrades_to_unsigned_never_raises(tmp_path, monkeypatch):
    short = tmp_path / "too-short.key"
    short.write_text("abcde", encoding="utf-8")  # < 16 bytes
    monkeypatch.setenv("HERMES_ATTRIBUTION_KEY", str(short).replace("\\", "/"))
    out = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    assert "sig=" not in out


def test_signed_marker_is_idempotent(attribution_key):
    once = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    twice = guard.append_attribution_marker(
        once, lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    assert once == twice
    assert len(re.findall(r"\[Hermes[^\]]*\]", twice)) == 1


def test_legacy_unsigned_marker_not_upgraded_in_place(attribution_key):
    """A body already ending with a pre-signing marker stays verbatim — the
    guard never edits an existing body, it only appends when absent."""
    legacy = "body\n\n[Hermes L, cycle :05 27/09, host H]\n"
    out = guard.append_attribution_marker(
        legacy, lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    assert out == legacy
    verdict = guard.verify_attribution(out, pr=42, sha="a" * 40)
    assert verdict.marker_present and not verdict.signed


def test_verify_without_key_reports_unverifiable_not_forged(
        attribution_key, tmp_path, monkeypatch):
    """Sweeping from a host without the key: signed marker, no local key →
    key_available=False. That means CANNOT verify — distinct from an
    actually-invalid signature."""
    signed = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    monkeypatch.setenv(
        "HERMES_ATTRIBUTION_KEY",
        str(tmp_path / "absent-here.key").replace("\\", "/"),
    )
    verdict = guard.verify_attribution(signed, pr=42, sha="a" * 40)
    assert verdict.signed and not verdict.key_available
    assert not verdict.signature_valid


def test_tampered_signature_is_invalid(attribution_key):
    signed = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )
    m = re.search(r"sig=([0-9a-f]{8})", signed)
    flipped = "0" if m.group(1)[0] != "0" else "1"
    tampered = signed.replace(
        m.group(0), f"sig={flipped}{m.group(1)[1:]}"
    )
    verdict = guard.verify_attribution(tampered, pr=42, sha="a" * 40)
    assert verdict.signed and verdict.key_available
    assert not verdict.signature_valid


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_post_path_signs_resolved_full_oid(stub_gh, attribution_key,
                                           monkeypatch):
    """End-to-end: short-SHA input + key present → the POSTed marker's sig
    verifies against the PR number and the RESOLVED full OID (MAC over a
    truncated SHA would never verify on sweep)."""
    monkeypatch.setenv("GH_STUB_FULL_SHA", _FULL382)
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863, "38287ac491cc",
        "verdict LGTM-side", lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is True, (
        f"reason={result.reason!r} stderr={result.stderr!r}"
    )
    payload = json.loads(stub_gh.payload_copy.read_text(encoding="utf-8"))
    verdict = guard.verify_attribution(
        payload["body"], pr=14863, sha=_FULL382,
    )
    assert verdict.signed and verdict.signature_valid
    # The sig was computed over the FULL OID, not the short input.
    assert not guard.verify_attribution(
        payload["body"], pr=14863, sha="38287ac491cc",
    ).signature_valid


def test_cli_verify_marker_exit_codes(attribution_key, monkeypatch, capsys):
    import io as _io

    good = guard.append_attribution_marker(
        "body", lane="L", host="H", cycle=":05 27/09", pr=42, sha="a" * 40,
    )

    def _run(body, *argv):
        monkeypatch.setattr("sys.stdin", _io.StringIO(body))
        code = guard._cli_verify_marker(list(argv))
        out = capsys.readouterr().out
        return code, json.loads(out)

    code, v = _run(good, "--pr", "42", "--sha", "a" * 40)
    assert code == 0 and v["signature_valid"] is True

    code, v = _run("body\n\n[Hermes L, cycle :05 27/09, host H]\n")
    assert code == 1 and v["signed"] is False

    code, v = _run("no marker at all")
    assert code == 3 and v["marker_present"] is False

    def _flip(mo):
        first = mo.group(1)[0]
        return "sig=" + ("0" if first != "0" else "1") + mo.group(1)[1:]

    tampered = re.sub(r"sig=([0-9a-f]{8})", _flip, good)
    code, v = _run(tampered, "--pr", "42", "--sha", "a" * 40)
    assert code == 2 and v["signature_valid"] is False


# --- Account-identity guard (#3476 datapoint #24, bot rule #3032) ----------


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_real_snippet_refuses_when_login_mismatches(stub_gh, monkeypatch):
    """A stray `gh auth switch` flips the active login: the POST must be
    refused with the observed login surfaced, and NOTHING sent — not even
    the GET-reviews probe (identity is checked first)."""
    monkeypatch.setenv("GH_STUB_LOGIN", "someone-else")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "refused_account"
    assert result.observed_login == "someone-else"
    # Exactly one gh call — the identity probe. No GET, no POST.
    calls = stub_gh.calls()
    assert len(calls) == 1, f"identity probe only expected, saw {calls}"
    assert not any("-X" in c and "POST" in c for c in calls)
    # No payload was ever written by a POST.
    assert not stub_gh.payload_copy.exists()


def test_no_expected_login_fails_closed_before_any_traffic(
    stub_gh, monkeypatch
):
    """HERMES_EXPECTED_LOGIN unset + expected_login not passed → refuse
    BEFORE any subprocess: zero gh calls, distinct stderr. A wiring without
    the env cannot post silently."""
    monkeypatch.delenv("HERMES_EXPECTED_LOGIN", raising=False)
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "refused_account"
    assert result.observed_login is None
    assert "HERMES_EXPECTED_LOGIN" in result.stderr
    # Fail-closed is pre-shell: not even the identity probe ran.
    assert stub_gh.calls() == []


def test_expected_login_param_overrides_env(stub_gh, monkeypatch):
    """The explicit parameter wins over the env — callers holding their own
    expectation (e.g. a sweep replaying a historical lane) keep it."""
    monkeypatch.setenv("GH_STUB_LOGIN", "historical-account")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
        expected_login="historical-account",
    )
    assert result.posted is True, (
        f"reason={result.reason!r} stderr={result.stderr!r}"
    )


@pytest.mark.skipif(not _HAS_SH, reason="sh not on PATH")
def test_api_user_failure_refuses_instead_of_posting(stub_gh, monkeypatch):
    """`gh api user` failing (auth expiry, network) exits non-zero under
    set -eu: the shell dies, reason=error — an unverifiable identity is
    never posted under."""
    monkeypatch.setenv("GH_STUB_LOGIN_FAIL", "1")
    result = guard.post_review_if_unique(
        "jsboige", "CoursIA", 14863,
        "38287ac491cc8b9edcd792a6b4856e6e377dcba4",
        "verdict",
        lane="L", host="H", cycle=":01 01/01",
    )
    assert result.posted is False
    assert result.reason == "error"
    calls = stub_gh.calls()
    assert not any("-X" in c and "POST" in c for c in calls)
