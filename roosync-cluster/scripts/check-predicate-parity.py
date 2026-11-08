"""Mechanical parity guard between the two Hermes-body predicates.

Reserve #2 of the external review of PR#26 (NanoClaw, 2026-11-08 06:06Z):
`is_hermes_body` (check-review-bodies.py, Python) and `Test-HermesBody`
(hermes-review-watchdog.ps1, PowerShell) are two implementations of the same
classification kept in sync by discipline alone ("keep in sync" comment).
Five header drifts have already been caught after the fact; this guard runs
both predicates over the same fixture corpus and fails on any divergence.

Usage: python check-predicate-parity.py
Exit 0 = full parity. Exit 1 = at least one fixture classified differently
(the report names the fixture and both verdicts).

Run it from the repo root or anywhere: paths resolve relative to this file.
The PowerShell side needs powershell.exe (Windows). On a seat without PS the
script exits 3 (instrument unavailable) — never read as parity.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY_PREDICATE = os.path.join(HERE, "check-review-bodies.py")
PS_PREDICATE = os.path.join(HERE, "hermes-review-watchdog.ps1")
MARKER = "[Hermes"

# Fixture corpus. Every branch of the shared spec plus the two drift-probe
# cases (first line that MENTIONS [NanoClaw mid-line while being otherwise a
# Hermes form — the exclusion is anchored to a first line STARTING WITH the
# NanoClaw banner, spec validated 10/10 on live reviews 2026-10-25).
FIXTURES = [
    ("contract-header", "[Hermes] Review sur le head abc123", True),
    ("bold-marker-first-line", "**[Hermes - review ai-01]** analyse du head", True),
    ("lane-heading", "## Review Hermes (lane myia-ai-01:hermes-agent) - analyse", True),
    (
        "incrementale-quoting-nanoclaw-in-body",
        "## Review Hermes - incrementale au head X\n\nContexte.\n\nL'analyse [NanoClaw] precedente disait Y, voici le complement.\n",
        True,
    ),
    ("nanoclaw-banner-first-line", "**[NanoClaw]** structural review - 2 porteurs lus", False),
    (
        "footer-marker-only",
        "**Rejeu independant sur ai-01, tete 29dc29ff.** Les mesures sont exactes.\n\nVerdict : COMMENT.\n\n[Hermes hermes-pr-review, cycle :04 08/11, host myia-ai-01, sig=df9ccd12]",
        True,
    ),
    ("verdict-heading-hermes", "## Verdict : CHANGES_REQUESTED - prose drift", True),
    (
        "verdict-heading-nanoclaw-second-line",
        "## Verdict : LGTM (structurel)\n\n**[NanoClaw]** suite de l'analyse",
        False,
    ),
    (
        "bare-verdict-nanoclaw",
        "VERDICT: LGTM (structurel - 2 porteurs lus integralement)\n\n**[NanoClaw]** structural review",
        False,
    ),
    ("approve-20261101-form", "[APPROVE - Hermes, lane myia-ai-01:hermes-agent, circuit #32]", True),
    ("review-20261101-form", "[REVIEW Hermes - lane myia-ai-01:hermes-agent, circuit #3219]", True),
    ("empty-body", "", False),
    ("unrelated-body", "Quelques remarques sur la PR, sans marqueur d'aucune lane.", False),
    # Drift probes: first line MENTIONS [NanoClaw mid-line but is otherwise a
    # Hermes form. Spec (anchored startswith) says Hermes = True. A Contains()
    # exclusion would drop them — the exact organ-blindness class this guard
    # exists to catch (a real Hermes review read as silence -> false ALERT).
    ("probe-mention-mid-first-line", "## Review Hermes - prolonge l'analyse [NanoClaw] ci-dessous", True),
    ("probe-mention-with-marker", "[Hermes] review - reprise du post [NanoClaw] du voisin", True),
]


def python_verdicts():
    spec = importlib.util.spec_from_file_location("crb", PY_PREDICATE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return [bool(mod.is_hermes_body(body, MARKER)) for _, body, _ in FIXTURES]


def extract_ps_function():
    """Pull the Test-HermesBody function block out of the watchdog script."""
    with open(PS_PREDICATE, encoding="utf-8-sig") as fh:
        text = fh.read()
    m = re.search(r"(?ms)^function Test-HermesBody \{.*?^\}", text)
    if not m:
        sys.stderr.write("Test-HermesBody not found in %s\n" % PS_PREDICATE)
        sys.exit(3)
    return m.group(0)


def powershell_verdicts(func_text):
    """Run the PS predicate over the same corpus via a temp wrapper."""
    cases = [{"name": n, "body": b} for n, b, _ in FIXTURES]
    tmpdir = tempfile.mkdtemp(prefix="pred-parity-")
    cases_path = os.path.join(tmpdir, "cases.json")
    out_path = os.path.join(tmpdir, "out.txt")
    wrapper = os.path.join(tmpdir, "wrapper.ps1")
    with open(cases_path, "w", encoding="utf-8") as fh:
        json.dump(cases, fh, ensure_ascii=False)
    wrapper_text = (
        "$ErrorActionPreference = 'Stop'\n"
        "$script:BodyMarker = '[Hermes'\n"
        + func_text
        + "\n$cases = Get-Content -Raw -LiteralPath '%s' | ConvertFrom-Json\n"
        "$out = @()\n"
        "foreach ($c in $cases) { $out += [bool](Test-HermesBody -Body $c.body) }\n"
        "[System.IO.File]::WriteAllText('%s', ($out -join ','), [System.Text.UTF8Encoding]::new($false))\n"
        % (cases_path, out_path)
    )
    # Function text and wrapper carry review bodies with apostrophes: write the
    # wrapper to a file (never pass through the command line).
    with open(wrapper, "w", encoding="utf-8-sig") as fh:
        fh.write(wrapper_text)
    proc = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", wrapper],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0 or not os.path.exists(out_path):
        sys.stderr.write("powershell wrapper failed rc=%s\n%s\n" % (proc.returncode, proc.stderr))
        sys.exit(3)
    with open(out_path, encoding="utf-8") as fh:
        raw = fh.read().strip()
    return [v == "True" for v in raw.split(",") if v != ""]


def main():
    py = python_verdicts()
    ps = powershell_verdicts(extract_ps_function())
    mismatches = []
    for i, (name, _, expected) in enumerate(FIXTURES):
        if py[i] != ps[i]:
            mismatches.append("  DIVERGENCE %-38s python=%s powershell=%s (spec: %s)" % (name, py[i], ps[i], expected))
        elif py[i] != expected:
            mismatches.append("  SPEC-FAIL   %-38s both=%s spec=%s" % (name, py[i], expected))
    print("parity: %d/%d fixtures agree" % (len(FIXTURES) - len(mismatches), len(FIXTURES)))
    if mismatches:
        print("\n".join(mismatches))
        print("FAIL: the two predicates have diverged (or both left the spec).")
        return 1
    print("OK: python and powershell predicates agree on every fixture.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
