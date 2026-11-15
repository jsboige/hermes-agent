"""Integrity check of the reviews posted by the bot account since a given time.

Usage: python check-review-bodies.py 2026-10-15T01:50:00Z [--login clusterManager-Myia] [--marker "[Hermes"]

Reads the account's review contributions, newest first, across all repos, in one
GraphQL call (needs an authenticated `gh`). Sampling PRs instead goes blind: a
bulk-update wave on CoursIA (dozens of PRs in seconds) pushes fresh reviews out
of any `search/issues` window sorted by `updated`.

Reports, for reviews carrying the marker: duplicates at the same commit, bodies
under 200 chars, and bodies posted as a literal file path (`-f body=@file`
instead of `-F body=@file`) - on 14/10 one run posted four of those.
Exit code 1 when anything is found.
"""
import argparse
import collections
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

QUERY = """query($login: String!) { user(login: $login) { contributionsCollection {
  pullRequestReviewContributions(first: 100, orderBy: {direction: DESC}) { nodes {
    pullRequestReview { databaseId submittedAt state body commit { oid } }
    pullRequest { number repository { nameWithOwner } } } } } } }"""
LITERAL_PATH = re.compile(r"(^|\s)@(/|[\w.-]+\.(md|txt))")
# Header forms the bot uses as its FIRST line (measured 2026-11-01 17:53-20:53Z):
#   "[Hermes] ..."                      -> already covered by the marker
#   "**[Hermes - review ai-01]** ..."   -> already covered by the marker
#   "[APPROVE - Hermes, lane ...]"      -> NO "[Hermes" substring (roo #4487 18:12Z)
#   "[REVIEW Hermes - lane ...]"        -> NO "[Hermes" substring (mcp #1619 18:19Z)
# The last two read as not-Hermes to a plain marker search, so the window's only
# visible reviews were dropped on 01/11 and the check printed "0 reviews".
HEADER_HERMES = re.compile(r"^\s*\**\s*\[[^\]\n]*\bHermes\b")
# Fifth drift, measured 2026-11-02 08:00-08:36Z: the bot wrote its verdict as a
# markdown HEADING ("## Verdict : CHANGES_REQUESTED — …", "## Verdict : APPROVE
# — …") in all five reviews of the 08:36 run and the three before it. None of the
# forms below matched, so the window read "0 reviews marked" while REST proved 14,
# and the watchdog alerted "no review in 5.4h" one minute after a real review
# (#23899, 08:36:25Z). NanoClaw's equivalent is a BARE "VERDICT: LGTM (…)" line
# followed by "**[NanoClaw]**" — the markdown heading separates the two: 14/14
# Hermes and 12/12 NanoClaw classified correctly on the live window.
HEADER_VERDICT = re.compile(r"^\s*#{1,6}\s*(?:Review\s+)?Verdict\s*:", re.IGNORECASE)
NANOCLAW_LINE = re.compile(r"^\s*\**\s*\[NanoClaw")
# The contributions view lags at its HEAD (measured 01/11: newest node 18:19:58Z
# while REST showed reviews at 20:17:22Z, and zero CoursIA nodes in 100). Past
# this lag an empty result is not a measurement, so it must not read as "none".
HEAD_LAG_HOURS = 0.5


def is_hermes_body(body, marker):
    """Mirror of Test-HermesBody in hermes-review-watchdog.ps1 — parity is
    enforced mechanically by check-predicate-parity.py (15-fixture corpus,
    both predicates, exit 1 on divergence; first catch 2026-11-08: the PS
    NanoClaw exclusion used Contains() where the spec anchors StartsWith).

    The bot drifted off the "[Hermes" header on 2026-10-25 (three live forms,
    measured 21:09-22:46Z): the contract header, "## Review Hermes (lane ...)"
    and "## Review Hermes - incrementale ...". A Hermes review quoting the
    NanoClaw analysis it increments still counts, so NanoClaw exclusion is
    anchored to the body's first line only.
    """
    if not body:
        return False
    lines = body.split("\n")
    first = lines[0]
    if first.startswith("**[NanoClaw"):
        return False
    if HEADER_VERDICT.match(first):
        # A heading verdict is Hermes's form, but a body that names NanoClaw in
        # its first content lines is NanoClaw's (defensive; not yet observed).
        head = [line for line in lines[:6] if line.strip()][:3]
        if any(NANOCLAW_LINE.match(line) for line in head[1:]):
            return False
        return True
    if HEADER_HERMES.match(first):
        return True
    return marker in body or body.startswith("## Review Hermes")


