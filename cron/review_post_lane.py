"""#3476 wiring layer: lane attribution env + deterministic gh review-POST interception.

Live call-site inventory (2026-09-15, ``~/.hermes/cron/jobs.json`` on po-2026):
only the ``hermes-pr-review`` lane (hourly :23) POSTs GitHub reviews from the
container. ``hermes-inbox-poll``, ``hermes-cluster-tour`` and ``hermes-self-check``
never POST reviews — the ``github_review_guard`` module docstring overstates the
call-site set. The interception is nonetheless installed for **every** cron lane
(PATH level), so a lane that starts POSTing tomorrow is covered with zero code
change.

Wiring chain (deterministic, prompt-independent):

1. ``cron.scheduler._CronRunScope`` publishes the lane name on a ContextVar
   (``set_current_lane``) for the whole ``run_job`` scope.
2. ``tools.environments.local._finalize_child_env`` bridges that ContextVar
   into every child-process env the job's agent spawns: ``HERMES_LANE``,
   ``HERMES_HOSTNAME``, and the ``cron/shim`` directory FIRST on ``PATH``.
   Outside a cron run the var is unset → interactive chats / CLI are untouched.
3. ``cron/shim/gh`` (a python script with shebang, executable bit committed)
   intercepts review-POST invocations — ``gh pr review …`` and
   ``gh api …/pulls/<N>/reviews`` with a POST method — and routes them through
   :func:`cron.github_review_guard.post_review` under the serialization locks
   below. Every other invocation ``exec``s the real ``gh`` untouched.

Serialization (#3476 — closing the twin window): the guard's single ``sh -c``
GET+POST still has a kernel-schedulable gap between its two ``gh`` processes.
This module closes it **between concurrent guard instances** with
``~/.hermes/cron/.review-post.lock`` (flock/msvcrt, bounded blocking): when two
lanes race, the second one's GET-reviews runs after the first one's POST and
sees the review → ``SKIP_DUP``. The canonical ``~/.hermes/cron/.tick.lock`` is
additionally taken with a single non-blocking attempt when free (the guard
module's docstring contract); it is never waited on because a synchronous tick
holds it for the whole job pool — a job-agent shim blocking on it would
self-deadlock until every sibling job finishes.

Recursion safety: the shim resolves the REAL ``gh`` (first ``gh`` on ``PATH``
excluding the shim dir) and exports it as ``GH_PATH`` for the guard, whose own
subprocesses then bypass the shim.

Escape hatches (ops levers, no image rollback needed):

- ``HERMES_REVIEW_GUARD_DISABLE=1`` — shim becomes a pure pass-through.
- ``HERMES_REVIEW_POST_LOCK_DISABLE=1`` — POST proceeds without the dedicated
  serialization lock (diagnostic only; re-opens the twin window).
"""

from __future__ import annotations

import contextlib
import contextvars
import json
import logging
import os
import re
import shutil
import socket
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows
    fcntl = None
try:
    import msvcrt
except ImportError:  # pragma: no cover - POSIX
    msvcrt = None

logger = logging.getLogger(__name__)

SHIM_DIR = Path(__file__).resolve().parent / "shim"

_POST_LOCK_NAME = ".review-post.lock"
_TICK_LOCK_NAME = ".tick.lock"
_POST_LOCK_TIMEOUT_S = float(os.environ.get("HERMES_REVIEW_POST_LOCK_TIMEOUT", "30"))
_TICK_RETRY_HINT_S = 0.0  # tick lock is single-shot non-blocking by design (see docstring)

_lane_var: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    "hermes_cron_review_lane", default=None)


# --- Lane context (set by cron.scheduler._CronRunScope) ---------------------


def set_current_lane(name: str):
    """Publish the cron lane name for this run; returns a reset token."""
    return _lane_var.set(name or "cron-unnamed")


def reset_current_lane(token) -> None:
    _lane_var.reset(token)


def current_lane() -> Optional[str]:
    return _lane_var.get()


def _path_key(env: dict) -> str:
    return "Path" if "Path" in env else "PATH"


