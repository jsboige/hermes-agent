#!/bin/bash
# Hermes post-rebuild config restore
# Usage: docker exec hermes bash /opt/data/restore-config.sh
# Or from host: ./roosync-cluster/scripts/hermes-restore-config.sh
#
# Secrets are NEVER hardcoded here. They come from:
#   1. /opt/data/.env.secrets (if present — copy from host .env.secrets before running)
#   2. Environment variables (Docker -e flags)

set -e
DATA="/opt/data"
SECRETS_FILE="$DATA/.env.secrets"

echo "Restoring Hermes deployment config..."

# 0. Load secrets from file if present, otherwise use env vars
if [ -f "$SECRETS_FILE" ]; then
    echo "  -> Loading secrets from $SECRETS_FILE"
    set -a
    source "$SECRETS_FILE"
    set +a
else
    echo "  -> No .env.secrets file, using environment variables"
fi

# 1. Overwrite model config (upstream resets to anthropic/claude-opus-4.6)
echo "  -> Setting model: glm-5-turbo (zai)"
sed -i 's/^  default: "anthropic\/claude-opus-4.6"/  default: "glm-5-turbo"/' "$DATA/config.yaml"

# Ensure provider is set to zai
if grep -q '^  provider:' "$DATA/config.yaml"; then
    sed -i 's/^  provider: "auto"/  provider: "zai"/' "$DATA/config.yaml"
    sed -i 's/^  provider: "openrouter"/  provider: "zai"/' "$DATA/config.yaml"
else
    sed -i '/^  default: "glm-5-turbo"/a\  provider: "zai"' "$DATA/config.yaml"
fi

# 1b. CRITICAL: Remove DUPLICATE provider: "auto" that upstream expansion adds
echo "  -> Checking for duplicate provider: auto..."
grep -n '^ *provider: "auto"' "$DATA/config.yaml" | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    sed -i "${linenum}s|^ *provider: \"auto\"|  # provider: \"auto\"  # REMOVED: duplicate overrides zai|" "$DATA/config.yaml"
done

# 2. Remove OpenRouter base_url contamination
echo "  -> Checking for OpenRouter base_url contamination..."
if grep -q '^ *base_url: "https://openrouter.ai/api/v1"' "$DATA/config.yaml"; then
    echo "  -> FOUND OpenRouter base_url — commenting out"
    sed -i 's|^ *base_url: "https://openrouter.ai/api/v1"|#  base_url: "https://openrouter.ai/api/v1"  # REMOVED: use zai native|' "$DATA/config.yaml"
fi

