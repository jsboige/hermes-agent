# hermes-verify.ps1 — 14-point post-op verification
# Usage: .\roosync-cluster\scripts\hermes-verify.ps1
# Runs checks inside the hermes container and reports PASS/FAIL.

$ErrorActionPreference = "Stop"
$Container = "hermes"

function Invoke-Hermes {
    param([string]$Command, [string]$User = "")
    # PowerShell strips embedded double quotes when passing args to docker.exe, so a
    # command like:  python3 -c "import json,sys; ..."  arrives as:  python3 -c "import"
    # -> SyntaxError. Base64 the command and decode it inside the container instead:
    # no quote ever crosses the PowerShell/docker argument boundary.
    # Strip CR for the same reason people forget: this file is checked out with CRLF, so a
    # multi-line here-string would reach sh with "\r" glued to every token -> `fi\r` is not
    # `fi` and sh dies with "end of file unexpected (expecting \"fi\")".
    $Command = $Command -replace "`r", ""
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    $execArgs = @("exec")
    if ($User) { $execArgs += @("-u", $User) }
    $execArgs += @($Container, "sh", "-c", "echo $b64 | base64 -d | sh")
    $result = & docker @execArgs 2>&1
    return $result
}

function Check {
    param([string]$Label, [string]$Result)
    if ($Result -eq "OK") {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  [FAIL] $Label - $Result" -ForegroundColor Red
        return $false
    }
}

$Pass = 0
$Fail = 0

Write-Host "=== HERMES VERIFICATION (14 checks) ===" -ForegroundColor Cyan
Write-Host ""

