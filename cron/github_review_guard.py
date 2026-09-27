"""GitHub review POST guard module (issue #3476 — **unwired**).

Twin-same-SHA reviews were emitted by the hermes cron container on
myia-po-2026: the ``hermes-pr-review`` and ``hermes-inbox-poll`` cron lanes
POST GitHub reviews independently of the tracked interactive lane. The lane's
pool scan saw ``reviews=0``, the tracked lane reviewed between scan and POST,
and the cron lane posted a second review on the same SHA (#14807, #14819,
#14821, #14863 ×2, #14866, #14878, #3477, …). User-approved remediation
(datapoint #16, 2026-09-13): re-scan reviews immediately before every POST,
with a cycle/lane attribution convention so the receiving end can attribute
every emission.

This module provides the guarded POST primitive. **No lane calls it yet**:
the ``hermes-pr-review`` / ``hermes-inbox-poll`` lanes are configured in the
po-2026 container's cron setup, outside this repository, so wiring them is
follow-up work tracked in ``jsboige/roo-extensions#3476``. Until that wiring
lands, 0 % of container POSTs go through this guard.

What the single ``sh -c`` subprocess does and does not buy: the identity
check (``gh api user``), the GET
(``/repos/{owner}/{repo}/pulls/{pr}/reviews``) and the conditional POST run
inside one shell invocation, which removes the Python-side gap between the
check and the send. It is **not** an atomicity guarantee: the checks and the
POST are separate ``gh`` processes inside that shell, and the kernel may
schedule another lane's guard between them. Cross-lane serialization must
come from the caller holding the canonical Hermes cron lock
(``~/.hermes/cron/.tick.lock``) around this call at wiring time.

Account-identity guard (roo-extensions #3476, web1 datapoint #24): the
previous guards cover the *what* (no twin same-SHA review) and the *who*
(signed attribution marker), but neither looked at the login the POST
actually leaves under — on a shared-login container a stray ``gh auth
switch`` re-silences every attribution. This is the bot equivalent of the
roo-extensions rule #3032: ``gh api user --jq .login`` runs **in the same
shell as the POST**, compared against the expected login
(:func:`_expected_login` — ``HERMES_EXPECTED_LOGIN`` env, set by the
container-side lane wrapper). Mismatch → the POST is refused
(``reason="refused_account"``, the observed login in
``PostResult.observed_login``, an ``logger.error`` alert) and nothing is
sent. **Fail-closed**: no expected login configured → refuse, never
silently post; ``gh api user`` failing → the shell exits non-zero →
``reason="error"``, still no POST. An emission under an unexpected account
can no longer be silent.

Cycle/lane attribution: by default the guard appends a single line to the
review body before POSTing::

    [Hermes <lane>, cycle :XX DD/MM, host <host>]

- ``<lane>``: the cron lane name (``hermes-pr-review``,
  ``hermes-inbox-poll``, …) — passed by the caller or read from the
  ``HERMES_LANE`` env override. Nothing in this repository exports
  ``HERMES_LANE`` / ``HERMES_HOSTNAME``; the container-side lane wrapper is
  expected to set them when the guard is wired.
- ``<host>``: ``socket.gethostname()`` — ``HERMES_HOSTNAME`` env override
  wins when set, ``unknown`` as last resort.
- Cycle label format ``:XX DD/MM`` matches the convention already in use by
  the tracked interactive lane on po-2026 (datapoint #16 §2: the cycle
  marker in body is the **single invariant** that separates tracked
  emissions from twins).
- The marker line is **idempotent**: if the body already **ends** with a
  full ``[Hermes <lane>, cycle :XX DD/MM, host <host>]`` line, no second
  marker is appended. A partial marker (missing lane/cycle/host) or a
  quoted ``[Hermes …]`` line mid-body does **not** count — the marker is
  detected only at the very end of the body.
- **Signed markers** (roo-extensions #3476 follow-up): when the container
  holds an attribution key file, the line gains a trailing
  ``sig=<8 hex>`` — HMAC-SHA256 over ``lane|cycle|host|pr|sha``, with the
  PR number and full commit OID as MAC-only inputs (never displayed), so a
  copied marker fails verification on any other PR/commit. No key means an
  unsigned marker, identical to the pre-signing format; signing never
  blocks a POST.

Module surface:

- :func:`post_review_if_unique` — primary entry point; one shell call,
  check + POST.
- :func:`post_review` — convenience wrapper: auto-resolves the PR head SHA
  via ``gh pr view``, then calls :func:`post_review_if_unique`.
- :func:`append_attribution_marker` — pure helper that adds the marker line
  to a body if not already present; exported so callers can preview the body
  before POSTing.
- :func:`verify_attribution` — extract + verify a body's marker against a
  PR/SHA pair; the CLI (``--verify-marker``, body on stdin) wraps it for
  fleet sweeps.

All subprocess invocations use ``sh -c`` with a temporary file holding the
POST payload so the command line does not embed secrets or large bodies
(args are visible to ``/proc/<pid>/cmdline`` on Linux; ``gh api --input
<file>`` is the documented GitHub-CLI pattern for JSON payloads).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger(__name__)

# Cycle/lane attribution marker: a single bracketed line at the very END of
# the body. All three fields (lane, cycle, host) are required, so a bare
# ``[Hermes]``, a partial marker, or a quoted ``[Hermes …]`` line in the
# middle of the body never suppresses the fresh marker (issue #3476 review:
# the previous permissive regex accepted citations and templates).
# The trailing ``sig=<8 hex>`` field is OPTIONAL (signed markers, #3476
# follow-up): unsigned markers keep matching, so idempotence and every
# pre-signing body stay valid. ``host`` stops at ``,`` so it cannot swallow
# the sig field — real hostnames / container IDs contain no comma.
_ATTRIBUTION_LINE_RE = re.compile(
    r"\[Hermes\s+(?P<lane>[^\],]+),"
    r"\s*cycle\s+:(?P<cycle>\d{1,2})\s+(?P<day>\d{1,2}/\d{1,2}),"
    r"\s*host\s+(?P<host>[^\],]+)"
    r"(?:,\s*sig=(?P<sig>[0-9a-f]{8}))?\]\s*$"
)

# Default lane when the caller passes none and HERMES_LANE is unset. No code
# in this repository exports the override — it belongs to the container-side
# lane wrapper once the guard is wired (see module docstring).
_DEFAULT_LANE = "hermes-pr-review"
_DEFAULT_HOST = ""  # populated at call time from socket.gethostname()


def _lane() -> str:
    return os.environ.get("HERMES_LANE", _DEFAULT_LANE).strip() or _DEFAULT_LANE


def _expected_login() -> Optional[str]:
    """The GitHub login this lane is configured to post under.

    ``HERMES_EXPECTED_LOGIN`` is set by the container-side lane wrapper at
    wiring time (like ``HERMES_LANE``). An empty/unset value means "no
    expectation configured" — the caller fails closed on that (see
    :func:`post_review_if_unique`).
    """
    return os.environ.get("HERMES_EXPECTED_LOGIN", "").strip() or None


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
                              cycle: Optional[str] = None,
                              pr: Optional[int] = None,
                              sha: Optional[str] = None) -> str:
    """Return ``body`` with a single attribution marker appended.

    Idempotent: if the body already **ends** with a full
    ``[Hermes <lane>, cycle :XX DD/MM, host <host>]`` line (matching
    :data:`_ATTRIBUTION_LINE_RE`), the marker is not duplicated. Partial or
    mid-body markers do not count. An unsigned trailing marker is left
    as-is (never upgraded in place).

    When an attribution key is loadable (see :func:`_load_attribution_key`),
    the marker carries a trailing ``sig=<8 hex>``: HMAC-SHA256 over
    ``lane|cycle|host|pr|sha`` truncated to 8 hex chars. Including ``pr`` and
    the 40-char ``sha`` in the MAC input (but NOT in the displayed line)
    makes a captured marker non-replayable onto another PR or commit. Safe
    degradation: no key, or an unusable one, means an unsigned marker —
    signing never blocks a POST. ``pr``/``sha`` default to ``None`` and are
    MAC'd as empty fields in that case.
    """
    if not body:
        body = ""
    body = body.rstrip()
    if _ATTRIBUTION_LINE_RE.search(body):
        return body + "\n"
    eff_lane = lane or _lane()
    eff_cycle = cycle or _cycle_label()
    eff_host = host or _hostname()
    line = f"[Hermes {eff_lane}, cycle {eff_cycle}, host {eff_host}"
    key = _load_attribution_key()
    if key is not None:
        line += f", sig={_sign_marker(key, eff_lane, eff_cycle, eff_host, pr, sha)}"
    line += "]"
    return body + "\n\n" + line + "\n"


# Signed-marker key (roo-extensions #3476 follow-up): the marker line alone
# is forgeable text — anyone can write ``[Hermes hermes-pr-review, cycle …]``
# into a body. A short HMAC over the marker fields turns the line into an
# attestation only key holders can produce. The key is NEVER generated here:
# deployment creates it (32 random bytes, mode 0600) inside the container;
# this module only reads it, and degrades to unsigned markers without it.
_DEFAULT_KEY_PATH = "/opt/data/hermes-ops/guard/attribution.key"


def _attribution_key_path() -> str:
    """Key file location — ``HERMES_ATTRIBUTION_KEY`` (a PATH, never key
    material: env values are readable from ``/proc/<pid>/environ``) wins
    over the container default."""
    env_path = os.environ.get("HERMES_ATTRIBUTION_KEY", "").strip()
    return env_path or _DEFAULT_KEY_PATH


def _load_attribution_key() -> Optional[bytes]:
    """Return the HMAC key bytes, or ``None`` when unavailable.

    ``None`` (missing file, unreadable, or shorter than 16 bytes) always
    means "emit an unsigned marker" — never an exception, never a blocked
    POST.
    """
    path = _attribution_key_path()
    try:
        # Key material is arbitrary bytes (hex at deploy time) — binary mode
        # by design; the path is hoisted so the windows-footguns checker's
        # open() regex can see the "rb" mode (a call expression as the first
        # argument blinds its mode group).
        with open(path, "rb") as fh:
            key = fh.read().strip()
    except OSError:
        return None
    if len(key) < 16:
        return None
    return key


def _sign_marker(key: bytes, lane: str, cycle: str, host: str,
                 pr: Optional[int], sha: Optional[str]) -> str:
    """8-hex HMAC-SHA256 over ``lane|cycle|host|pr|sha`` (empty for None)."""
    msg = "|".join([
        lane,
        cycle,
        host,
        "" if pr is None else str(pr),
        "" if not sha else sha.strip().lower(),
    ])
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).hexdigest()[:8]


@dataclass(slots=True)
class AttributionVerdict:
    """Result of :func:`verify_attribution` — JSON-serializable for sweeps.

    ``signature_valid`` requires ``key_available``; a verdict with
    ``signed=True, key_available=False`` means "cannot verify here" (e.g.
    sweeping from a host without the container key), NOT "forged".
    """

    marker_present: bool
    lane: Optional[str] = None
    cycle: Optional[str] = None
    host: Optional[str] = None
    signed: bool = False
    key_available: bool = False
    signature_valid: bool = False


def verify_attribution(body: str, *, pr: Optional[int] = None,
                       sha: Optional[str] = None) -> AttributionVerdict:
    """Extract and verify the attribution marker at the end of ``body``.

    ``pr``/``sha`` are the review's PR number and full commit OID as known
    by the CALLER (from the GitHub API object being swept) — they are MAC
    inputs, not read back from the line. A marker whose sig was computed
    for a different PR/commit therefore fails verification even though its
    text looks well-formed: the anti-replay property.
    """
    if not body:
        return AttributionVerdict(marker_present=False)
    m = _ATTRIBUTION_LINE_RE.search(body.rstrip())
    if not m:
        return AttributionVerdict(marker_present=False)
    cycle_label = f":{m['cycle']} {m['day']}"
    verdict = AttributionVerdict(
        marker_present=True,
        lane=m["lane"],
        cycle=cycle_label,
        host=m["host"],
        signed=m["sig"] is not None,
    )
    if not verdict.signed:
        return verdict
    key = _load_attribution_key()
    if key is None:
        return verdict  # key_available=False: unverifiable, not invalid
    verdict.key_available = True
    expected = _sign_marker(key, m["lane"], cycle_label, m["host"], pr, sha)
    verdict.signature_valid = hmac.compare_digest(expected, m["sig"])
    return verdict


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
        ``"refused_account"`` — the active ``gh`` login is not the expected
          one (``observed_login`` holds it), or no expected login is
          configured; nothing sent. This is the alert signal: an emission
          under an unexpected account was refused instead of staying silent.
        ``"error"`` — subprocess returned non-zero or shell snippet failed
          before the POST could complete; ``stderr`` carries the diagnostic.
    commit_id:
        SHA the guard checked and POSTed against — the **effective** SHA:
        short inputs are resolved to the full 40-char OID first (datapoint
        #18 §3), so this echoes the resolution result, not the raw input.
    review_id:
        GitHub review ID returned by the POST, or ``None`` if not posted.
    observed_login:
        The login ``gh api user`` reported at guard time, for
        ``refused_account`` results (``None`` when the refusal predates the
        shell — no expected login configured).
    body_with_marker:
        The body that was actually sent (with the attribution marker
        appended). Useful for logs and dashboard receipts.
    elapsed_s:
        Wall-clock duration of the subprocess call (measured, not a stub).
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
    observed_login: Optional[str] = None
    stdout: str = ""
    stderr: str = ""


def _require_gh() -> str:
    """Resolve the ``gh`` binary — ``GH_PATH`` override wins over ``PATH``."""
    path = os.environ.get("GH_PATH", "").strip() or shutil.which("gh")
    if not path:
        raise RuntimeError(
            "github_review_guard: 'gh' CLI not found — install it on PATH "
            "or set GH_PATH"
        )
    return path


def _resolve_full_sha(
    gh: str, owner: str, repo: str, short_sha: str, timeout_s: float,
) -> tuple[Optional[str], str]:
    """Resolve a short (7-39 hex chars) SHA to its full 40-char commit OID.

    One ``gh api /repos/{owner}/{repo}/commits/{sha}`` call — GitHub accepts
    short SHAs on the commits endpoint and returns the full OID as ``.sha``.
    Returns ``(full_sha, "")`` on success or ``(None, diagnostic)`` on
    failure. Never raises: the caller fails closed into a ``PostResult``
    error so a transient GitHub failure does not kill the cron tick.
    """
    try:
        # Through ``sh`` like the guarded snippet: one invocation pattern,
        # and the call works wherever ``sh`` resolves the gh binary (the
        # direct-exec form cannot spawn a script on Windows, where the
        # test-suite gh stub lives).
        proc = subprocess.run(
            ["sh", "-c", '"$1" api "$2" --jq .sha', "_", gh,
             f"/repos/{owner}/{repo}/commits/{short_sha}"],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        return None, f"timeout after {timeout_s}s: {e}"
    except OSError as e:
        return None, f"spawn failed: {e}"
    if proc.returncode != 0:
        err = proc.stderr.strip()[:200] or f"gh api exit {proc.returncode}"
        return None, err
    full = proc.stdout.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", full):
        return None, f"unexpected resolution output: {full[:60]!r}"
    return full, ""


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
    expected_login: Optional[str] = None,
    timeout_s: float = 60.0,
) -> PostResult:
    """Guarded POST: GET reviews, skip if a same-SHA review exists, else POST.

    Implemented as **one** ``sh -c`` subprocess so the check and the POST
    share a single shell invocation — no Python-side gap between them. This
    does **not** serialize concurrent lanes (see module docstring): the
    caller is responsible for holding the canonical Hermes cron lock around
    this call at wiring time.

    The count query uses ``gh api --paginate`` and sums the per-page
    counts with ``awk``: ``gh`` >= 2.100 **rejects** ``--slurp`` combined
    with ``--jq`` (``the --slurp option is not supported with --jq``), which
    made the previous ``--slurp`` form fail-closed on every call. Without a
    per-page sum, two empty pages print ``0\\n0`` — which a naive
    ``[ "$N" != "0" ]`` comparison misreads as a duplicate, false-skipping
    a legitimate POST. Found while wiring the guard in the po-2026 cron
    container (roo-extensions #3476): the merged tests exercised the shell
    only against a stub ``gh``, so the incompatibility never surfaced.

    Parameters
    ----------
    owner, repo:
        GitHub ``owner/repo`` coordinates.
    pr_number:
        Pull-request number.
    commit_sha:
        SHA the review must target. A full 40-char OID is used as-is; a
        short hex SHA (7-39 chars) is resolved to the full OID via one
        ``gh api commits`` call **before** the guarded shell — a truncated
        ``commit_id`` both 422s the POST and never matches the GET-reviews
        dedup (datapoint #18 §3, roo-extensions #3476).
    body:
        Review body. The attribution marker is appended automatically unless
        the body already ends with a full one (see
        :func:`append_attribution_marker`).
    event:
        ``"COMMENT"``, ``"APPROVE"``, or ``"REQUEST_CHANGES"``.
    lane, host, cycle:
        Override the attribution marker values. Defaults are read from
        ``HERMES_LANE`` / ``HERMES_HOSTNAME`` env / :func:`_hostname` /
        :func:`_cycle_label`.
    expected_login:
        The GitHub login this POST must leave under. Defaults to
        ``HERMES_EXPECTED_LOGIN`` env; when neither is set the guard
        **refuses** (``reason="refused_account"``, fail-closed) — see the
        account-identity guard in the module docstring. The comparison runs
        inside the guarded shell, against the login live at POST time.
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
        Only if ``gh`` is absent (neither ``GH_PATH`` nor ``PATH`` resolve
        it). All other failure modes surface as :class:`PostResult` with
        ``posted=False`` and a populated ``stderr`` — the guard is
        fail-closed but never raises to the caller, so a transient GitHub
        error does not kill the cron tick.
    """
    sha = (commit_sha or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        raise ValueError(
            f"commit_sha must be a hex SHA of 7-40 chars (got {commit_sha!r})"
        )
    if event not in {"COMMENT", "APPROVE", "REQUEST_CHANGES"}:
        raise ValueError(
            f"event must be COMMENT | APPROVE | REQUEST_CHANGES (got {event!r})"
        )

    gh = _require_gh()

    # Account-identity guard (#3476 datapoint #24): fail closed BEFORE any
    # GitHub traffic when no expectation is configured — the container-side
    # wrapper must set HERMES_EXPECTED_LOGIN at wiring time, and a wiring
    # without it refuses loudly rather than posting under an unverified
    # account. The login-vs-expected COMPARISON itself lives in the shell
    # below (same invocation as the POST — rule #3032: no check-to-send gap).
    eff_expected = expected_login or _expected_login()
    if not eff_expected:
        logger.error(
            "github_review_guard: HERMES_EXPECTED_LOGIN unset for lane %s "
            "on host %s — refusing to POST (fail-closed; the lane wrapper "
            "must set it at wiring time)",
            lane or _lane(), host or _hostname(),
        )
        return PostResult(
            posted=False,
            reason="refused_account",
            commit_id=(commit_sha or "").strip().lower(),
            body_with_marker=append_attribution_marker(
                body, lane=lane, host=host, cycle=cycle, pr=pr_number,
            ),
            elapsed_s=0.0,
            stderr=(
                "refused: no expected login configured "
                "(HERMES_EXPECTED_LOGIN unset, expected_login not passed)"
            ),
        )

    # Datapoint #18 §3 (roo-extensions #3476): review ``commit_id`` values on
    # GitHub are ALWAYS full 40-char OIDs and the POST endpoint requires one —
    # a short SHA both 422s the POST ("The commitOID is not part of the pull
    # request") and silently disables the GET-reviews dedup (a jq
    # ``select(.commit_id == "<short>")`` never matches a full OID). Resolve
    # short SHAs to the full OID BEFORE the guarded shell. This lookup is
    # informational (like ``post_review``'s head lookup): the check→POST pair
    # stays inside the single ``sh -c`` invocation, so the twin window is not
    # reopened.
    if len(sha) != 40:
        resolved, resolve_err = _resolve_full_sha(
            gh, owner, repo, sha, timeout_s,
        )
        if not resolved:
            logger.warning(
                "github_review_guard: cannot resolve short SHA %r for "
                "%s/%s#%d: %s",
                sha, owner, repo, pr_number, resolve_err,
            )
            return PostResult(
                posted=False,
                reason="error",
                commit_id=sha,
                body_with_marker=append_attribution_marker(
                    body, lane=lane, host=host, cycle=cycle, pr=pr_number,
                ),
                elapsed_s=0.0,
                stderr=(
                    f"commit_sha {sha!r} is not 40 chars and could not be "
                    f"resolved: {resolve_err}"
                ),
            )
        sha = resolved

    # Marker composition happens AFTER short-SHA resolution so the HMAC (if
    # any) covers the full 40-char OID actually POSTed and matched by the
    # dedup — a sig over a truncated SHA would never verify on sweep.
    body_with_marker = append_attribution_marker(
        body, lane=lane, host=host, cycle=cycle,
        pr=pr_number, sha=sha,
    )

    # Write the payload to a tempfile; gh api --input <file> avoids leaking
    # the body through /proc/<pid>/cmdline.
    payload = json.dumps({
        "body": body_with_marker,
        "event": event,
        "commit_id": sha,
    })

    shell_script = r"""
set -eu
PAYLOAD="$1"
SHA="$2"
GH="$3"
EXPECTED="$4"

# Account-identity guard (#3476 datapoint #24, bot equivalent of rule #3032):
# the login the POST would leave under is checked IN THIS SHELL, immediately
# before the send — no Python-side gap where a stray `gh auth switch` could
# flip the account between check and POST. Mismatch -> refuse (nothing is
# sent); `gh api user` failing exits non-zero under set -eu -> same refusal,
# an identity we could not verify is not an identity we post under.
LOGIN="$("$GH" api user --jq .login)"
if [ "$LOGIN" != "$EXPECTED" ]; then
    echo "REFUSED_LOGIN:$LOGIN"
    exit 0
fi

# GET reviews, count entries whose commit_id matches $SHA.
# --paginate pulls all pages; gh >= 2.100 rejects --slurp with --jq, so each
# page's count lands on its own line and awk sums them to a single integer.
# A naive per-line comparison would misread "0\n0" as a duplicate (false
# SKIP_DUP) — the awk sum keeps one integer.
N=$("$GH" api \
    -H "Accept: application/vnd.github+json" \
    "/repos/__OWNER__/__REPO__/pulls/__PR__/reviews" \
    --paginate \
    --jq '[.[] | select(.commit_id == "'"$SHA"'")] | length' \
    | awk '{s+=$1} END {print s+0}')

if [ "$N" != "0" ]; then
    echo "SKIP_DUP:$N"
    exit 0
fi

# POST — same shell invocation as the check. gh api --input reads the JSON
# payload from the tempfile, keeping the body off the command line.
"$GH" api \
    -H "Accept: application/vnd.github+json" \
    -X POST \
    "/repos/__OWNER__/__REPO__/pulls/__PR__/reviews" \
    --input "$PAYLOAD"
""".replace("__OWNER__", owner).replace(
        "__REPO__", repo
    ).replace("__PR__", str(pr_number))

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    ) as payload_file:
        payload_file.write(payload)
        payload_path = payload_file.name

    # One sh -c invocation: the identity check, the GET and the POST share
    # the shell (the resolved gh path is passed as $3 so the binary verified
    # by _require_gh() is the one actually invoked; $2 carries the FULL SHA,
    # $4 the expected login).
    cmd = ["sh", "-c", shell_script, "_", payload_path, sha, gh, eff_expected]
    t0 = time.monotonic()
    try:
        completed = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        elapsed = time.monotonic() - t0
        logger.warning(
            "github_review_guard: timeout after %.1fs for %s/%s#%d @ %s",
            timeout_s, owner, repo, pr_number, commit_sha[:8],
        )
        return PostResult(
            posted=False,
            reason="error",
            commit_id=sha,
            body_with_marker=body_with_marker,
            elapsed_s=elapsed,
            stderr=f"timeout after {timeout_s}s: {e}",
        )
    finally:
        try:
            os.unlink(payload_path)
        except OSError:
            pass

    elapsed = time.monotonic() - t0
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
            commit_id=sha,
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
            commit_id=sha,
            body_with_marker=body_with_marker,
            elapsed_s=elapsed,
            stdout=stdout,
            stderr=stderr,
        )

    # REFUSED_LOGIN path — print format "REFUSED_LOGIN:<login>" (identity
    # guard): the alert is the logger.error — container log watchers and the
    # cron lane's dashboard receipt surface it; the distinct reason lets
    # callers escalate without string-matching stderr.
    if stdout.startswith("REFUSED_LOGIN:"):
        observed = stdout[len("REFUSED_LOGIN:"):].strip()
        logger.error(
            "github_review_guard: REFUSED POST for %s/%s#%d — active gh "
            "login %r != expected %r (lane %s, host %s)",
            owner, repo, pr_number, observed, eff_expected,
            lane or _lane(), host or _hostname(),
        )
        return PostResult(
            posted=False,
            reason="refused_account",
            commit_id=sha,
            body_with_marker=body_with_marker,
            elapsed_s=elapsed,
            observed_login=observed,
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
        commit_id=sha,
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
    guard's single-shell invariant applies only to the GET-reviews + POST
    pair.
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
                body, lane=lane, host=host, cycle=cycle, pr=pr_number,
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
                body, lane=lane, host=host, cycle=cycle, pr=pr_number,
            ),
            elapsed_s=0.0,
            stderr="gh pr view returned empty headRefOid",
        )
    return post_review_if_unique(
        owner, repo, pr_number, sha, body, event,
        lane=lane, host=host, cycle=cycle, timeout_s=timeout_s,
    )


def _cli_verify_marker(argv: Optional[list] = None) -> int:
    """``--verify-marker``: read a review body on stdin, verify its marker.

    Exit codes a sweep can branch on: 0 signed+valid · 1 marker present but
    unsigned (pre-signing emission) · 2 signed but invalid OR unverifiable
    (no key on this host) · 3 no marker at all. One JSON verdict on stdout.
    """
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        prog="github_review_guard.py --verify-marker",
        description="Verify the attribution marker of a review body (stdin).",
    )
    parser.add_argument("--pr", type=int, default=None,
                        help="PR number the review was posted on")
    parser.add_argument("--sha", default=None,
                        help="full 40-char commit OID of the review")
    args = parser.parse_args(argv)

    body = sys.stdin.read()
    verdict = verify_attribution(body, pr=args.pr, sha=args.sha)
    import dataclasses

    print(json.dumps(dataclasses.asdict(verdict)))
    if not verdict.marker_present:
        return 3
    if not verdict.signed:
        return 1
    if verdict.signature_valid:
        return 0
    return 2


if __name__ == "__main__":  # pragma: no cover - CLI exercised via _cli_verify_marker
    raise SystemExit(_cli_verify_marker())