# 3. Replace/add RooSync deployment section
# Remove ALL RooSync sections (from previous runs) and original upstream sections
# that we override, to prevent YAML duplicate key errors.
echo "  -> Removing old RooSync and upstream sections..."
LINE=$(grep -n '# --- RooSync deployment config' "$DATA/config.yaml" | head -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
    head -n $((LINE - 1)) "$DATA/config.yaml" > /tmp/config_strip.yaml
    mv /tmp/config_strip.yaml "$DATA/config.yaml"
fi
# Remove original auxiliary: section (upstream) — we replace it
LINE=$(grep -n '^auxiliary:' "$DATA/config.yaml" | head -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
    head -n $((LINE - 1)) "$DATA/config.yaml" > /tmp/config_aux.yaml
    mv /tmp/config_aux.yaml "$DATA/config.yaml"
fi
# Remove original stt: section (upstream) — we replace it
LINE=$(grep -n '^stt:' "$DATA/config.yaml" | head -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
    head -n $((LINE - 1)) "$DATA/config.yaml" > /tmp/config_stt.yaml
    mv /tmp/config_stt.yaml "$DATA/config.yaml"
fi
# Remove any approvals: section
LINE=$(grep -n '^approvals:' "$DATA/config.yaml" | tail -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
    head -n $((LINE - 1)) "$DATA/config.yaml" > /tmp/config_appr.yaml
    mv /tmp/config_appr.yaml "$DATA/config.yaml"
fi

# Require secrets — NO hardcoded fallbacks
STT_API_KEY="${WHISPER_BEARER_TOKEN:-}"
MCP_AUTH="${MCP_AUTH_TOKEN:-}"
if [ -z "$STT_API_KEY" ]; then echo "ERROR: WHISPER_BEARER_TOKEN not set (add to .env.secrets)"; exit 1; fi
if [ -z "$MCP_AUTH" ]; then echo "ERROR: MCP_AUTH_TOKEN not set (add to .env.secrets)"; exit 1; fi

cat >> "$DATA/config.yaml" << EOF

# --- RooSync deployment config (2026-05-16) ---
# All auxiliary tasks use z.ai provider (openrouter/nous cause 401 in gateway)
auxiliary:
  compression:
    provider: "zai"
    model: "glm-4.5-air"
  image:
    provider: "zai"
  browser:
    provider: "zai"
  web:
    provider: "zai"

# STT — Cluster Whisper endpoint (self-hosted on po-2023, OpenAI-compatible)
stt:
  enabled: true
  provider: "openai"
  openai:
    model: "whisper-1"
    base_url: "https://whisper-api.myia.io/v1"
    api_key: "${STT_API_KEY}"

# MCP servers — LAN direct (bypass IIS ARR pool issues on po-2023)
mcp_servers:
  roo-state-manager:
    command: npx
    args:
      - -y
      - mcp-remote
      - http://192.168.0.47:9090/roo-state-manager/mcp
      - --allow-http
      - --header
      - "Authorization:Bearer ${MCP_AUTH}"
  sk-agent:
    command: npx
    args:
      - -y
      - mcp-remote
      - http://192.168.0.47:9090/sk-agent/mcp
      - --allow-http
      - --header
      - "Authorization:Bearer ${MCP_AUTH}"
  searxng:
    command: npx
    args:
      - -y
      - mcp-remote
      - http://192.168.0.47:9090/searxng/mcp
      - --allow-http
      - --header
      - "Authorization:Bearer ${MCP_AUTH}"

# Auto-approve for gateway cron jobs (no user to approve in gateway mode)
approvals:
  mode: off
  cron_mode: approve
EOF

# 4. Restore .env — non-secret config + secrets from env/file
echo "  -> Restoring .env with all tokens"
cat > "$DATA/.env" << EOF
TELEGRAM_ALLOWED_USERS=6541428999
TELEGRAM_GROUP_ALLOWED_USERS=6541428999
TELEGRAM_HOME_CHANNEL=-1003904676273
GATEWAY_ALLOW_ALL_USERS=false

# z.ai / GLM provider
GLM_API_KEY=${GLM_API_KEY:-}
GLM_BASE_URL=${GLM_BASE_URL:-https://api.z.ai/api/coding/paas/v4}

# Telegram bot
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}

# GitHub tokens
GH_TOKEN_CLUSTERMANAGER=${GH_TOKEN_CLUSTERMANAGER:-}
GH_TOKEN_JSBOIGEEPITA=${GH_TOKEN_JSBOIGEEPITA:-}
GH_TOKEN_JSBOIGE=${GH_TOKEN_JSBOIGE:-}
GH_TOKEN=${GH_TOKEN_CLUSTERMANAGER:-}
EOF

# 5. Fix jobs.json format
echo "  -> Checking jobs.json format"
if [ -f "$DATA/cron/jobs.json" ]; then
    python3 -c "
import json
with open('$DATA/cron/jobs.json', 'r') as f:
    data = json.load(f)
if isinstance(data, list):
    data = {'jobs': data}
for job in data.get('jobs', []):
    sched = job.get('schedule')
    if isinstance(sched, str):
        job['schedule'] = {'kind': 'cron', 'expr': sched, 'display': sched}
    if job.get('repeat') == 'forever':
        job['repeat'] = None
    # Remove toolset restrictions — cluster crons need full access
    if 'enabled_toolsets' in job:
        del job['enabled_toolsets']
    # Re-enable paused jobs
    if job.get('enabled') is False:
        job['enabled'] = True
        job.pop('paused_at', None)
        job.pop('paused_reason', None)
        job['state'] = 'scheduled'
    # Enforce 30min interval for ping-intercom (alternance with NanoClaw :15,:45)
    if 'ping-intercom' in job.get('name', '') and job.get('schedule', {}).get('kind') == 'interval':
        job['schedule']['minutes'] = 30
        job['schedule']['display'] = 'every 30m'
        job['schedule_display'] = 'every 30m'
with open('$DATA/cron/jobs.json', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('  -> jobs.json OK')
" 2>/dev/null || echo "  -> Warning: could not check jobs.json format"
fi

# 6. Install croniter
echo "  -> Checking croniter"
/opt/hermes/.venv/bin/python3 -c 'import croniter' 2>/dev/null && echo "  -> croniter already installed" || {
    echo "  -> Installing croniter..."
    uv pip install --python /opt/hermes/.venv/bin/python3 --force-reinstall croniter 2>/dev/null && echo "  -> croniter installed" || echo "  -> Warning: croniter install failed"
}

# 7. Install gh CLI if missing
echo "  -> Checking gh CLI"
if ! command -v gh &>/dev/null; then
    echo "  -> Installing gh CLI..."
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq 2>/dev/null && apt-get install -y -qq gh 2>/dev/null
    gh --version 2>/dev/null && echo "  -> gh CLI installed" || echo "  -> Warning: gh CLI install failed"
else
    echo "  -> gh CLI already installed: $(gh --version 2>/dev/null | head -1)"
fi

# 7b. Install jq if missing
echo "  -> Checking jq"
if ! command -v jq &>/dev/null; then
    echo "  -> Installing jq..."
    apt-get update -qq 2>/dev/null && apt-get install -y -qq jq 2>/dev/null
    jq --version 2>/dev/null && echo "  -> jq installed" || echo "  -> Warning: jq install failed"
else
    echo "  -> jq already installed: $(jq --version 2>/dev/null)"
fi

# 7c. gh auth login with GH_TOKEN (persists to /opt/data so it survives restarts)
echo "  -> Configuring gh CLI auth"
GH_TOKEN_VAL="${GH_TOKEN_CLUSTERMANAGER:-}"
if [ -n "$GH_TOKEN_VAL" ]; then
    # Persist gh config to /opt/data so it survives container restarts
    mkdir -p /opt/data/.config/gh
    ln -sf /opt/data/.config/gh /root/.config/gh 2>/dev/null || true
    echo "$GH_TOKEN_VAL" | gh auth login --with-token 2>/dev/null || true
    if gh auth status &>/dev/null; then
        echo "  -> gh auth configured (token from GH_TOKEN_CLUSTERMANAGER)"
    else
        echo "  -> Warning: gh auth login failed"
    fi
else
    # Try reusing existing auth if already in /opt/data/.config/gh
    if [ -d "/opt/data/.config/gh" ]; then
        ln -sf /opt/data/.config/gh /root/.config/gh 2>/dev/null || true
        if gh auth status &>/dev/null; then
            echo "  -> gh auth restored from /opt/data/.config/gh"
        else
            echo "  -> Warning: GH_TOKEN_CLUSTERMANAGER not set, gh auth not configured"
        fi
    else
        echo "  -> Warning: GH_TOKEN_CLUSTERMANAGER not set, gh auth not configured"
    fi
fi

# 8. Inject secrets into s6 container environment so they're available
# to the CMD (main-wrapper.sh) via with-contenv, and thus to cron terminal tool.
S6_ENV="/run/s6/container_environment"
if [ -d "$S6_ENV" ]; then
    for var in GLM_API_KEY TELEGRAM_BOT_TOKEN GH_TOKEN_CLUSTERMANAGER GH_TOKEN_JSBOIGEEPITA GH_TOKEN_JSBOIGE GH_TOKEN MCP_AUTH_TOKEN WHISPER_BEARER_TOKEN; do
        val="${!var:-}"
        if [ -n "$val" ]; then
            printf '%s' "$val" > "$S6_ENV/$var"
        fi
    done
    echo "  -> Secrets injected into s6 container environment"
fi

# 8a. Fix ownership
chown hermes:hermes "$DATA/config.yaml" "$DATA/.env" "$DATA/cron/jobs.json" "$DATA/SOUL.md" "$DATA/.config" "$DATA/kanban.db" "$DATA/kanban.db-wal" "$DATA/kanban.db-shm" 2>/dev/null || true

# 8b. Symlink config files into hermes home (~/.hermes = $DATA/.hermes/)
# Hermes reads config from ~/.hermes/ but restore writes to $DATA/ (volume root).
HERMES_HOME="$DATA/.hermes"
mkdir -p "$HERMES_HOME/cron" 2>/dev/null || true
ln -sf "$DATA/config.yaml" "$HERMES_HOME/config.yaml" 2>/dev/null || true
ln -sf "$DATA/.env" "$HERMES_HOME/.env" 2>/dev/null || true
ln -sf "$DATA/.env.secrets" "$HERMES_HOME/.env.secrets" 2>/dev/null || true
ln -sf "$DATA/cron/jobs.json" "$HERMES_HOME/cron/jobs.json" 2>/dev/null || true

# 8b. Patch kanban SCHEMA_SQL — remove premature CREATE INDEX for session_id
# Upstream bug: SCHEMA_SQL has CREATE INDEX on session_id before migration adds the column
KANBAN_FILE="/opt/hermes/hermes_cli/kanban_db.py"
if [ -f "$KANBAN_FILE" ]; then
    echo "  -> Patching kanban SCHEMA_SQL (session_id index)"
    # Comment out the premature index creation
    if grep -q 'CREATE INDEX IF NOT EXISTS idx_tasks_session_id ON tasks(session_id)' "$KANBAN_FILE"; then
        sed -i 's|CREATE INDEX IF NOT EXISTS idx_tasks_session_id ON tasks(session_id)|-- CREATE INDEX IF NOT EXISTS idx_tasks_session_id ON tasks(session_id)  -- PATCHED: migration creates it after ALTER TABLE|' "$KANBAN_FILE"
        # Clear __pycache__ so patch takes effect
        find /opt/hermes -name '*.pyc' -delete 2>/dev/null || true
        find /opt/hermes -name '__pycache__' -type d -empty -delete 2>/dev/null || true
        echo "  -> Kanban SCHEMA_SQL patched"
    else
        echo "  -> Kanban SCHEMA_SQL already patched (or upstream fixed)"
    fi
else
    echo "  -> Warning: kanban_db.py not found at $KANBAN_FILE"
fi

# 9. Verify everything
echo ""
echo "=== VERIFICATION ==="
PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"
    if [ "$result" = "OK" ]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label — $result"
        FAIL=$((FAIL + 1))
    fi
}

# Model
MODEL=$(grep '^  default:' "$DATA/config.yaml" | head -1)
[[ "$MODEL" == *glm-5-turbo* ]] && check "Model" "OK" || check "Model" "got: $MODEL"

# YAML valid (no duplicate keys)
DUP_AUX=$(grep -c '^auxiliary:' "$DATA/config.yaml")
DUP_STT=$(grep -c '^stt:' "$DATA/config.yaml")
DUP_MCP=$(grep -c '^mcp_servers:' "$DATA/config.yaml")
DUP_APPR=$(grep -c '^approvals:' "$DATA/config.yaml")
if [ "$DUP_AUX" -le 1 ] && [ "$DUP_STT" -le 1 ] && [ "$DUP_MCP" -le 1 ] && [ "$DUP_APPR" -le 1 ]; then
    check "YAML no duplicate keys" "OK"
else
    check "YAML duplicates" "aux=$DUP_AUX stt=$DUP_STT mcp=$DUP_MCP appr=$DUP_APPR"
fi

# Provider
PROV=$(grep '^  provider:' "$DATA/config.yaml" | head -1)
[[ "$PROV" == *zai* ]] && check "Provider" "OK" || check "Provider" "got: $PROV"

# No duplicate provider: auto
DUP=$(grep -c '^ *provider: "auto"' "$DATA/config.yaml" || true)
[ "$DUP" = "0" ] && check "No duplicate provider:auto" "OK" || check "No duplicate provider:auto" "found $DUP"

# No OpenRouter contamination
OR_URL=$(grep -c 'openrouter.ai' "$DATA/config.yaml" || true)
[ "$OR_URL" = "0" ] && check "No OpenRouter base_url" "OK" || check "No OpenRouter base_url" "found $OR_URL"

# Auxiliary
AUX=$(grep -c 'provider: "zai"' "$DATA/config.yaml")
[ "$AUX" -ge 4 ] && check "Auxiliary providers (zai)" "OK" || check "Auxiliary providers" "only $AUX zai entries"

# STT
STT=$(grep -c 'whisper-api.myia.io' "$DATA/config.yaml")
[ "$STT" -ge 1 ] && check "STT endpoint" "OK" || check "STT endpoint" "not found"

# MCP servers
MCPS=$(grep -c 'mcp_servers:' "$DATA/config.yaml")
[ "$MCPS" -ge 1 ] && check "MCP servers section" "OK" || check "MCP servers section" "not found"
MCP_COUNT=$(grep -c '192.168.0.47:9090' "$DATA/config.yaml")
[ "$MCP_COUNT" -ge 3 ] && check "MCP bridges (3)" "OK" || check "MCP bridges" "only $MCP_COUNT"

# Approvals
APPR=$(grep -c 'cron_mode: approve' "$DATA/config.yaml")
[ "$APPR" -ge 1 ] && check "Approvals (cron_mode)" "OK" || check "Approvals" "not found"

# .env secrets
for tok in GLM_API_KEY TELEGRAM_BOT_TOKEN GH_TOKEN_CLUSTERMANAGER; do
    VAL=$(grep "^${tok}=" "$DATA/.env" | cut -d= -f2)
    [ -n "$VAL" ] && check ".env $tok" "OK" || check ".env $tok" "EMPTY"
done

# jobs.json
if [ -f "$DATA/cron/jobs.json" ]; then
    JOBS=$(python3 -c "import json; d=json.load(open('$DATA/cron/jobs.json')); print(len(d.get('jobs',[])))" 2>/dev/null || echo 0)
    [ "$JOBS" -ge 1 ] && check "Cron jobs ($JOBS)" "OK" || check "Cron jobs" "found $JOBS"
    TOOLSETS=$(python3 -c "import json; d=json.load(open('$DATA/cron/jobs.json')); print(sum(1 for j in d.get('jobs',[]) if 'enabled_toolsets' in j))" 2>/dev/null || echo "?")
    [ "$TOOLSETS" = "0" ] && check "No enabled_toolsets restrictions" "OK" || check "No enabled_toolsets" "$TOOLSETS jobs have restrictions"
else
    check "Cron jobs" "jobs.json not found"
fi

# gh CLI
command -v gh &>/dev/null && check "gh CLI" "OK" || check "gh CLI" "not installed"

# croniter
/opt/hermes/.venv/bin/python3 -c 'import croniter' 2>/dev/null && check "croniter" "OK" || check "croniter" "not installed"

# jq
command -v jq &>/dev/null && check "jq" "OK" || check "jq" "not installed"

# gh auth
gh auth status &>/dev/null && check "gh auth" "OK" || check "gh auth" "not configured"

# gh config persisted
[ -d "/opt/data/.config/gh" ] && check "gh config persisted" "OK" || check "gh config persisted" "not found in /opt/data"

# kanban patch
if [ -f "$KANBAN_FILE" ]; then
    KPATCH=$(grep -c 'PATCHED: migration creates it' "$KANBAN_FILE" || true)
    [ "$KPATCH" -ge 1 ] && check "Kanban session_id patch" "OK" || check "Kanban session_id patch" "not applied"
fi

# Symlinks hermes home (config must be visible from ~/.hermes/)
SYMLINK_OK=0
for f in config.yaml .env .env.secrets cron/jobs.json; do
    TARGET="$DATA/.hermes/$f"
    if [ -L "$TARGET" ]; then
        LINK=$(readlink "$TARGET")
        SYMLINK_OK=$((SYMLINK_OK + 1))
    elif [ -f "$TARGET" ]; then
        check "Symlink .hermes/$f" "FILE EXISTS (not symlink)"
    else
        check "Symlink .hermes/$f" "MISSING"
    fi
done
[ "$SYMLINK_OK" -ge 4 ] && check "Symlinks hermes home ($SYMLINK_OK/4)" "OK" || check "Symlinks hermes home" "only $SYMLINK_OK/4"

# Kanban DB writable
KDB="$DATA/.hermes/kanban.db"
if [ -f "$KDB" ] || [ -L "$KDB" ]; then
    REAL_KDB=$(readlink -f "$KDB" 2>/dev/null || echo "$KDB")
    KW=$(/opt/hermes/.venv/bin/python3 -c "
import sqlite3
conn=sqlite3.connect('$REAL_KDB')
conn.execute('CREATE TABLE IF NOT EXISTS _write_test (id INTEGER)')
conn.execute('DROP TABLE IF EXISTS _write_test')
conn.commit()
conn.close()
print('OK')" 2>/dev/null || echo "FAIL: not writable as hermes")
    check "Kanban DB writable" "$KW"
else
    check "Kanban DB" "not found (will be created on first use)"
fi

# Gateway Telegram state (check after process has had time to start)
sleep 3
GS_FILE=""
for gf in "$DATA/.hermes/gateway_state.json" "$DATA/gateway_state.json"; do
    if [ -f "$gf" ]; then GS_FILE="$gf"; break; fi
done
if [ -n "$GS_FILE" ]; then
    GS=$(python3 -c "
import json
d=json.load(open('$GS_FILE'))
tg=d.get('platforms',{}).get('telegram',{}).get('state','unknown')
print(tg)" 2>/dev/null || echo "parse_error")
    [[ "$GS" == *"connected"* ]] && check "Telegram state" "OK" || check "Telegram state" "$GS"
else
    check "Gateway state" "not yet written (normal during boot)"
fi

echo ""
if [ "$FAIL" = "0" ]; then
    echo "=== ALL $PASS CHECKS PASSED ==="
else
    echo "=== $PASS passed, $FAIL FAILED ==="
fi
echo "Done. Restart container to apply: docker restart hermes"
