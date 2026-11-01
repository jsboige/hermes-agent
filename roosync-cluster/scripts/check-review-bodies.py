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
# The contributions view lags at its HEAD (measured 01/11: newest node 18:19:58Z
# while REST showed reviews at 20:17:22Z, and zero CoursIA nodes in 100). Past
# this lag an empty result is not a measurement, so it must not read as "none".
HEAD_LAG_HOURS = 0.5


def is_hermes_body(body, marker):
    """Mirror of Test-HermesBody in hermes-review-watchdog.ps1 — keep in sync.

    The bot drifted off the "[Hermes" header on 2026-10-25 (three live forms,
    measured 21:09-22:46Z): the contract header, "## Review Hermes (lane ...)"
    and "## Review Hermes - incrementale ...". A Hermes review quoting the
    NanoClaw analysis it increments still counts, so NanoClaw exclusion is
    anchored to the body's first line only.
    """
    if not body:
        return False
    first = body.split("\n", 1)[0]
    if first.startswith("**[NanoClaw"):
        return False
    if HEADER_HERMES.match(first):
        return True
    return marker in body or body.startswith("## Review Hermes")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("since", help="ISO UTC timestamp, e.g. 2026-10-15T01:50:00Z")
    ap.add_argument("--login", default="clusterManager-Myia")
    ap.add_argument("--marker", default="[Hermes")
    args = ap.parse_args()

    out = subprocess.run(["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"login={args.login}"],
                         capture_output=True, text=True, check=True).stdout
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
