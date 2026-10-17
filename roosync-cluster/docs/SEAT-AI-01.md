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
| `hermes-pr-review` | `5,35 * * * *` | slots :00/:30 (recovery-doc offset :05/:35); NanoClaw's slots are NanoClaw's call — read them from its signed posts |
| `hermes-cluster-tour` | `13 */12 * * *` | posts `[CLUSTER-HEALTH] T#N` on global every fire (po-2026 cadence and format, numbering continued from T#163; prompt source `roosync-cluster/prompts/hermes-cluster-tour.prompt.md`) |
| `hermes-morning-brief` | `0 8 * * *` | 5-line bilan on Telegram |
| `ping-intercom` | every 30 min | light coordination check, SILENT on RAS |

**[ONLINE]** was posted on global by the seat (2026-10-14 11:37Z, then 17:02Z for the review lane
only). NanoClaw keeps reviewing on all 4 slots (`0,15,30,45`, compensation since 2026-10-10) until it
decides to revert to `15,45`; its gate also waits for Hermes Telegram. On 2026-10-15 the tour reported
that revert as done from the plan alone (T#165) — the tour prompt now says another lane's state is
reported only as measured (its signed posts or observed fires).

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
   (`NanoClaw-Watchdog`, `MCP-Chain-Watchdog`). Registered on ai-01: cron-output (:11/:41, 14/10), review
   (:07/:37, 15/10), cluster-tour (:19/:49, 16/10 — after its `[WARN]` was moved from a direct `global.md`
   write to a bus append). MCP watchdog: **not registered, by decision** (measured 16/10 16:4xZ):
   - Its premise is gone. The running image no longer lets a bridge die after 5 failed reconnects:
     `tools/mcp_tool_server_run.py` parks the server and self-probes every `_PARKED_RETRY_INTERVAL` = 300 s,
     for an initial-connect failure too (`_park`, #16788 / #57129). A bridge comes back by itself within
     ~5 min of the proxy's recovery. This was read in the code, not yet seen live: 0 `parking` lines in the
     bot's logs since 14/10.
   - Its Stage 1 is dead here. The pattern `hermes gateway run` matches no process in this container: the
     gateway is PID 386, a python with `argv[0]='hermes'`. Every recovery would therefore go straight to
     Stage 2 (`docker restart`) and kill in-flight jobs, while the bot heals on its own.
   - The blind spot it never covered (bridge up, backend dead, incident 2026-08-12→15) is ai-01's
     `MCP-Chain-Healthcheck` (roo-extensions; Ready, 0x0) plus routine check 6. No task named
     `MCP-Chain-Watchdog` exists here.

   At po-2026's return, check whether `Hermes-MCP-Watchdog` is still registered there. That image (06/10
   sync) has the same parking, so the same reasoning probably applies. Verify it there before deciding.
3. **Backup**: `hermes-backup.ps1` follows `%USERPROFILE%` (remapped 15/10), uses the local
   `alpine:3.19`, always restarts the container (`try/finally`) and has `-DryRun`. It STOPS the bot:
   run it when no job is in flight (`last_dispatch.dispatched_at` ≤ `last_run_at` for every enabled
   job in `cron/jobs.json`) — pr-review runs 10-30 min every 30 min, so the gaps are short. First real
   run 2026-10-15 07:30Z (546 MB, 148 s of downtime, taken between the end of a pr-review run and the
   next :35 fire). Snapshot again BEFORE any rebuild (incident precedent 2026-05-14).

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

## Live-config mitigations (volume `config.yaml`, not in the repo)

- **`agent.disabled_toolsets: [search]`** (2026-10-15 20:03Z): removes `web_search` from every cron run and keeps
  `web_extract`. It was applied because 5 pr-review runs in a row (17:46→19:38Z) ended on raw web-search hits with no
  report. In each of them the bot never ran `web_search`, and the hub's last turn carried 74–95 model tokens but
  2.8–4.3 k chars, so the search text was added outside the model's output. Confirmed by ai-01:claudish
  (2026-10-15 23:30Z): the hub treats only an exact `WebSearch` as a client tool, so it drops the bot's `web_search`
  call, runs SearXNG itself, injects the hits and ends the turn. The fix is assigned to po-2023 (claudish Refs #28;
  the three-way disposition PR is claudish #498, open 16/10 — remove this block only once it is merged AND deployed).
  **Placement rule (measured 2026-10-17):** the block MUST sit ABOVE `auxiliary:` in the volume `config.yaml` — the
  restore strips everything from the first `auxiliary:` line onward, and the machine reboot of 16/10 23:19Z silently
  deleted the end-of-file copy (bot unprotected ~2.6 h, no recurrence). Re-applied above `auxiliary:` with a comment
  saying why; also seeded in `roosync-cluster/config/config.ai-01.yaml`. Backups: `config.yaml.bak-20261015T2003Z`,
  `config.yaml.bak-20261017T0205Z`. The earlier claim "restore-config.sh never touches `agent:`" was wrong in effect.
  **Remove the block once claudish announces the fix is deployed.**

## Known seat defect — RooSync identity behind the proxy

Through mcp-remote → the ai-01 sparfenyuk proxy, the roo-state-manager process answers as its own identity
(`myia-ai-01:roo-extensions`). Measured 2026-10-16: the bot's `roosync_messages inbox` returned that lane's 860
messages, so `[nb-preaudit]` dossiers addressed to `myia-ai-01:hermes-agent` stay invisible to it, and its DMs go
out signed roo-extensions (dashboard appends are fine: they carry an explicit `author`). The fix is the `as`
assertion (#3591), which needs `myia-ai-01` in `ROOSYNC_TRUSTED_CALLER_IDS` of that process (its `.env` lists
`myia-po-2026` only). That `.env` belongs to roo-extensions: asked on the global dashboard, not applied.
