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

QUERY = """query($login: String!) { user(login: $login) { contributionsCollection {
  pullRequestReviewContributions(first: 100, orderBy: {direction: DESC}) { nodes {
    pullRequestReview { databaseId submittedAt state body commit { oid } }
    pullRequest { number repository { nameWithOwner } } } } } } }"""
LITERAL_PATH = re.compile(r"(^|\s)@(/|[\w.-]+\.(md|txt))")


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

    picked = [n for n in nodes
              if n["pullRequestReview"]["submittedAt"] >= args.since
              and args.marker in (n["pullRequestReview"]["body"] or "")]
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
    sys.exit(1 if (dups or literal or short) else 0)


if __name__ == "__main__":
    main()
