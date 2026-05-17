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

# 8. Fix ownership
chown hermes:hermes "$DATA/config.yaml" "$DATA/.env" "$DATA/cron/jobs.json" "$DATA/SOUL.md" 2>/dev/null || true

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

echo ""
if [ "$FAIL" = "0" ]; then
    echo "=== ALL $PASS CHECKS PASSED ==="
else
    echo "=== $PASS passed, $FAIL FAILED ==="
fi
echo "Done. Restart container to apply: docker restart hermes"
