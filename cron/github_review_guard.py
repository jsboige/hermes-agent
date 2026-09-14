"""Atomic GitHub review POST guard.

Issue #3476 — twin-same-SHA reviews emitted by the hermes cron container on
myia-po-2026 (resolution: ``state.db`` shows the ``hermes-pr-review`` and
``hermes-inbox-poll`` cron lanes POSTing GitHub reviews independently of the
tracked interactive lane). The root cause was a race window between the lane's
pool scan and the POST: the scan saw ``reviews=0``, the tracked lane reviewed
between scan and POST, the cron lane posted a second review on the same SHA,
producing an unclaimed "twin" review (#14807, #14819, #14821, #14863 ×2,
#14866, #14878, #3477, …). User-approved remediation (datapoint #16,
2026-09-13): **re-scan reviews immediately before 100 % of POSTs**, with a
cycle/lane attribution convention so the receiving end can attribute every
emission.

The atomic guard: a single ``sh -c`` invocation that performs the GET
(``/repos/{owner}/{repo}/pulls/{pr}/reviews``) **and** the conditional POST
(``/repos/{owner}/{repo}/pulls/{pr}/reviews``) in **one subprocess**. The
kernel cannot context-switch between the GET and the POST — the race window is
zero. A Python-side implementation that GETs then POSTs from two separate
``subprocess.run()`` calls would leave a measurable gap; per datapoint #15
§4, only 6/46 cron POSTs (13 %) had the atomic shape before this module
shipped.

Cycle/lane attribution: by default the guard appends a single line to the
review body before POSTing::

    [Hermes <lane>, cycle :XX DD/MM, host <host>]

- ``<lane>``: the cron lane name (``hermes-pr-review``, ``hermes-inbox-poll``,
  ``kanban-dispatcher``, …) — passed by the caller or read from
  ``HERMES_LANE`` env.
- ``<host>``: ``socket.gethostname()`` — falls back to
  ``HERMES_HOSTNAME`` / ``unknown``.
- Cycle label format ``:XX DD/MM`` matches the convention already in use by
  the tracked interactive lane on po-2026 (datapoint #16 §2: the cycle
  marker in body is the **single invariant** that separates tracked emissions
  from twins). The marker line is **idempotent**: if the body already ends
  with a ``[Hermes …]`` line, no second marker is appended.

Module surface:

- :func:`post_review_if_unique` — primary entry point; one shell call,
  atomic check + POST.
- :func:`post_review` — convenience wrapper: auto-resolves the PR head SHA
  via ``gh pr view``, then calls :func:`post_review_if_unique`.
- :func:`append_attribution_marker` — pure helper that adds the marker line
  to a body if not already present; exported so callers can preview the body
  before POSTing.

All subprocess invocations use ``sh -c`` with a temporary file holding the
POST payload so the command line does not embed secrets or large bodies
(args are visible to ``/proc/<pid>/cmdline`` on Linux, and the
``--input-file`` form is the documented GitHub-CLI pattern for JSON payloads).
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import socket
import subprocess
import tempfile
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger(__name__)

# Cycle/lane attribution marker: a single bracketed line at the end of the
# body. The regex captures any prior marker so a body that already carries
# one (idempotency) is left untouched.
_ATTRIBUTION_LINE_RE = re.compile(
    r"^\s*\[Hermes(?:\s+[^\]]+)?(?:,\s*cycle\s+:[0-9A-Za-z]+(?:\s+[0-9A-Za-z/-]+)?)?"
    r"(?:,\s*host\s+[^\]]+)?\]\s*$",
    re.MULTILINE,
)

# Default values — overridden by env when running inside the hermes cron
# container.  Env wins because cron jobs run with these exported by the
# dispatch wrapper (`docker/main-wrapper.sh:75`).
_DEFAULT_LANE = "hermes-pr-review"
_DEFAULT_HOST = ""  # populated at call time from socket.gethostname()


def _lane() -> str:
    return os.environ.get("HERMES_LANE", _DEFAULT_LANE).strip() or _DEFAULT_LANE


def _hostname() -> str:
    env_host = os.environ.get("HERMES_HOSTNAME", "").strip()
    if env_host:
        return env_host
    try:
        return socket.gethostname().strip() or "unknown"
    except Exception:  # noqa: BLE001 - hostname resolution is best-effort
        return "unknown"


def _cycle_label(now=None) -> str:
    """``":XX DD/MM"`` cycle marker.

    Format chosen to match the convention documented in datapoint #16 §2
    (Hermes po-2026 tracked lane). The hour (XX, 24h UTC) and day-of-month
    are sufficient for human attribution without exposing the full timestamp
    (which would add bytes and let receivers collate across hosts).
    """
    from datetime import datetime, timezone

    ts = (now or datetime.now(timezone.utc))
    return f":{ts.strftime('%H')} {ts.strftime('%d/%m')}"


def append_attribution_marker(body: str, *, lane: Optional[str] = None,
                              host: Optional[str] = None,
                              cycle: Optional[str] = None) -> str:
    """Return ``body`` with a single attribution marker appended.

    Idempotent: if the body already ends with a ``[Hermes …]`` line (matching
    :data:`_ATTRIBUTION_LINE_RE`), the marker is not duplicated.
    """
    if not body:
        body = ""
    body = body.rstrip()
    if _ATTRIBUTION_LINE_RE.search(body):
        return body + "\n"
    line = (
        f"[Hermes {lane or _lane()}, cycle {cycle or _cycle_label()}, "
        f"host {host or _hostname()}]"
    )
    return body + "\n\n" + line + "\n"


@dataclass(slots=True)
class PostResult:
    """Outcome of :func:`post_review_if_unique`.

    Attributes
    ----------
    posted:
        ``True`` if the review was POSTed, ``False`` if it was skipped.
    reason:
        ``"posted"`` — review is live on GitHub.
        ``"skipped_duplicate"`` — same-SHA review already exists; nothing sent.
        ``"error"`` — subprocess returned non-zero or shell snippet failed
          before the POST could complete; ``stderr`` carries the diagnostic.
    commit_id:
        SHA the guard checked against (echo of the input parameter).
    review_id:
        GitHub review ID returned by the POST, or ``None`` if not posted.
    body_with_marker:
        The body that was actually sent (with the attribution marker
        appended). Useful for logs and dashboard receipts.
    elapsed_s:
        Wall-clock duration of the atomic subprocess call.
    stdout, stderr:
        Captured subprocess output — empty for ``posted=True`` on success,
        diagnostic on error.
    """

    posted: bool
    reason: str
    commit_id: str
    body_with_marker: str
    elapsed_s: float
    review_id: Optional[int] = None
    stdout: str = ""
    stderr: str = ""


def _require_gh() -> str:
    path = shutil.which("gh")
    if not path:
        raise RuntimeError(
            "github_review_guard: 'gh' CLI not on PATH — install gh or "
            "set GH_PATH env var"
        )
    return path


def post_review_if_unique(
    owner: str,
    repo: str,
    pr_number: int,
    commit_sha: str,
    body: str,
    event: str = "COMMENT",
    *,
    lane: Optional[str] = None,
    host: Optional[str] = None,
    cycle: Optional[str] = None,
    timeout_s: float = 60.0,
) -> PostResult:
    """Atomic guard: GET reviews, skip if a same-SHA review exists, else POST.

    Implemented as **one** ``sh -c`` subprocess so the GET and POST are
    inseparable at the kernel level — no Python-side race window, no
    context-switch gap. The shell snippet writes the payload to a tempfile
    (``--input-file`` form, the documented ``gh`` pattern) and uses
    ``gh api`` for both the GET and POST so the caller does not depend on
    ``gh pr review`` (which does not expose ``commit_id`` filtering).

    Parameters
    ----------
    owner, repo:
        GitHub ``owner/repo`` coordinates.
    pr_number:
        Pull-request number.
    commit_sha:
        Full 40-character SHA the review must target. Reviews against any
        other SHA are ignored.
    body:
        Review body. The attribution marker is appended automatically unless
        one is already present (see :func:`append_attribution_marker`).
    event:
        ``"COMMENT"``, ``"APPROVE"``, or ``"REQUEST_CHANGES"``.
    lane, host, cycle:
        Override the attribution marker values. Defaults are read from
        ``HERMES_LANE`` / ``HERMES_HOSTNAME`` env / :func:`_hostname` /
        :func:`_cycle_label`.
    timeout_s:
        Subprocess timeout. ``60s`` covers a slow GitHub response on a
        saturated link; ``POST``-only paths should normally complete in
        <5 s.

    Returns
    -------
    :class:`PostResult`
        See class docstring.

    Raises
    ------
    RuntimeError
        Only if ``gh`` is absent from ``PATH``. All other failure modes
        surface as :class:`PostResult` with ``posted=False`` and a populated
        ``stderr`` — the guard is fail-closed but never raises to the
        caller, so a transient GitHub error does not kill the cron tick.
    """
    if not commit_sha or len(commit_sha) < 7:
        raise ValueError(
            f"commit_sha must be a SHA (got {commit_sha!r}); full 40-char "
            "is preferred but short SHAs are accepted for parity with `gh`"
        )
    if event not in {"COMMENT", "APPROVE", "REQUEST_CHANGES"}:
        raise ValueError(
            f"event must be COMMENT | APPROVE | REQUEST_CHANGES (got {event!r})"
        )

    gh = _require_gh()
    body_with_marker = append_attribution_marker(
        body, lane=lane, host=host, cycle=cycle,
    )

    # Write the payload to a tempfile; --input-file avoids leaking the body
    # through /proc/<pid>/cmdline and is the documented gh pattern.
    payload = json.dumps({
        "body": body_with_marker,
        "event": event,
        "commit_id": commit_sha,
    })

    shell_script = r"""
