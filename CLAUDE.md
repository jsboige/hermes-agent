# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workspace Purpose

This workspace is dedicated to **deploying and operating the Hermes Agent platform** on machine `myia-po-2026`. It is part of the Myia AI cluster managed by RooSync.

**Upstream:** [nousresearch/hermes-agent](https://github.com/nousresearch/hermes-agent) → fork [jsboige/hermes-agent](https://github.com/jsboige/hermes-agent)
**Our drift:** `roosync-cluster/` directory (ADR, scripts, docs) — isolated from upstream code
**Epic:** roo-extensions #1862 (Hermes Phase 2 — Bootstrap), parent #1864 (Cycle 26 — Cluster Expansion)

### Cluster context (RooSync)

| Workspace | Machine(s) | Role |
|-----------|------------|------|
| roo-extensions | ai-01, po-2023/24/25/26 | Code, MCPs, coordination |
| nanoclaw | web1 (ai-01 sessions) | Docker agents, IPC, ClusterManager Telegram bot |
| CoursIA | po-2023 | Training and courses |
| Argumentum | ai-01 | Logical argumentation |
| vllm / myia-open-webui | ai-01 | LLM inference |
| **hermes-agent** | **po-2026** | **Routing, audit, orchestration (THIS)** |

### Hermes orchestration role

Hermes is a **read-only** cluster coordinator: route tasks, track hand-offs, audit cluster health. See `.claude/CLAUDE.md` and `.claude/rules/` for the full orchestrator identity and protocols.

### Communication channels

- **Dashboard workspace:** `roosync_dashboard(type: "workspace", workspace: "hermes-agent")`
- **Dashboard global:** `roosync_dashboard(type: "global")` — routing + health reports
- **Cross-machine:** `roosync_send/read` for urgent notifications
- **Neighbor:** nanoclaw (ai-01) — mention via dashboard with `mentions: [{userId: {machineId: "myia-ai-01", workspace: "nanoclaw"}}]`

The upstream development guide lives in `AGENTS.md` and `CONTRIBUTING.md`. This file covers what's needed to work effectively in this repo.

---

## Build & Development Commands

```bash
# Install (first time)
uv venv .venv --python 3.11
source .venv/bin/activate  # Linux/WSL; Windows: .venv\Scripts\Activate.ps1
uv pip install -e ".[all,dev]"

# Install optional: browser tools
npm install

# Run the agent
hermes              # Interactive CLI
hermes --tui        # Ink-based TUI
hermes gateway      # Messaging gateway (Telegram, Discord, etc.)

# Tests — ALWAYS use the wrapper script, not pytest directly
scripts/run_tests.sh                                  # Full suite
scripts/run_tests.sh tests/gateway/                   # One directory
scripts/run_tests.sh tests/agent/test_foo.py::test_x  # One test
scripts/run_tests.sh -v --tb=long                     # With extra pytest flags

# If you must run pytest directly (Windows, IDE): use -n 4 and activate venv
python -m pytest tests/ -q -n 4

# TUI development (ui-tui/)
cd ui-tui && npm install
npm run dev          # Watch mode
npm run build        # Full build
npm run type-check   # tsc --noEmit
npm test             # vitest

# Diagnostics
hermes doctor
hermes version
```

### Key test constraints
- `scripts/run_tests.sh` enforces CI parity: TZ=UTC, LANG=C.UTF-8, credential env vars blanked, `-n 4` workers
- `tests/conftest.py` isolates `HERMES_HOME` to temp dirs — tests never write to `~/.hermes/`
- Integration tests are marked `@pytest.mark.integration` and excluded by default

---

## Architecture (Big Picture)

```
User message → AIAgent._run_agent_loop() (run_agent.py)
  ├── System prompt assembly (agent/prompt_builder.py)
  ├── LLM API call (OpenAI-compatible, any provider)
  ├── If tool_calls → dispatch via tools/registry.py → execute → loop
  ├── If text response → persist session → return
  └── Context compression if approaching token limit

CLI (cli.py) ──prompt_toolkit──> Interactive terminal
TUI (ui-tui/) ──stdio JSON-RPC──> tui_gateway/ ──> AIAgent
Gateway (gateway/run.py) ──platform adapters──> Telegram/Discord/Slack/WhatsApp/Signal/...
```

### File dependency chain
```
tools/registry.py  (no deps, imported by all tools)
       ↑
tools/*.py  (each calls registry.register() at import time)
       ↑
model_tools.py  (triggers tool discovery)
       ↑
run_agent.py, cli.py, batch_runner.py
```

### Key entry points

| File | Role |
|------|------|
| `run_agent.py` | `AIAgent` class — core conversation loop, tool dispatch |
| `cli.py` | `HermesCLI` — interactive CLI with prompt_toolkit |
| `model_tools.py` | Tool orchestration, `handle_function_call()` |
| `toolsets.py` | Tool groupings and platform presets |
| `hermes_state.py` | SQLite session store with FTS5 search |
| `hermes_cli/main.py` | CLI entry point, arg parsing, profile support |
| `hermes_cli/config.py` | Config management, `DEFAULT_CONFIG`, env var definitions |
| `hermes_cli/commands.py` | Central slash command registry (`COMMAND_REGISTRY`) |
| `gateway/run.py` | `GatewayRunner` — platform lifecycle, message routing |
| `agent/prompt_builder.py` | System prompt assembly (identity, skills, context, memory) |

### User configuration

| Path | Purpose |
|------|---------|
| `~/.hermes/config.yaml` | All settings (model, terminal, toolsets, compression...) |
| `~/.hermes/.env` | API keys and secrets ONLY |
| `~/.hermes/auth.json` | OAuth credentials |
| `~/.hermes/skills/` | Active skills |
| `~/.hermes/state.db` | SQLite session database |

### Profile system

Multiple isolated instances via `HERMES_HOME` override. All code must use `get_hermes_home()` from `hermes_constants` — never hardcode `~/.hermes`.

---

## Critical Gotchas

1. **Always `get_hermes_home()`, never `Path.home() / ".hermes"`** — breaks profiles. Use `display_hermes_home()` for user-facing messages.
2. **Never alter context mid-conversation** — breaks prompt caching. Changes to tools/skills/memory take effect next session by default.
3. **Gateway has TWO message guards** — new commands that must reach the runner while agent is blocked need to bypass both the base adapter queue and the gateway runner intercept.
4. **No `simple_term_menu`** in new code — has rendering bugs. Use `hermes_cli/curses_ui.py`.
5. **No ANSI `\033[K`** in spinner/display — leaks under prompt_toolkit. Use space-padding.
6. **Tool schemas must not reference tools from other toolsets** — those tools may be unavailable.
7. **Tests must not write to `~/.hermes/`** — `_isolate_hermes_home` autouse fixture redirects to temp.

---

## Platform Support

- **Primary**: Linux, macOS, WSL2
- **Native Windows**: Not supported — use WSL2
- **Android/Termux**: Supported via `.[termux]` extra

---

## Configuration Notes

Three config loaders exist — know which one you're in:

| Loader | Used by | Location |
|--------|---------|----------|
| `load_cli_config()` | CLI mode | `cli.py` |
| `load_config()` | Most CLI subcommands | `hermes_cli/config.py` |
| Direct YAML load | Gateway runtime | `gateway/run.py` + `gateway/config.py` |

---

## Deployment (po-2026)

### Docker

```bash
# Pull & run (basic)
docker run -d --name hermes \
  --restart unless-stopped \
  -v ~/.hermes:/opt/data \
  -p 8642:8642 \
  -p 9119:9119 \
  -e GATEWAY_HEALTH_URL=http://localhost:9119 \
  nousresearch/hermes-agent gateway run

# With browser tools (needs shared memory)
docker run -d --name hermes \
  --shm-size=1g \
  --cap-drop=ALL \
  ... nousresearch/hermes-agent gateway run
```

- Data volume: `/opt/data` → `~/.hermes`
- API server: port 8642 | Dashboard UI: port 9119
- RAM: 1-4 GB depending on tools | One container per profile
- Permissions: `HERMES_UID`/`HERMES_GID` to match host user

### z.ai provider (CRITICAL)

Use NATIVE z.ai (`provider: "zai"`, built-in `/api/paas/v4` endpoint). NEVER use `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic` — the Anthropic-compat translation layer causes MCP tool registry loss after compaction.

### Gateway service

```bash
hermes gateway setup    # Interactive: platform + token
hermes gateway install  # systemd (Linux) / launchd (macOS)
hermes gateway start / stop / status
```

### Telegram bring-up

1. @BotFather → `/newbot` → get token
2. `hermes gateway setup` → Telegram → paste token
3. DM bot to pair (first user = owner)

### Context compression

```yaml
compression:
  enabled: true
  auxiliary_model: "glm-4-flash"  # cheaper model for summaries
```

Watch for `tool_use_error` after compaction — restart session if seen.

### Cluster ASR

`https://whisper-api.myia.io/v1` — available for voice memo transcription, no token needed internally.
