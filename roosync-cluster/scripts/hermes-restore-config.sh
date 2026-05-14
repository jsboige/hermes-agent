#!/bin/bash
# Hermes post-rebuild config restore
# Usage: docker exec hermes bash /opt/data/restore-config.sh
# Or from host: ./roosync-cluster/scripts/hermes-restore-config.sh

set -e
DATA="/opt/data"

echo "Restoring Hermes deployment config..."

# 1. Overwrite model config (upstream resets to anthropic/claude-opus-4.6)
echo "  -> Setting model: glm-5-turbo (zai)"
sed -i 's/^  default: "anthropic\/claude-opus-4.6"/  default: "glm-5-turbo"\n  provider: "zai"/' "$DATA/config.yaml"

# 2. Ensure auxiliary compression is configured
if ! grep -q "^auxiliary:" "$DATA/config.yaml"; then
    echo "  -> Adding auxiliary compression (glm-4.5-air / zai)"
    cat >> "$DATA/config.yaml" << 'EOF'

# --- RooSync deployment config ---
auxiliary:
  compression:
    provider: "zai"
    model: "glm-4.5-air"
EOF
fi

# 3. Restore .env non-secret config
echo "  -> Restoring .env allowlists"
cat > "$DATA/.env" << 'EOF'
TELEGRAM_ALLOWED_USERS=6541428999
TELEGRAM_GROUP_ALLOWED_USERS=6541428999
TELEGRAM_HOME_CHANNEL=-1003904676273
GATEWAY_ALLOW_ALL_USERS=false
EOF

# 4. Fix ownership
chown hermes:hermes "$DATA/config.yaml" "$DATA/.env" 2>/dev/null || true

echo "Done. Restart container to apply: docker restart hermes"