# 1. Gateway process running
# The real cmdline is `/opt/hermes/.venv/bin/python -P -c "... hermes_cli.main ..." gateway run --replace`
# — the literal "hermes gateway run" is never contiguous. Match the "gateway run"
# suffix instead (bracket trick keeps grep itself out of the count).
$proc = Invoke-Hermes 'ps aux | grep "[g]ateway run" | wc -l'
if ($proc -match "([1-9])") { if (Check "Gateway process" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Gateway process" "not running ($proc)") { $Pass++ } else { $Fail++ } }

# 2. Telegram connected
$tg = Invoke-Hermes 'cat /opt/data/gateway_state.json /opt/data/.hermes/gateway_state.json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(\"platforms\",{}).get(\"telegram\",{}).get(\"state\",\"unknown\"))" 2>/dev/null || echo "NOT_FOUND"'
if ($tg -match "connected") { if (Check "Telegram" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Telegram" "$tg") { $Pass++ } else { $Fail++ } }

# 3. Config readable via symlink
$cfg = Invoke-Hermes 'head -1 /opt/data/.hermes/config.yaml 2>/dev/null || echo "FAIL"'
if ($cfg -match "model:") { if (Check "Config symlink" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Config symlink" "$cfg") { $Pass++ } else { $Fail++ } }

# 4. .env readable via symlink + TELEGRAM_BOT_TOKEN non-empty
$envTok = Invoke-Hermes 'grep "^TELEGRAM_BOT_TOKEN=" /opt/data/.hermes/.env 2>/dev/null | cut -d= -f2 | wc -c'
if ($envTok -match "([3-9]\d|[1-9]\d{2,})") { if (Check ".env symlink + token" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check ".env symlink + token" "empty or missing") { $Pass++ } else { $Fail++ } }

# 5. Symlinks intact
$symOk = $true
foreach ($f in @("config.yaml", ".env", ".env.secrets", "cron/jobs.json")) {
    $link = Invoke-Hermes "readlink /opt/data/.hermes/$f 2>/dev/null || echo MISSING"
    if ($link -match "MISSING") {
        if (Check "Symlink .hermes/$f" "MISSING") { $Pass++ } else { $Fail++ }
        $symOk = $false
    }
}
if ($symOk) { if (Check "Symlinks (4)" "OK") { $Pass++ } else { $Fail++ } }

# 6. Model correct
# Main model is routed via the claudish proxy (po-2023), which remaps the claude-*
# family onto the fleet's inference budget. Accept any claude-* generation (the
# exact version moves with upstream syncs) plus the legacy glm-* names.
$model = Invoke-Hermes 'grep "^  default:" /opt/data/.hermes/config.yaml 2>/dev/null | head -1'
if ($model -match "claude-|glm-") { if (Check "Model" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Model" "$model") { $Pass++ } else { $Fail++ } }

# 7. MCP servers in config
$mcp = Invoke-Hermes 'grep -c "mcp_servers:" /opt/data/.hermes/config.yaml 2>/dev/null || echo 0'
if ($mcp -match "([1-9])") { if (Check "MCP servers" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "MCP servers" "not found") { $Pass++ } else { $Fail++ } }

# 8. jobs.json valid
$jobs = Invoke-Hermes 'python3 -c "import json; d=json.load(open(''/opt/data/.hermes/cron/jobs.json'')); print(len(d.get(''jobs'',[])))" 2>/dev/null || echo 0'
if ($jobs -match "([1-9]\d*)") { if (Check "Cron jobs ($jobs)" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Cron jobs" "none or invalid") { $Pass++ } else { $Fail++ } }

# 9. kanban.db writable (as hermes user)
$kanban = Invoke-Hermes 'python3 -c "
import sqlite3
conn=sqlite3.connect(''/opt/data/.hermes/kanban.db'')
conn.execute(''CREATE TABLE IF NOT EXISTS _wtest (id INTEGER)'')
conn.execute(''DROP TABLE IF EXISTS _wtest'')
conn.commit()
conn.close()
print(''OK'')" 2>/dev/null || echo FAIL'
if ($kanban -match "OK") { if (Check "Kanban DB writable" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Kanban DB writable" "$kanban") { $Pass++ } else { $Fail++ } }

# 10. gh auth
# docker exec does not inherit the gateway process env: GH_TOKEN must be sourced from
# /opt/data/.env explicitly, otherwise gh reports "not logged in" (false negative).
$gh = Invoke-Hermes 'export GH_TOKEN=$(grep "^GH_TOKEN=" /opt/data/.env | cut -d= -f2-); gh auth status 2>&1 | head -2'
if ($gh -match "Logged in") { if (Check "gh auth" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "gh auth" "$gh") { $Pass++ } else { $Fail++ } }

# 11. Cron enabled count
$enabled = Invoke-Hermes 'python3 -c "
import json
d=json.load(open(''/opt/data/.hermes/cron/jobs.json''))
active=[j for j in d.get(''jobs'',[]) if j.get(''enabled'',True)]
print(len(active))" 2>/dev/null || echo 0'
if ($enabled -ge 3) { if (Check "Active crons ($enabled)" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Active crons" "only $enabled") { $Pass++ } else { $Fail++ } }

# 12. MCP connection health (no recent "giving up" in logs)
# /opt/data/logs/gateways/default/ holds s6-log rotated files (@<tai64n>.u), not a
# "current" symlink — grep the rotated set plus the main agent log.
$mcpHealth = Invoke-Hermes 'cat /opt/data/logs/gateways/default/@* /opt/data/logs/agent.log 2>/dev/null | tail -300 | grep -c "giving up" || true'
$mcpHealth = ($mcpHealth -replace '\D','').Trim()
if ([string]::IsNullOrWhiteSpace($mcpHealth)) { $mcpHealth = "0" }
if ([int]$mcpHealth -eq 0) { if (Check "MCP health" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "MCP health" "$mcpHealth servers gave up") { $Pass++ } else { $Fail++ } }

# 13. config.yaml parses strictly (no duplicate top-level key)
# Incident 2026-10-07: the upstream default config grew a `memory:` key that our
# restore script re-appended -> DuplicateKeyError. The GATEWAY tolerates it (falls back
# to env/defaults) but the CRON SCHEDULER refuses every job at dispatch, so the cluster
# looked alive (process green, Telegram OK, reviews OK) while all 5 crons were dead ~9h45.
# Nothing in this script parsed the config, so 12/12 PASS was reported throughout.
# NB: no heredoc — this script is itself piped into `sh` on stdin (see Invoke-Hermes),
# so a `<<EOF` block would be consumed as commands. Single-quoted python, sh double-quoted.
$cfgParse = Invoke-Hermes @'
python3 -c "
import re, sys
p = '/opt/data/config.yaml'
keys = []
for line in open(p):
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):', line)
    if m: keys.append(m.group(1))
dup = sorted(k for k in set(keys) if keys.count(k) > 1)
if dup:
    print('DUPKEY:' + ','.join(dup)); sys.exit(0)
try:
    from ruamel.yaml import YAML
    y = YAML(typ='rt'); y.allow_duplicate_keys = False
    y.load(open(p))
    print('OK-strict')
except ImportError:
    print('OK-regex')
except Exception as e:
    print('PARSEERR:' + type(e).__name__)
" 2>/dev/null || echo PYFAIL
'@
if ($cfgParse -match "OK-") { if (Check "Config strict parse" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Config strict parse" "$cfgParse") { $Pass++ } else { $Fail++ } }

# 14. gateway process env carries ANTHROPIC_BASE_URL
# Incident 2026-10-07 (second layer): upstream's per-profile dynamic s6 service
# `gateway-default` respawns the gateway WITHOUT sourcing /opt/data/.env, unlike our
# main-wrapper. The gateway then silently fell back to the native Anthropic endpoint and
# every cron died on HTTP 401 `invalid x-api-key`. Presence of the var in
# /proc/<pid>/environ is the regression guard (the value is not printed — the same block
# holds the API key).
# Two gotchas, both measured: `docker exec` runs as root by default, but Docker drops
# CAP_SYS_PTRACE, so root gets EACCES reading another user's environ. The gateway runs as
# `hermes`, so the read must be done as that same user (-u hermes).
$gwEnv = Invoke-Hermes -User hermes @'
pid=$(ps aux | grep "[g]ateway run" | awk '{print $2}' | head -1)
if [ -z "$pid" ]; then echo NO_PID; exit 0; fi
n=$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep -c '^ANTHROPIC_BASE_URL=..*')
echo "ENVCHECK:$pid:$n"
'@
if ($gwEnv -match "ENVCHECK:\d+:[1-9]") { if (Check "Gateway env (base_url)" "OK") { $Pass++ } else { $Fail++ } }
else { if (Check "Gateway env (base_url)" "$gwEnv") { $Pass++ } else { $Fail++ } }

# Summary
Write-Host ""
if ($Fail -eq 0) {
    Write-Host "=== ALL $Pass CHECKS PASSED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "=== $Pass passed, $Fail FAILED ===" -ForegroundColor Red
    exit 1
}