def lane_child_env_injection(env: dict) -> None:
    """Mutate *env* (a child-process env dict) for the active cron lane.

    Sets ``HERMES_LANE``, defaults ``HERMES_HOSTNAME`` to
    ``hermes@<hostname>`` (an existing value wins — deployment override), and
    prepends the shim dir to ``PATH`` so any ``gh`` the agent invokes resolves
    to the guarded shim. No-op when no lane context is active.
    """
    lane = current_lane()
    if not lane:
        return
    env["HERMES_LANE"] = lane
    env.setdefault("HERMES_HOSTNAME", f"hermes@{socket.gethostname().strip() or 'unknown'}")
    key = _path_key(env)
    parts = [p for p in env.get(key, "").split(os.pathsep) if p]
    if parts and Path(parts[0]).resolve() == SHIM_DIR:
        return
    env[key] = os.pathsep.join([str(SHIM_DIR)] + parts) if parts else str(SHIM_DIR)


# --- Serialization locks -----------------------------------------------------


def _hermes_home() -> Path:
    try:
        from hermes_constants import get_hermes_home
        return Path(get_hermes_home())
    except Exception:
        return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def _try_lock_nonblocking(fd) -> bool:
    if fcntl is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False
    if msvcrt is not None:
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            return False
    return False  # pragma: no cover - no locking primitive available


def _unlock(fd) -> None:
    with contextlib.suppress(OSError):
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_UN)
        elif msvcrt is not None:
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    with contextlib.suppress(OSError):
        os.close(fd)


@dataclass(slots=True)
class ReviewPostLocks:
    held_post: bool
    held_tick: bool


@contextlib.contextmanager
def serialize_review_post(*, hermes_home: Optional[Path] = None):
    """Hold ``.review-post.lock`` (blocking, bounded) + best-effort ``.tick.lock``.

    The dedicated POST lock is the deterministic twin-killer (see module
    docstring). The tick lock is attempted exactly once without blocking — a
    sync tick holds it for the whole job pool, so waiting here would deadlock
    the very job whose POST we are guarding.
    """
    home = Path(hermes_home) if hermes_home else _hermes_home()
    cron_dir = home / "cron"
    with contextlib.suppress(OSError):
        cron_dir.mkdir(parents=True, exist_ok=True)

    post_fd: Optional[int] = None
    if os.environ.get("HERMES_REVIEW_POST_LOCK_DISABLE") != "1":
        deadline = time.monotonic() + _POST_LOCK_TIMEOUT_S
        while post_fd is None:
            fd = os.open(str(cron_dir / _POST_LOCK_NAME),
                         os.O_RDWR | os.O_CREAT, 0o644)
            if _try_lock_nonblocking(fd):
                post_fd = fd
                break
            os.close(fd)
            if time.monotonic() >= deadline:
                logger.error(
                    "review_post_lane: .review-post.lock contention exceeded "
                    "%.0fs — proceeding WITHOUT the serialization lock", _POST_LOCK_TIMEOUT_S)
                break
            time.sleep(0.1)

    tick_fd: Optional[int] = None
    try:
        fd = os.open(str(cron_dir / _TICK_LOCK_NAME),
                     os.O_RDWR | os.O_CREAT, 0o644)
        if _try_lock_nonblocking(fd):
            tick_fd = fd
        else:
            os.close(fd)
        yield ReviewPostLocks(held_post=post_fd is not None, held_tick=tick_fd is not None)
    finally:
        if tick_fd is not None:
            _unlock(tick_fd)
        if post_fd is not None:
            _unlock(post_fd)


# --- gh argv parsing ---------------------------------------------------------


@dataclass(slots=True)
class ReviewPostIntent:
    owner: str
    repo: str
    pr_number: int
    body: str
    event: str = "COMMENT"
    commit_sha: Optional[str] = None  # None → resolve current head via gh


_REVIEWS_ENDPOINT_RE = re.compile(
    r"^(?:https?://[^/]+/)?(?:api\.[^/]+/)?(?:repos/)?"
    r"(?P<owner>[A-Za-z0-9_.-]+)/(?P<repo>[A-Za-z0-9_.-]+)/pulls/(?P<n>\d+)/reviews/?$"
)
_PR_URL_RE = re.compile(r"/pull/(\d+)")


def _flag_value(argv: Sequence[str], *names: str) -> Optional[str]:
    for i, arg in enumerate(argv):
        if arg in names:
            return argv[i + 1] if i + 1 < len(argv) else None
        for n in names:
            pref = n + "="
            if arg.startswith(pref):
                return arg[len(pref):]
    return None


