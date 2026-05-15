#!/bin/bash
# Hermes post-rebuild config restore
# Usage: docker exec hermes bash /opt/data/restore-config.sh
# Or from host: ./roosync-cluster/scripts/hermes-restore-config.sh

set -e
DATA="/opt/data"

echo "Restoring Hermes deployment config..."

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
#     Line ~43 gets a second provider: "auto" under model: block — YAML takes the last one
#     This silently overrides our provider: "zai" on line 12!
echo "  -> Checking for duplicate provider: auto..."
grep -n '^ *provider: "auto"' "$DATA/config.yaml" | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    # Skip the first provider line (the one we just set to zai) — only comment out "auto" lines
    sed -i "${linenum}s|^ *provider: \"auto\"|  # provider: \"auto\"  # REMOVED: duplicate overrides zai|" "$DATA/config.yaml"
done

# 2. CRITICAL: Remove OpenRouter base_url contamination
#    Upstream config expansion injects: base_url: "https://openrouter.ai/api/v1"
#    This overrides z.ai provider routing → 401 errors
echo "  -> Checking for OpenRouter base_url contamination..."
if grep -q '^ *base_url: "https://openrouter.ai/api/v1"' "$DATA/config.yaml"; then
    echo "  -> FOUND OpenRouter base_url — commenting out"
    sed -i 's|^ *base_url: "https://openrouter.ai/api/v1"|#  base_url: "https://openrouter.ai/api/v1"  # REMOVED: use zai native, never openrouter|' "$DATA/config.yaml"
fi

# 3. Replace/add auxiliary section (all tasks to zai, not just compression)
echo "  -> Setting auxiliary tasks to z.ai..."
# Remove any existing RooSync deployment marker and everything after it
LINE=$(grep -n '# --- RooSync deployment config' "$DATA/config.yaml" | head -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
    head -n $((LINE - 1)) "$DATA/config.yaml" > /tmp/config_aux.yaml
    mv /tmp/config_aux.yaml "$DATA/config.yaml"
fi
# Also remove any stray approvals section at the end
LINE=$(grep -n '^approvals:' "$DATA/config.yaml" | tail -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
    head -n $((LINE - 1)) "$DATA/config.yaml" > /tmp/config_appr.yaml
    mv /tmp/config_appr.yaml "$DATA/config.yaml"
fi

cat >> "$DATA/config.yaml" << 'EOF'

# --- RooSync deployment config (2026-05-14) ---
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

# Auto-approve for gateway cron jobs (no user to approve in gateway mode)
# Without this, -e/-c flag commands get blocked → tool loops → SIGTERM crash
approvals:
  mode: off
  cron_mode: approve
EOF

# 4. Restore .env non-secret config
echo "  -> Restoring .env allowlists"
cat > "$DATA/.env" << 'EOF'
TELEGRAM_ALLOWED_USERS=6541428999
TELEGRAM_GROUP_ALLOWED_USERS=6541428999
TELEGRAM_HOME_CHANNEL=-1003904676273
GATEWAY_ALLOW_ALL_USERS=false
EOF

# 5. Fix jobs.json format (must be {"jobs": [...]}, not bare array)
echo "  -> Checking jobs.json format"
if [ -f "$DATA/cron/jobs.json" ]; then
    python3 -c "
import json
with open('$DATA/cron/jobs.json', 'r') as f:
    data = json.load(f)
if isinstance(data, list):
    with open('$DATA/cron/jobs.json', 'w') as f:
        json.dump({'jobs': data}, f, indent=2, ensure_ascii=False)
    print('  -> Fixed jobs.json: wrapped bare array in {\"jobs\": [...]}')
else:
    print('  -> jobs.json format OK')
" 2>/dev/null || echo "  -> Warning: could not check jobs.json format"
fi

# 6. Install gh CLI if missing
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

# 7. Fix ownership
chown hermes:hermes "$DATA/config.yaml" "$DATA/.env" "$DATA/cron/jobs.json" "$DATA/SOUL.md" 2>/dev/null || true

echo "Done. Restart container to apply: docker restart hermes"