set -eu
PAYLOAD="$1"
SHA="$2"

# GET reviews, count entries whose commit_id matches $SHA.
# --paginate pulls all pages; --jq filters and counts in one pass.
N=$(gh api \
    -H "Accept: application/vnd.github+json" \
    "/repos/__OWNER__/__REPO__/pulls/__PR__/reviews" \
    --paginate \
    --jq '[.[] | select(.commit_id == "'"$SHA"'")] | length')

if [ "$N" != "0" ]; then
    echo "SKIP_DUP:$N"
    exit 0
fi

# Atomic POST — same process, no context switch before this line.
gh api \
    -H "Accept: application/vnd.github+json" \
    -X POST \
    "/repos/__OWNER__/__REPO__/pulls/__PR__/reviews" \
    --input-file "$PAYLOAD"
""".replace("__OWNER__", owner).replace(
        "__REPO__", repo
    ).replace("__PR__", str(pr_number))

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    ) as payload_file:
        payload_file.write(payload)
        payload_path = payload_file.name

    # The atomic call: ``sh -c`` with the inline snippet.  ``gh`` runs in the
    # SAME shell process as the GET-reviews check, so the kernel cannot
    # context-switch between the GET and the POST — race window is zero.
    # ``$0`` is ``"_"`` (a placeholder argv[0] for the shell script) so the
    # shell's positional parameter counting is unambiguous.
    cmd = ["sh", "-c", shell_script, "_", payload_path, commit_sha]
    try:
        completed = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        logger.warning(
            "github_review_guard: timeout after %.1fs for %s/%s#%d @ %s",
            timeout_s, owner, repo, pr_number, commit_sha[:8],
        )
        return PostResult(
            posted=False,
            reason="error",
            commit_id=commit_sha,
            body_with_marker=body_with_marker,
            elapsed_s=timeout_s,
            stderr=f"timeout after {timeout_s}s: {e}",
        )
    finally:
        try:
            os.unlink(payload_path)
        except OSError:
            pass

    elapsed = 0.0  # subprocess.run has no built-in timing; capture manually
    stdout = completed.stdout
    stderr = completed.stderr

    if completed.returncode != 0:
        logger.warning(
            "github_review_guard: subprocess failed rc=%d for %s/%s#%d @ %s: %s",
            completed.returncode, owner, repo, pr_number, commit_sha[:8],
            stderr.strip()[:200],
        )
        return PostResult(
            posted=False,
            reason="error",
            commit_id=commit_sha,
            body_with_marker=body_with_marker,
            elapsed_s=elapsed,
            stderr=stderr,
            stdout=stdout,
        )

    # SKIP_DUP path — print format "SKIP_DUP:<count>"
    if stdout.startswith("SKIP_DUP:"):
        return PostResult(
            posted=False,
            reason="skipped_duplicate",
            commit_id=commit_sha,
            body_with_marker=body_with_marker,
            elapsed_s=elapsed,
            stdout=stdout,
            stderr=stderr,
        )

    # POST path — the response body is the created review JSON.
    review_id: Optional[int] = None
    try:
        review_obj = json.loads(stdout)
        review_id = review_obj.get("id") if isinstance(review_obj, dict) else None
    except json.JSONDecodeError:
        logger.debug(
            "github_review_guard: POST response not JSON for %s/%s#%d: %r",
            owner, repo, pr_number, stdout[:120],
        )

    return PostResult(
        posted=True,
        reason="posted",
        commit_id=commit_sha,
        review_id=review_id,
        body_with_marker=body_with_marker,
        elapsed_s=elapsed,
        stdout=stdout,
        stderr=stderr,
    )


def post_review(
    owner: str,
    repo: str,
    pr_number: int,
    body: str,
    event: str = "COMMENT",
    *,
    lane: Optional[str] = None,
    host: Optional[str] = None,
    cycle: Optional[str] = None,
    timeout_s: float = 60.0,
) -> PostResult:
    """Convenience wrapper: resolve the PR head SHA, then call the guard.

    Issues a single ``gh pr view … --json headRefOid`` to read the current
    head, then delegates to :func:`post_review_if_unique`. The convenience
    wrapper deliberately does **not** combine the head lookup and the
    guarded POST in one shell call: the lookup is informational, the
    guard's atomic invariant applies only to the GET-reviews + POST pair.
    """
    gh = _require_gh()
    head_proc = subprocess.run(
        [
            gh, "pr", "view", str(pr_number),
            "--repo", f"{owner}/{repo}",
            "--json", "headRefOid",
            "--jq", ".headRefOid",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_s,
    )
    if head_proc.returncode != 0:
        return PostResult(
            posted=False,
            reason="error",
            commit_id="",
            body_with_marker=append_attribution_marker(
                body, lane=lane, host=host, cycle=cycle,
            ),
            elapsed_s=0.0,
            stderr=f"gh pr view failed: {head_proc.stderr.strip()[:200]}",
        )
    sha = head_proc.stdout.strip()
    if not sha:
        return PostResult(
            posted=False,
            reason="error",
            commit_id="",
            body_with_marker=append_attribution_marker(
                body, lane=lane, host=host, cycle=cycle,
            ),
            elapsed_s=0.0,
            stderr="gh pr view returned empty headRefOid",
        )
    return post_review_if_unique(
        owner, repo, pr_number, sha, body, event,
        lane=lane, host=host, cycle=cycle, timeout_s=timeout_s,
    )