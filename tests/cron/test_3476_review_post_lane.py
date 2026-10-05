"""Tests for the #3476 wiring layer (``cron.review_post_lane`` + shim + env bridge).

The guard primitive (``cron.github_review_guard``, PR #6) was delivered unwired.
These tests pin the wiring contract so the container deployment inherits a
verified chain:

1. **Lane env injection** — inside a cron lane context every child env gets
   ``HERMES_LANE``/``HERMES_HOSTNAME`` and the shim dir FIRST on ``PATH``;
   outside a lane nothing changes (interactive isolation).
2. **local.py bridge** — ``_finalize_child_env`` performs that injection for
   every spawn surface.
3. **scheduler scope** — ``_CronRunScope`` publishes/resets the lane (source
   pin + ContextVar roundtrip).
4. **argv interception** — ``gh pr review`` POST forms and ``gh api
   …/pulls/N/reviews`` POSTs route through the guard with ``GH_PATH`` pointed
   at the REAL gh (recursion-proof); GETs and views pass through; the
   ``HERMES_REVIEW_GUARD_DISABLE`` escape hatch works.
5. **Serialization** — the ``.review-post.lock`` is held for the whole guarded
   POST, and two concurrent guarded POSTs on the same SHA produce exactly ONE
   review (the no-twin proof). Disabling the lock re-opens the race — the
   mutation control that shows the LOCK, not luck, is the discriminator.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import threading
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve()
_REPO_ROOT = _HERE.parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from cron import review_post_lane as lane_mod  # noqa: E402
from cron import github_review_guard as guard  # noqa: E402


# --- Lane env injection -------------------------------------------------------


def test_lane_env_injection_sets_lane_host_and_shim_path_first():
    env = {"PATH": "/usr/bin" + os.pathsep + "/bin"}
    token = lane_mod.set_current_lane("hermes-pr-review")
    try:
        lane_mod.lane_child_env_injection(env)
    finally:
        lane_mod.reset_current_lane(token)
    assert env["HERMES_LANE"] == "hermes-pr-review"
    assert env["HERMES_HOSTNAME"].startswith("hermes@")
    assert env["PATH"].split(os.pathsep)[0] == str(lane_mod.SHIM_DIR)
    assert "/usr/bin" in env["PATH"]


def test_lane_env_injection_noop_outside_cron_lane():
    env = {"PATH": "/usr/bin"}
    lane_mod.lane_child_env_injection(env)
    assert "HERMES_LANE" not in env
    assert "HERMES_HOSTNAME" not in env
    assert env["PATH"] == "/usr/bin"


def test_lane_env_injection_respects_existing_hostname_override():
    env = {"PATH": "", "HERMES_HOSTNAME": "deployment-label"}
    token = lane_mod.set_current_lane("hermes-inbox-poll")
    try:
        lane_mod.lane_child_env_injection(env)
    finally:
        lane_mod.reset_current_lane(token)
    assert env["HERMES_HOSTNAME"] == "deployment-label"


def test_finalize_child_env_bridges_lane():
    from tools.environments.local import _finalize_child_env
    env = {"PATH": "/usr/bin"}
    token = lane_mod.set_current_lane("hermes-pr-review")
    try:
        out = _finalize_child_env(env)
    finally:
        lane_mod.reset_current_lane(token)
    assert out["HERMES_LANE"] == "hermes-pr-review"
    assert out["PATH"].split(os.pathsep)[0] == str(lane_mod.SHIM_DIR)


def test_finalize_child_env_untouched_without_lane():
    from tools.environments.local import _finalize_child_env
    env = {"PATH": "/usr/bin"}
    out = _finalize_child_env(env)
    assert "HERMES_LANE" not in out


def test_scheduler_scope_publishes_lane(monkeypatch):
    """_CronRunScope sets the lane ContextVar from job['name'] and exit() resets it.

    Instantiating the full scope drags gateway/session machinery; the wiring is
    pinned at source level (same style as the fleet's static pins) plus a
    ContextVar roundtrip for the primitive itself.
    """
    src = (_REPO_ROOT / "cron" / "scheduler.py").read_text(encoding="utf-8")
    assert "set_current_lane(str(job.get(\"name\") or job_id))" in src
    assert "reset_current_lane(self._review_lane_token)" in src
    src_local = (_REPO_ROOT / "tools" / "environments" / "local.py").read_text(
        encoding="utf-8")
    assert "_inject_cron_lane_env(env)" in src_local
    token = lane_mod.set_current_lane("hermes-pr-review")
    assert lane_mod.current_lane() == "hermes-pr-review"
    lane_mod.reset_current_lane(token)
    assert lane_mod.current_lane() is None


# --- argv parsing ---------------------------------------------------------------


def test_parse_pr_review_body_file_approve(tmp_path):
    body_file = tmp_path / "review.md"
    body_file.write_text("Verdict: LGTM-side.", encoding="utf-8")
    intent = lane_mod.parse_gh_pr_review(
        ["pr", "review", "14807", "--repo", "jsboige/CoursIA",
         "--body-file", str(body_file), "--approve"])
    assert intent is not None
    assert (intent.owner, intent.repo, intent.pr_number) == ("jsboige", "CoursIA", 14807)
    assert intent.body == "Verdict: LGTM-side."
    assert intent.event == "APPROVE"
    assert intent.commit_sha is None  # resolved by the guard


def test_parse_pr_review_inline_body_comment_default(tmp_path):
    intent = lane_mod.parse_gh_pr_review(
        ["pr", "review", "-R", "o/r", "-b", "note", "42"])
    assert intent is not None and intent.event == "COMMENT"
    assert intent.body == "note"


def test_parse_pr_review_interactive_form_not_a_post():
    assert lane_mod.parse_gh_pr_review(["pr", "review", "42", "-R", "o/r"]) is None
    assert lane_mod.parse_gh_pr_review(["pr", "view", "42"]) is None
    assert lane_mod.parse_gh_pr_review(["pr"]) is None


def test_parse_pr_review_branch_without_repo_unparseable():
    # branch target and no -R: cannot resolve confidently → pass through
    assert lane_mod.parse_gh_pr_review(["pr", "review", "wt/foo", "-b", "x"]) is None


def test_parse_api_post_with_input(tmp_path):
    payload = tmp_path / "payload.json"
    payload.write_text(json.dumps(
        {"body": "b", "event": "REQUEST_CHANGES", "commit_id": "a" * 40}),
        encoding="utf-8")
    intent = lane_mod.parse_gh_api_post_reviews(
        ["api", "repos/jsboige/CoursIA/pulls/14863/reviews",
         "--input", str(payload)])
    assert intent is not None
    assert intent.pr_number == 14863 and intent.event == "REQUEST_CHANGES"
    assert intent.commit_sha == "a" * 40


def test_parse_api_explicit_post_method():
    intent = lane_mod.parse_gh_api_post_reviews(
        ["api", "-X", "POST", "repos/o/r/pulls/9/reviews", "-f", "body=text"])
    assert intent is not None and intent.body == "text"


def test_parse_api_get_and_other_endpoints_pass_through():
    assert lane_mod.parse_gh_api_post_reviews(
        ["api", "repos/o/r/pulls/9/reviews", "--jq", ".[].body"]) is None
    assert lane_mod.parse_gh_api_post_reviews(
        ["api", "repos/o/r/issues/9/comments", "-f", "body=x"]) is None


# --- Interception routing --------------------------------------------------------


class _Recorder:
    def __init__(self):
        self.calls = []


def _fake_post_result(posted=True, reason="posted", stdout='{"id": 1}\n'):
    return guard.PostResult(
        posted=posted, reason=reason, commit_id="sha", body_with_marker="b",
        elapsed_s=0.01, review_id=1 if posted else None, stdout=stdout, stderr="")


@pytest.fixture()
def gh_env(monkeypatch, tmp_path):
    """Isolated env: fake real gh, no leftover lane vars."""
    monkeypatch.setattr(lane_mod, "resolve_real_gh", lambda: "/usr/bin/gh")
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes-home"))
    monkeypatch.delenv("HERMES_LANE", raising=False)
    return monkeypatch


def test_intercept_pr_review_routes_through_guard(gh_env, tmp_path, capsys, monkeypatch):
    rec = _Recorder()

    def fake_post(owner, repo, n, body, event, **kw):
        rec.calls.append((owner, repo, n, body, event, kw.get("lane")))
        return _fake_post_result()

    monkeypatch.setattr(guard, "post_review", fake_post)
    body_file = tmp_path / "b.md"
    body_file.write_text("content", encoding="utf-8")
    rc = lane_mod.maybe_intercept(
        ["pr", "review", "15", "--repo", "o/r", "--body-file", str(body_file)])
    assert rc == 0
    assert rec.calls == [("o", "r", 15, "content", "COMMENT", None)]
    # The guard must target the REAL gh — recursion-proof wiring.
    assert os.environ.get("GH_PATH") == "/usr/bin/gh"
    assert '{"id": 1}' in capsys.readouterr().out


def test_intercept_api_post_with_commit_sha_skips_head_lookup(gh_env, tmp_path, monkeypatch):
    rec = _Recorder()

    def fake_post_unique(owner, repo, n, sha, body, event, **kw):
        rec.calls.append((n, sha, event))
        return _fake_post_result()

    monkeypatch.setattr(guard, "post_review_if_unique", fake_post_unique)
    payload = tmp_path / "p.json"
    payload.write_text(json.dumps({"body": "b", "commit_id": "c" * 40}), encoding="utf-8")
    rc = lane_mod.maybe_intercept(
        ["api", "repos/o/r/pulls/9/reviews", "--input", str(payload)])
    assert rc == 0
    assert rec.calls == [(9, "c" * 40, "COMMENT")]


def test_intercept_skip_duplicate_is_not_an_error(gh_env, tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(
        guard, "post_review",
        lambda *a, **k: _fake_post_result(
            posted=False, reason="skipped_duplicate", stdout=""))
    body_file = tmp_path / "b.md"
    body_file.write_text("x", encoding="utf-8")
    rc = lane_mod.maybe_intercept(
        ["pr", "review", "15", "-R", "o/r", "-F", str(body_file), "--approve"])
    assert rc == 0
    err = capsys.readouterr().err
    assert "SKIP_DUP" in err and "twin prevented" in err


def test_passthrough_for_view_and_get(gh_env):
    assert lane_mod.maybe_intercept(["pr", "view", "42", "--repo", "o/r"]) is None
    assert lane_mod.maybe_intercept(
        ["api", "repos/o/r/pulls/42/reviews", "--jq", ".[].id"]) is None


def test_disable_escape_hatch_is_pure_passthrough(gh_env, monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_REVIEW_GUARD_DISABLE", "1")
    body_file = tmp_path / "b.md"
    body_file.write_text("x", encoding="utf-8")
    assert lane_mod.maybe_intercept(
        ["pr", "review", "15", "-R", "o/r", "--body-file", str(body_file)]) is None


def test_resolve_real_gh_excludes_shim_dir(monkeypatch):
    seen = {}
    real_which = shutil.which

    def spy(name, path=None):
        seen["path"] = path
        return real_which(name, path=path)

    monkeypatch.setattr(shutil, "which", spy)
    monkeypatch.setenv(
        "PATH",
        os.pathsep.join([str(lane_mod.SHIM_DIR), "/usr/local/bin", "/usr/bin"]))
    lane_mod.resolve_real_gh()
    parts = seen["path"].split(os.pathsep)
    assert str(lane_mod.SHIM_DIR) not in parts


def test_shim_exec_passes_through_via_execv(monkeypatch):
    calls = []
    monkeypatch.setattr(lane_mod, "resolve_real_gh", lambda: "/usr/bin/gh")
    monkeypatch.setattr(os, "execv", lambda p, argv: calls.append((p, argv)))
    rc = lane_mod.shim_exec(["pr", "view", "42"])
    assert calls == [("/usr/bin/gh", ["/usr/bin/gh", "pr", "view", "42"])]
    assert rc == 127  # execv (stubbed) returned — real execv never does


# --- Serialization / no-twin proof -----------------------------------------------


def test_post_lock_held_for_whole_guarded_post(gh_env, tmp_path, monkeypatch):
    home = tmp_path / "hermes-home"
    lock_states = []

    def fake_post(owner, repo, n, body, event, **kw):
        fd = os.open(str(home / "cron" / ".review-post.lock"),
                     os.O_RDWR | os.O_CREAT, 0o644)
        held = not lane_mod._try_lock_nonblocking(fd)
        if held:
            os.close(fd)
        else:
            lane_mod._unlock(fd)
        lock_states.append(held)
        return _fake_post_result()

    monkeypatch.setattr(guard, "post_review", fake_post)
    rc = lane_mod.maybe_intercept(["pr", "review", "1", "-R", "o/r", "-b", "x"])
    assert rc == 0 and lock_states == [True]


def test_tick_lock_busy_does_not_block(gh_env, tmp_path):
    home = tmp_path / "hermes-home"
    (home / "cron").mkdir(parents=True)
    fd = os.open(str(home / "cron" / ".tick.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    assert lane_mod._try_lock_nonblocking(fd)  # simulate a running sync tick
    try:
        with lane_mod.serialize_review_post(hermes_home=home) as locks:
            assert locks.held_post and not locks.held_tick
    finally:
        lane_mod._unlock(fd)


@pytest.mark.skipif(os.name != "posix", reason="shebang stub gh execs on POSIX only")
def test_two_lanes_same_sha_exactly_one_posted(tmp_path, monkeypatch):
    """No-twin proof, end to end against a stub gh.

    With the lock: the second lane's GET-reviews sees the first lane's POST and
    SKIP_DUPs — exactly one review lands. With the lock disabled (mutation
    control): both lanes POST — proving the serialization lock, not luck, is
    the discriminator.
    """
    stub_gh = tmp_path / "stub-gh"
    stub_gh.write_text(
        "#!/bin/sh\n"
        '# $2 == api: reviews GET (count) or POST (--input payload)\n'
        '# otherwise: gh pr view → head SHA\n'
        'case "$1" in\n'
        '  api) ;;\n'
        '  *) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; exit 0 ;;\n'
        "esac\n"
        'if echo "$@" | grep -q " -X POST"; then\n'
        '  prev=""; PAY=""\n'
        '  for a in "$@"; do\n'
        '    if [ "$prev" = "--input" ]; then PAY="$a"; fi\n'
        '    prev="$a"\n'
        "  done\n"
        '  cat "$PAY" >> reviews.json; printf "\\n" >> reviews.json\n'
        '  cat "$PAY"\n'
        '  exit 0\n'
        "fi\n"
        'if echo "$@" | grep -q "/reviews"; then\n'
        '  sleep 0.3\n'  # widen the window so the unlocked race interleaves
        '  grep -c deadbeef reviews.json 2>/dev/null || true\n'
        '  exit 0\n'
        "fi\n"
        'echo "stub-gh: unhandled api call" >&2; exit 1\n',
        encoding="utf-8")
    stub_gh.chmod(0o755)

    def run_two_lanes(lock_enabled: bool) -> int:
        (tmp_path / "reviews.json").write_text("", encoding="utf-8")
        monkeypatch.setenv("GH_PATH", str(stub_gh))
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        monkeypatch.setenv("HERMES_LANE", "hermes-pr-review")
        monkeypatch.delenv("HERMES_REVIEW_POST_LOCK_DISABLE", raising=False)
        if not lock_enabled:
            monkeypatch.setenv("HERMES_REVIEW_POST_LOCK_DISABLE", "1")
        monkeypatch.chdir(tmp_path)  # stub writes/reads reviews.json in cwd
        results = []

        def lane() -> None:
            results.append(lane_mod.maybe_intercept(
                ["pr", "review", "77", "-R", "o/r", "-b", "review body"]))

        t1 = threading.Thread(target=lane)
        t2 = threading.Thread(target=lane)
        t1.start(); t2.start(); t1.join(); t2.join()
        assert all(rc == 0 for rc in results), results
        return (tmp_path / "reviews.json").read_text(encoding="utf-8").count('"body"')

    assert run_two_lanes(lock_enabled=True) == 1
    assert run_two_lanes(lock_enabled=False) == 2


@pytest.mark.skipif(os.name != "posix", reason="shebang stub gh execs on POSIX only")
def test_posted_payload_carries_lane_attribution_marker(tmp_path, monkeypatch):
    stub_gh = tmp_path / "stub-gh"
    stub_gh.write_text(
        "#!/bin/sh\n"
        'if echo "$@" | grep -q " -X POST"; then\n'
        '  prev=""; PAY=""\n'
        '  for a in "$@"; do\n'
        '    if [ "$prev" = "--input" ]; then PAY="$a"; fi\n'
        '    prev="$a"\n'
        "  done\n"
        '  cp "$PAY" posted-payload.json\n'
        '  cat "$PAY"\n'
        '  exit 0\n'
        "fi\n"
        'if echo "$@" | grep -q "/reviews"; then echo 0; exit 0; fi\n'
        'echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"\n',
        encoding="utf-8")
    stub_gh.chmod(0o755)
    monkeypatch.setenv("GH_PATH", str(stub_gh))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_LANE", "hermes-pr-review")
    monkeypatch.setenv("HERMES_HOSTNAME", "hermes@test-host")
    monkeypatch.chdir(tmp_path)
    rc = lane_mod.maybe_intercept(
        ["pr", "review", "77", "-R", "o/r", "-b", "review body"])
    assert rc == 0
    payload = json.loads((tmp_path / "posted-payload.json").read_text(encoding="utf-8"))
    markers = [line for line in payload["body"].splitlines()
               if line.startswith("[Hermes ")]
    assert len(markers) == 1
    assert markers[0].startswith("[Hermes hermes-pr-review, cycle :")
    assert markers[0].endswith(", host hermes@test-host]")
    assert "review body" in payload["body"]
