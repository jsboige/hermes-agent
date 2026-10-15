# Hermes Seat on myia-ai-01 — Runbook

**Created:** 2026-10-14 (by myia-ai-01:nanoclaw, on operator GO)
**Doctrine:** po-2026 HS, no ETA → ai-01 seat is **interim primary**. When po-2026
returns, its base restarts there and this seat becomes **failover** — never two
active pollers on @MyIAHermesBot.

---

## What is prepared (state at handoff)

| Piece | Where | Status |
|-------|-------|--------|
| Fork clone | `D:\hermes-agent` (branch `seat/ai-01`) | ✅ cloned from jsboige/hermes-agent@main + seat commits |
| Docker image | `hermes-agent:ai-01` | ✅ built from the fork (not the upstream image) |
| Volume seed | `C:\Users\MYIA\.hermes` | ✅ config.yaml seed, SOUL.md (seat variant), cron/jobs.json (4 jobs), scripts/, .env.secrets |
| Secrets | `roosync-cluster/config/.env.secrets` + volume copy | ✅ 6/7 filled from fleet sources (`D:\nanoclaw\.env`) — **TELEGRAM_BOT_TOKEN EMPTY** |
| Seat compose | `roosync-cluster/docker/docker-compose.ai-01.yml` | ✅ windows shape (no host network), dashboard 127.0.0.1:9119 |

Reachability validated from ai-01 Docker (2026-10-14): MCP proxy `192.168.0.47:9090` → 401 (UP,
auth-gated — the exact class the restore probe accepts) ; claudish hub `192.168.0.50:3000` → model
list (UP). No container-name conflict (`hermes`, `hermes-dashboard` free). Port 9119 free.

### Secrets provenance (filled 2026-10-14)

| Var | Source |
|-----|--------|
| `MCP_AUTH_TOKEN` | nanoclaw `MCP_PROXY_BEARER` (TBXark :9090, shared fleet bearer) |
| `WHISPER_BEARER_TOKEN` | nanoclaw `ASR_API_KEY` (whisper-api.myia.io — same key as NanoClaw STT) |
| `CLAUDISH_PROXY_KEY` | nanoclaw `ANTHROPIC_CUSTOM_HEADERS` x-proxy-key (64-hex, post-RX96) |
| `GH_TOKEN_CLUSTERMANAGER` / `GH_TOKEN_JSBOIGEEPITA` / `GH_TOKEN_JSBOIGE` | nanoclaw `.env` (same values as the NanoClaw bot) |

### The one missing secret — ⚠️ ACTION USER

`TELEGRAM_BOT_TOKEN` for **@MyIAHermesBot** lived only in po-2026's `.env.secrets` (unreachable;
not in nanoclaw, not in roo-extensions, not on G:). Recover it either way:

- **Now:** Telegram → @BotFather → `/mybots` → @MyIAHermesBot → **API Token** (shows the current
  token; no re-issue needed).
- **Later:** at po-2026's return, read `C:\Users\jsboi\.hermes\.env.secrets` there.

Fill it in **both** files: `D:\hermes-agent\roosync-cluster\config\.env.secrets` and
`C:\Users\MYIA\.hermes\.env.secrets`. Without it the gateway boots, model+MCP validate, but the
Telegram platform stays down (restore verification reports `TELEGRAM_BOT_TOKEN EMPTY`).

---

## Start (operator)

```powershell
cd D:\hermes-agent
# 1. Boot the stack (gateway + dashboard) — first boot expands the default config in the volume
docker compose -f roosync-cluster/docker/docker-compose.ai-01.yml up -d
# 2. Wait ~60 s (config expansion + s6 services), then run the full restore (secrets, model
#    routing claudish, MCP bridges, jobs directives, gh auth, verification)
.\roosync-cluster\scripts\hermes-restore.ps1
# 3. Apply
docker restart hermes
```

`hermes-restore.ps1` requires Docker running, the `hermes` container to exist (step 1), and
`roosync-cluster\config\.env.secrets` present — all true at handoff (after the token is filled).

## Verify

```powershell
docker logs hermes --tail 30                                  # s6 services up, gateway connected
docker exec hermes /opt/hermes/.venv/bin/hermes -z "Bonjour, qui es-tu ?"          # model via claudish
docker exec hermes /opt/hermes/.venv/bin/hermes -z "Call roosync_dashboard with action list. Report dashboard count."   # MCP
```