def gh_api(args, attempts=3):
    """Run `gh api …`, retrying a TRANSIENT failure, and never die on a traceback.

    Measured 2026-11-02 11:36Z: a burst of REST calls on this host made the single
    GraphQL call fail once (quota was fine: 2570/5000 remaining), and the checker
    exited on a `subprocess.CalledProcessError` traceback. A traceback reads like a
    broken script, not like "the instrument could not measure" — and the next line
    of an incident report would have been "the checker is broken", which was false.
    Returns None when every attempt failed; the caller then says so explicitly.
    """
    last = None
    for i in range(attempts):
        last = subprocess.run(args, capture_output=True, text=True)
        if last.returncode == 0:
            return last.stdout
        if i + 1 < attempts:
            time.sleep(2 * (i + 1))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("since", help="ISO UTC timestamp, e.g. 2026-10-15T01:50:00Z")
    ap.add_argument("--login", default="clusterManager-Myia")
    ap.add_argument("--marker", default="[Hermes")
    ap.add_argument("--repos", default="jsboige/CoursIA,jsboige/roo-extensions,jsboige/jsboige-mcp-servers",
                    help="fleet repos the account reviews daily; a repo absent from the whole page is warned about")
    args = ap.parse_args()

    out = gh_api(["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"login={args.login}"])
    if out is None:
        # Exit 3 is "cannot measure", a third state distinct from 0 (clean),
        # 1 (defects found) and 2 (view inconclusive). Never let an unavailable
        # instrument be read as a count of zero reviews.
        print("INSTRUMENT UNAVAILABLE: `gh api graphql` failed after 3 attempts. "
              "This is NOT a review count — do not read it as 'no review'. "
              "Verify by REST on the PRs named in the bot's run reports.")
        sys.exit(3)
    nodes = json.loads(out)["data"]["user"]["contributionsCollection"]["pullRequestReviewContributions"]["nodes"]
    if nodes and nodes[-1]["pullRequestReview"]["submittedAt"] > args.since:
        print(f"WARNING: the 100 latest reviews only reach back to {nodes[-1]['pullRequestReview']['submittedAt']}")

    # The tail check above cannot see a HEAD lag, and the head is what lags:
    # on 01/11 the view stopped at 18:19:58Z while REST showed reviews posted
    # at 20:17:22Z, with no CoursIA node at all in the 100. A head lag makes any
    # count here a floor, not a measurement.
    lag_hours = None
    if nodes:
        head_ts = nodes[0]["pullRequestReview"]["submittedAt"]
        head_dt = datetime.fromisoformat(head_ts.replace("Z", "+00:00"))
        lag_hours = (datetime.now(timezone.utc) - head_dt).total_seconds() / 3600.0
        if lag_hours > HEAD_LAG_HOURS:
            print(f"WARNING: the view's HEAD is {lag_hours:.1f}h behind (newest {head_ts}) — "
                  f"reviews posted after it are invisible here, so any count below is a floor.")

    picked = [n for n in nodes
              if n["pullRequestReview"]["submittedAt"] >= args.since
              and is_hermes_body(n["pullRequestReview"]["body"], args.marker)]
    # A literal-path body carries no marker: check every review of the window for those.
    window = [n for n in nodes if n["pullRequestReview"]["submittedAt"] >= args.since]

    # A repo-by-repo truncation is invisible to both guards: on 2026-11-02 the view's
    # head was FRESH (03:15:48Z, no lag) yet held ZERO CoursIA nodes while REST proved
    # 11 in-window CoursIA reviews — the run below read "1 review" and exited 0. Print
    # the distribution so the truncation is visible in the output itself.
    by_repo = collections.Counter(n["pullRequest"]["repository"]["nameWithOwner"] for n in window)

    def ref(n):
        r = n["pullRequestReview"]
        return f"{n['pullRequest']['repository']['nameWithOwner']}#{n['pullRequest']['number']} review {r['databaseId']}"

    keys = collections.Counter((n["pullRequest"]["repository"]["nameWithOwner"], n["pullRequest"]["number"],
                                (n["pullRequestReview"]["commit"] or {}).get("oid")) for n in picked)
    dups = [f"{repo}#{num} @{(oid or '')[:8]} x{c}" for (repo, num, oid), c in keys.items() if c > 1]
    literal = [ref(n) for n in window if LITERAL_PATH.search(n["pullRequestReview"]["body"] or "")]
    short = [f"{ref(n)} ({len(n['pullRequestReview']['body'])} chars)" for n in picked
             if len(n["pullRequestReview"]["body"] or "") < 200]
    states = collections.Counter(n["pullRequestReview"]["state"] for n in picked)

    print(f"since {args.since}: {len(picked)} reviews marked {args.marker!r} {dict(states)}")
    print(f"  window: {len(window)} reviews by repo {dict(by_repo) or 'none'}")
    # Third shape of the view's truncation (measured 2026-11-02 05:53Z): tail reach OK,
    # head FRESH, yet ZERO CoursIA nodes in the whole 100-node page (roo 38 / mcp 40 /
    # Arg 22) while REST proved 11 in-window CoursIA reviews — the run above read
    # "1 review" and exited 0. A declared fleet repo absent from the entire page means
    # the view cannot speak about it at all: say so instead of letting silence read
    # as a count.
    page_by_repo = collections.Counter(n["pullRequest"]["repository"]["nameWithOwner"] for n in nodes)
    for repo in args.repos.split(","):
        repo = repo.strip()
        if not repo:
            continue
        if repo not in page_by_repo:
            print(f"  WARNING: {repo} holds 0 of the {len(nodes)} latest review nodes — the view "
                  f"cannot speak about that repo (measured case: 11 REST-verified reviews, 0 nodes). "
                  f"Verify by REST on the PRs named in the bot's run reports.")
    print(f"  duplicates at same commit: {dups or 'none'}")
    print(f"  literal-path bodies (any review): {literal or 'none'}")
    print(f"  bodies under 200 chars: {short or 'none'}")
    if dups or literal or short:
        sys.exit(1)
    if lag_hours is not None and lag_hours > HEAD_LAG_HOURS and not picked:
        print(f"  INCONCLUSIVE: view head {lag_hours:.1f}h behind and nothing matched — "
              f"0 here does NOT mean 'no review'. Verify by REST on the PRs named in the run reports.")
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
