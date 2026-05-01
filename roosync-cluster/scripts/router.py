"""
Hermes Task Router — RooSync cluster cross-workspace routing prototype.

Reads global dashboard from GDrive, applies keyword heuristics, posts
[ROUTED] + [DELEGATED] messages to target workspace dashboards.

Usage:
    python roosync-cluster/scripts/router.py [--dry-run]
"""
import argparse, re, sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DASHBOARD_PATH = r"G:\Mon Drive\Synchronisation\RooSync\.shared-state\dashboards"

ROUTING_RULES = {
    "roo-extensions": [r"\bcode\b", r"\bbuild\b", r"\btest\b", r"\bnpm\b", r"\bvitest\b", r"\bbug\b", r"\bfix\b", r"\bPR\b", r"\btypescript\b", r"\bMCP\b"],
    "nanoclaw": [r"\bdocker\b", r"\bcontainer\b", r"\bdeploy\b", r"\bnanoclaw\b"],
    "CoursIA": [r"\btrain\b", r"\bmodel\b", r"\bGPU\b", r"\bCoursIA\b"],
}
DEFAULT_WORKSPACE = "roo-extensions"

def read_dashboard(p, key):
    fp = p / f"{key}.md"
    if not fp.exists(): return None
    c = fp.read_text(encoding="utf-8")
    msgs, cur = [], []
    for l in c.split("\n"):
        if l.startswith("### [") and cur: msgs.append("\n".join(cur)); cur = [l]
        elif l.startswith("### ["): cur = [l]
        else: cur.append(l)
    if cur: msgs.append("\n".join(cur))
    return {"key": key, "messages": msgs, "size": len(c)}

def find_tasks(gd):
    return [m for m in gd.get("messages",[]) if "[TASK-ROUTE]" in m]

def route(text, dashboards):
    t = text.lower()
    best, score = None, 0
    for ws, kws in ROUTING_RULES.items():
        s = sum(1 for k in kws if re.search(k, t, re.IGNORECASE))
        if s > score: score, best = s, ws
    if best: return {"target": best, "reason": f"keyword({score})", "confidence": min(score/3,1.0)}
    return {"target": DEFAULT_WORKSPACE, "reason": "default", "confidence": 0.3}

def append_msg(p, key, msg):
    fp = p / f"{key}.md"
    if not fp.exists(): return False
    c = fp.read_text(encoding="utf-8")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    fp.write_text(c.rstrip() + f"\n\n### [{ts}] hermes|hermes\n\n{msg}\n", encoding="utf-8")
    return True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--dashboard-path", default=DEFAULT_DASHBOARD_PATH)
    a = ap.parse_args()
    dp = Path(a.dashboard_path)
    if not dp.exists(): print(f"ERROR: {dp} not found"); sys.exit(1)
    print(f"HERMES ROUTER | {'DRY-RUN' if a.dry_run else 'LIVE'} | {datetime.now(timezone.utc).isoformat()}")
    gd = read_dashboard(dp, "global")
    if not gd: print("ERROR: no global dashboard"); sys.exit(1)
    print(f"Global: {gd['size']}B, {len(gd['messages'])} msgs | Dashboards: {len(list(dp.glob('*.md')))}")
    tasks = find_tasks(gd)
    print(f"Tasks: {len(tasks)}")
    if not tasks: print("No [TASK-ROUTE] found."); return
    for i, t in enumerate(tasks, 1):
        r = route(t, [])
        print(f"  {i}. -> workspace-{r['target']} ({r['reason']}, {r['confidence']:.0%})")
        if not a.dry_run:
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            routed = f"## [ROUTED] -> workspace-{r['target']}\n**Reason:** {r['reason']} | **Confidence:** {r['confidence']:.0%} | **TS:** {ts}"
            delegated = f"## [DELEGATED] from Hermes\n**Routed:** {r['reason']} | **TS:** {ts}\n\n{t[:500]}"
            append_msg(dp, "global", routed)
            append_msg(dp, f"workspace-{r['target']}", delegated)
            print(f"     [ROUTED] + [DELEGATED]")
    print(f"{'DRY-RUN' if a.dry_run else 'COMPLETE'}: {len(tasks)} task(s)")

if __name__ == "__main__": main()