Then DM @MyIAHermesBot any message — it must answer. First pr-review fire at the next :05/:35;
first tour at the next `:37 */3`.

### Expected verification output (restore script)

All checks PASS except `Telegram state` until the token is filled. The cron block should report
**4 jobs** (hermes-pr-review, hermes-cluster-tour, hermes-morning-brief, ping-intercom) with the
#2505 / sequential / presence / README-totals directives injected (the script adds them to the
bootstrap prompts automatically — anchors are in place).

---

## Bootstrap jobs (4) — cadence & coordination

| Job | Schedule | Notes |
|-----|----------|-------|
| `hermes-pr-review` | `5,35 * * * *` | slots :00/:30 (recovery-doc offset :05/:35); NanoClaw holds :15/:45 after revert |
| `hermes-cluster-tour` | `13 */12 * * *` | posts `[CLUSTER-HEALTH] T#N` on global every fire (po-2026 cadence and format, numbering continued from T#163; prompt source `roosync-cluster/prompts/hermes-cluster-tour.prompt.md`) |
| `hermes-morning-brief` | `0 8 * * *` | 5-line bilan on Telegram |
| `ping-intercom` | every 30 min | light coordination check, SILENT on RAS |

**On first online tour, Hermes must post [ONLINE] on the global dashboard** (its SOUL says so) —
the nanoclaw seat watches for it to revert the NanoClaw review cadence `0,15,30,45` → `15,45`
(compensation in place since 2026-10-10; one-shot check armed 2026-10-15 09:41).

## Phase 2 (after validation — NOT for first boot)

1. **Self-check job** (12h, the durable surveillance layer 2): register the host status collector
   first — `roosync-cluster/scripts/hermes-status-collector.ps1` as a Windows scheduled task
   (30 min) writing `C:\Users\MYIA\.hermes\host-status\host-status.json`, copy
   `roosync-cluster/prompts/hermes-self-check.prompt.md` into the volume `scripts/`, then
   `inject_self_check_job.py` (idempotent). The job is po-2026-worded — adapt the seat name in the
   prompt before injecting.
2. **Watchdogs** (`hermes-mcp-watchdog.ps1`, `hermes-review-watchdog.ps1`,
   `hermes-cron-output-watchdog.ps1`, registered with `register-host-watchdog.ps1`): po-2026 paths and
   expectations — review each before registering on ai-01 (paths `C:\Users\jsboi\…` need
   remapping to `C:\Users\MYIA\…`). Check for collisions with existing ai-01 scheduled tasks
   (`NanoClaw-Watchdog`, `MCP-Chain-Watchdog`).
3. **Backup**: `hermes-backup.ps1` hardcodes po-2026 paths — remap before first use. Until then,
   the volume is un-snapshotted (incident precedent 2026-05-14 — snapshot BEFORE any rebuild).

## Failover switch (when po-2026 returns)

1. po-2026 base restarts there (its volume `C:\Users\jsboi\.hermes` should be intact).
2. Stop THIS gateway first: `docker compose -f roosync-cluster/docker/docker-compose.ai-01.yml stop gateway`
   (keep the dashboard if useful — read-only). One poller per bot token, always.
3. po-2026 Hermes posts [ONLINE]; ai-01 seat stands by, dashboard identity history continues on
   `workspace-hermes-agent` either way.
4. Token note: if po-2026's token differs from the one BotFather shows now (re-issued), the LAST
   started poller wins the getUpdates conflict — stop one before starting the other, always.

## Known deltas vs po-2026 (lost with the machine)

- **Cron job history** (`last_run_at`, streaks) and any job beyond the 4 bootstrapped (e.g.
  `inbox-poll`, `hermes-general-patrol`) — recreate on demand inside the agent (`hermes cron`).
- **Sessions / state.db / kanban** — fresh (the May-2026 incident playbook applies: persona and
  protocols live in SOUL.md, which IS preserved here).
- **Full review-skill edition** — lived in po-2026 `~/skills/github/myia-cluster-pr-review/`. The
  bootstrap prompt embeds the reduced edition v1.2.0 (from roo-extensions, 2026-10-06).
- **jsboigeEpita coverage** — skipped on this seat (reduced-edition protocol; token gap).
