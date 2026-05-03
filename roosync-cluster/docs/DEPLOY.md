# Hermes Deployment Guide

**Issue:** #1862
**Version:** 2.0.0
**Date:** 2026-05-02

---

## Prerequisites

1. Docker + Docker Compose available (WSL2 on Windows, native on Linux)
2. z.ai API key for GLM models (dedicated Hermes key, not shared with nanoclaw)
3. MCP access via `https://mcp-tools.myia.io/roo-state-manager/mcp` (Bearer token required)

---

## Quick Deploy (Docker)

### 1. Clone the fork

```bash
git clone https://github.com/jsboige/hermes-agent.git /mnt/c/dev/hermes-agent
cd /mnt/c/dev/hermes-agent
git remote add upstream https://github.com/NousResearch/hermes-agent.git
```

### 2. Create config directory

```bash
mkdir -p ~/.hermes
```

### 3. Write `~/.hermes/.env`

```
GLM_API_KEY=<your-zai-key>
GLM_BASE_URL=https://api.z.ai/api/coding/paas/v4
```

**Important:** Use the **coding endpoint** (`/api/coding/paas/v4`), not the standard one (`/api/paas/v4`).

### 4. Write `~/.hermes/config.yaml`

Start minimal. Hermes will expand it on first run with all defaults:

```yaml
model:
  default: glm-5-turbo
  provider: zai
compression:
  enabled: true
  auxiliary_model: glm-4.5-air
mcp_servers:
  roo-state-manager:
    command: npx
    args:
      - -y
      - mcp-remote
      - https://mcp-tools.myia.io/roo-state-manager/mcp
      - --header
      - "Authorization:Bearer <bearer-token>"
```

**Critical:** After Hermes expands the config (~1027 lines), verify these sections remain intact:
- `model.default` and `model.provider` — may revert to defaults
- `mcp_servers` — may be lost during expansion
- `.env` file — may be overwritten by template during expansion

### 5. Build and start

```bash
# From WSL2 or Linux
cd /mnt/c/dev/hermes-agent
HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose up -d
```

### 6. Verify

```bash
docker logs hermes --tail 20
docker exec hermes /opt/hermes/.venv/bin/hermes -z "Bonjour, qui es-tu ?"
```

### 7. Test MCP access

```bash
docker exec hermes /opt/hermes/.venv/bin/hermes -z \
  "Call roosync_dashboard with action list. Report dashboard count."
```

---

## Known Issues

### Config expansion wipes settings

`hermes mcp remove` and similar commands expand config.yaml from ~15 lines to 1027+ lines, overwriting:

- Model settings (reverts to OpenAI defaults)
- `.env` file (replaces with template)
- MCP server configs (lost entirely)

**Workaround:** Always verify/restore these sections after any `hermes mcp` command.

### MCP stdio in Docker doesn't work for roo-state-manager

roo-state-manager reads host filesystem (Roo tasks in `%APPDATA%`, Qdrant on ai-01:6333). From Docker, only HTTP via `mcp-tools.myia.io` works. Never attempt stdio mounting.

### MCP connection timing

`hermes -z` one-shot mode may fail with "MCP connection is closed" on first attempt. Retry usually succeeds. The MCP connection takes ~12s to establish.

### Windows path mangling

`docker exec` from PowerShell mangles `/bin/sh` to Windows paths. Use `wsl -e bash -c "docker exec ..."` as a wrapper.

---

## Telegram Setup (Phase 6)

### 1. Create the bot

Message @BotFather on Telegram:

```text
/newbot
Name: MyIA Hermes
Username: @MyIAHermesBot
```

Copy the bot token.

### 2. Disable privacy mode

**CRITICAL — do this BEFORE adding the bot to any group.**

```text
/setprivacy → @MyIAHermesBot → Disable
```

Privacy settings are frozen at group-add time. If the bot is already in a group, you must remove it, disable privacy, then re-add it.

### 3. Configure environment

Inside the container, write to `/opt/data/.env`:

```text
TELEGRAM_BOT_TOKEN=<token>
TELEGRAM_ALLOWED_USERS=<your-telegram-user-id>
TELEGRAM_GROUP_ALLOWED_USERS=<your-telegram-user-id>
```

### 4. Configure config.yaml

The `telegram:` section inside the container's `/opt/data/config.yaml`:

```yaml
telegram:
  reactions: true
  require_mention: false
  group_allow_from:
    - '<your-telegram-user-id>'
  channel_prompts: {}
```

**Note:** All config edits must be done inside the container (WSL2 path divergence — Docker mounts from `/home/jesse/.hermes`, not `C:\Users\jsboi\.hermes`).

### 5. Restart and verify

```bash
docker restart hermes
docker logs hermes --tail 20
```

DM the bot on Telegram with `/start` or any message. Confirm response.

### 6. Add to group chat

Create or open a group (e.g. "MyIA Cluster"), add @MyIAHermesBot as member. Send a message — the bot should respond.

### 7. Set home channel

In the group chat, run `/sethome` to designate the group as the delivery target for cron results and system notifications.

### Telegram Channels

| Channel              | Mode          | Purpose                       |
|----------------------|---------------|-------------------------------|
| DM @MyIAHermesBot    | User-Hermes   | Commands, admin, queries      |
| DM @MyIANanoclawBot  | User-nanoclaw | Cluster manager interactions  |
| Group "MyIA Cluster" | 3-way chat    | Coordination, experimentation |

---

## Docker Architecture

```text
docker-compose.yml
  ├── gateway (hermes container, network_mode: host)
  │     - Volume: ~/.hermes:/opt/data
  │     - Command: gateway run
  │     - MCP: HTTP via mcp-remote → mcp-tools.myia.io
  │     - LLM: z.ai GLM-5-Turbo (coding endpoint)
  │
  └── dashboard (localhost:9119)
        - Volume: ~/.hermes:/opt/data
        - Command: dashboard --host 127.0.0.1 --no-open
```

---

## Cluster Status (validated 2026-05-02)

All 8 machines online, 0 offline, 0 warnings. po-2026 heartbeat confirmed active.

Hermes one-shot tests validated:

- GLM-5-Turbo connectivity via coding endpoint
- Cluster health reporting (read_overview)
- Task routing (TASK-ROUTE detection + routing analysis)
