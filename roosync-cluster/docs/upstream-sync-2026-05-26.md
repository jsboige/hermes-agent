# Upstream Sync — 2026-05-26

## Backup

- **Tag:** `pre-upstream-sync-20260526`
- **Branch:** `backup/pre-upstream-sync-20260526`
- **Commits ahead of upstream:** 624

## Strategy

Take upstream entirely, then re-apply our patches. Our code lives in `roosync-cluster/` and `.claude/` which upstream doesn't touch — those merge cleanly.

## Conflicts (16 total)

### i18n files (15) — MECHANICAL
All `web/src/i18n/*.ts` files. Take upstream version — they added new translation keys.

### Dockerfile (1) — TAKE UPSTREAM
Upstream migrated from tini/gosu to s6-overlay:
- `/init` is PID 1 (replaces tini)
- `s6-setuidgid` replaces gosu for privilege drop
- `docker/stage2-hook.sh` replaces our `docker/entrypoint.sh` for boot config
- New: `docker/main-wrapper.sh` handles arg routing
- New: `docker/cont-init.d/` for s6 service wiring

Our entrypoint.sh (tini/gosu) is superseded. **Take upstream Dockerfile entirely.**

## Post-merge patches

### Patch 1: .gitignore — add .env.secrets
Add `roosync-cluster/config/.env.secrets` to .gitignore. Should merge cleanly, but verify after.

### Patch 2: Restore script integration with s6-overlay
Our `roosync-cluster/scripts/hermes-restore-config.sh` runs inside the container. Currently invoked by `docker/entrypoint.sh` (old tini/gosu version). After merge:

- The upstream `docker/entrypoint.sh` is now a thin s6 shim
- Config bootstrap happens in `docker/stage2-hook.sh` (cont-init.d)
- Our restore script should be called from `docker/stage2-hook.sh` OR from a new cont-init.d script

**Option A (recommended):** Add a `docker/cont-init.d/03-roosync-restore` that calls our restore script:
```sh
#!/bin/sh
# RooSync cluster restore — runs after stage2-hook
if [ -f "/opt/data/restore-config.sh" ]; then
    bash /opt/data/restore-config.sh
fi
```

**Option B:** The restore script is already called from the CMD line in our docker run command:
```
bash -c bash /opt/data/restore-config.sh 2>&1; exec /usr/bin/tini -g -- ...
```
With s6-overlay, the equivalent would be to call it from stage2-hook.sh before services start.

### Patch 3: kanban session_id index
Our restore script already patches `kanban_db.py` at runtime (section 8b). This is ephemeral — survives restarts but not rebuilds. If upstream fixed it, the patch is a no-op (grep finds nothing to patch).

### Patch 4: gh/jq ephemeral installs
Already in restore script (sections 7, 7b). Installs at runtime, lost on rebuild. Not a merge concern.

## Files we OWN (no upstream conflict)

```
.claude/                          # Hermes orchestrator config
roosync-cluster/                  # Entire directory — scripts, docs, config templates
docker/entrypoint.sh.local        # Local override (untracked)
```

## Verification checklist post-merge

1. `git diff backup/pre-upstream-sync-20260526..main -- roosync-cluster/` — should show NO changes (our files untouched)
2. `git diff backup/pre-upstream-sync-20260526..main -- .claude/` — should show NO changes
3. Dockerfile is upstream version (s6-overlay)
4. `.gitignore` has `roosync-cluster/config/.env.secrets`
5. `docker/entrypoint.sh` is upstream shim
6. Restore script still runs correctly inside container
7. Test: `docker build` succeeds
8. Test: `docker run` starts with s6-overlay, restore script executes