def _has_flag(argv: Sequence[str], *names: str) -> bool:
    return any(a == n or a.startswith(n + "=") for a in argv for n in names)


def parse_gh_pr_review(argv: Sequence[str]) -> Optional[ReviewPostIntent]:
    """Parse a POST-bearing ``gh pr review`` invocation; None when not a POST.

    A bare ``gh pr review <n>`` with no body and no verdict flag opens an
    interactive editor — not a confidently-parseable POST, so it is left to the
    real gh (which fails on a non-tty anyway).
    """
    if len(argv) < 2 or argv[0] != "pr" or argv[1] != "review":
        return None
    rest = list(argv[2:])
    body: Optional[str] = None
    repo_arg: Optional[str] = None
    filtered: list[str] = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--body", "-b"):
            body = rest[i + 1] if i + 1 < len(rest) else ""
            i += 2
        elif a.startswith("--body="):
            body = a[len("--body="):]
            i += 1
        elif a in ("--body-file", "-F"):
            path = rest[i + 1] if i + 1 < len(rest) else ""
            if path == "-":
                body = sys.stdin.read()
            else:
                try:
                    body = Path(path).read_text(encoding="utf-8")
                except OSError as exc:
                    print(f"gh-shim: cannot read --body-file {path}: {exc}",
                          file=sys.stderr)
                    raise SystemExit(1)
            i += 2
        elif a.startswith("--body-file="):
            path = a[len("--body-file="):]
            body = Path(path).read_text(encoding="utf-8")
            i += 1
        elif a in ("--repo", "-R"):
            repo_arg = rest[i + 1] if i + 1 < len(rest) else None
            i += 2  # flag + value: keep both out of the positional scan
        else:
            filtered.append(a)
            i += 1

    event = "COMMENT"
    if _has_flag(filtered, "--approve", "-a"):
        event = "APPROVE"
    elif _has_flag(filtered, "--request-changes", "-r"):
        event = "REQUEST_CHANGES"
    positional = [a for a in filtered if not a.startswith("-")]

    if body is None and event == "COMMENT":
        return None  # interactive form — not a parseable POST
    repo = repo_arg or os.environ.get("GH_REPO")
    owner = repo_name = None
    if repo and repo.count("/") == 1:
        owner, repo_name = repo.split("/", 1)
    pr_number: Optional[int] = None
    if positional:
        p0 = positional[0]
        if p0.isdigit():
            pr_number = int(p0)
        else:
            m = _PR_URL_RE.search(p0)
            if m:
                pr_number = int(m.group(1))
    if pr_number is None or owner is None:
        return None  # branch target / repo-less — leave to real gh + WARN
    return ReviewPostIntent(owner=owner, repo=repo_name, pr_number=pr_number,
                            body=body or "", event=event)


def parse_gh_api_post_reviews(argv: Sequence[str]) -> Optional[ReviewPostIntent]:
    """Parse ``gh api …/pulls/<N>/reviews`` with a POST-ish method; None otherwise."""
    if not argv or argv[0] != "api":
        return None
    rest = list(argv[1:])
    # Positional scan that skips flag VALUES (-X POST, -f body=x, -H …):
    # a naive "not startswith('-')" scan reads POST/--input paths as positionals.
    value_flags = ("-X", "--method", "--input", "-f", "-F", "--field",
                   "--raw-field", "-H", "--header", "--hostname", "--jq")
    positional: list[str] = []
    skip_next = False
    for a in rest:
        if skip_next:
            skip_next = False
            continue
        if a in value_flags:
            skip_next = True
            continue
        if not a.startswith("-"):
            positional.append(a)
    if not positional:
        return None
    m = _REVIEWS_ENDPOINT_RE.match(positional[0])
    if not m:
        return None
    method = (_flag_value(rest, "-X", "--method") or "").upper()
    postish = (
        method == "POST"
        or _has_flag(rest, "--input")
        or _has_flag(rest, "-f", "-F", "--field", "--raw-field")
    )
    if not postish:
        return None  # plain GET — pass through

    payload: dict = {}
    input_path = _flag_value(rest, "--input")
    if input_path and input_path != "-":
        try:
            payload = json.loads(Path(input_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"gh-shim: cannot parse --input {input_path}: {exc}",
                  file=sys.stderr)
            raise SystemExit(1)
    else:
        # -f/-F/--field/--raw-field, two-token ("flag key=value") and
        # single-token ("flag=key=value") forms alike.
        field_flags = ("-f", "-F", "--field", "--raw-field")
        i = 0
        while i < len(rest):
            a = rest[i]
            kv: Optional[str] = None
            if a in field_flags and i + 1 < len(rest):
                kv = rest[i + 1]
                i += 2
            else:
                for f in field_flags:
                    pref = f + "="
                    if a.startswith(pref):
                        kv = a[len(pref):]
                        break
                i += 1
            if kv and "=" in kv:
                k, v = kv.split("=", 1)
                payload[k] = v
    if not isinstance(payload, dict):
        return None
    event = str(payload.get("event") or "COMMENT").upper()
    if event not in ("COMMENT", "APPROVE", "REQUEST_CHANGES"):
        event = "COMMENT"
    return ReviewPostIntent(
        owner=m.group("owner"), repo=m.group("repo"), pr_number=int(m.group("n")),
        body=str(payload.get("body") or ""), event=event,
        commit_sha=(str(payload["commit_id"]) if payload.get("commit_id") else None) or None,
    )


# --- Shim entry ---------------------------------------------------------------


def resolve_real_gh() -> Optional[str]:
    """First ``gh`` on PATH that is NOT the shim itself."""
    key = _path_key(dict(os.environ)) if os.environ else "PATH"
    raw = os.environ.get(key) or os.environ.get("PATH") or ""
    parts = [p for p in raw.split(os.pathsep) if p]
    try:
        shim_resolved = SHIM_DIR.resolve()
        parts = [p for p in parts if Path(p).resolve() != shim_resolved]
    except OSError:
        pass
    return shutil.which("gh", path=os.pathsep.join(parts))


def maybe_intercept(argv: Sequence[str]) -> Optional[int]:
    """Route a review-POST gh invocation through the guard.

    Returns an exit code when the invocation was handled (POST attempted,
    skipped or failed), or ``None`` when the caller must exec the real gh.
    """
    if os.environ.get("HERMES_REVIEW_GUARD_DISABLE") == "1":
        return None
    intent = parse_gh_pr_review(argv) or parse_gh_api_post_reviews(argv)
    if intent is None:
        return None

    real_gh = resolve_real_gh()
    if not real_gh:
        print("gh-shim: no real gh resolvable on PATH (excluding shim dir) — "
              "cannot guard this POST", file=sys.stderr)
        return 1
    os.environ["GH_PATH"] = real_gh  # guard + its subprocesses bypass the shim

    from cron import github_review_guard as guard

    with serialize_review_post():
        if intent.commit_sha:
            result = guard.post_review_if_unique(
                intent.owner, intent.repo, intent.pr_number, intent.commit_sha,
                intent.body, intent.event)
        else:
            result = guard.post_review(
                intent.owner, intent.repo, intent.pr_number,
                intent.body, intent.event)

    lane = os.environ.get("HERMES_LANE", "?")
    if result.posted:
        sys.stdout.write(result.stdout or "")
        print(f"gh-shim: review POSTed via #3476 guard "
              f"[lane {lane}, review_id={result.review_id}]",
              file=sys.stderr)
        return 0
    if result.reason == "skipped_duplicate":
        print(f"SKIP_DUP: a review already exists on the same SHA — "
              f"twin prevented [lane {lane}]", file=sys.stderr)
        print(f"{{\"gh_shim\": \"skip_duplicate\", \"lane\": \"{lane}\"}}")
        return 0
    print(f"gh-shim: guarded POST failed: {result.stderr.strip()[:400]}",
          file=sys.stderr)
    return 1


def shim_exec(argv: Sequence[str]) -> int:
    rc = maybe_intercept(argv)
    if rc is not None:
        return rc
    real_gh = resolve_real_gh()
    if not real_gh:
        print("gh-shim: gh not found on PATH", file=sys.stderr)
        return 127
    os.execv(real_gh, [real_gh] + list(argv))  # never returns
    return 127  # pragma: no cover - execv failed on this platform
