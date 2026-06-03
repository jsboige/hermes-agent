# Patches to Re-apply After Upstream Sync

**Created:** 2026-06-02 (pre-sync reference)
**Purpose:** Exact diffs of our 4 fork patches against upstream, for re-application after merge.

---

## 1. Dockerfile — 2 insertions (after s6-rc.d COPY and after cont-init.d COPY)

### Patch A: CRLF strip for s6-overlay files

**Insert after line `COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/`:**

```dockerfile
# Strip CRLF from s6-overlay files (Windows git checkout may introduce \r)
RUN find /etc/s6-overlay/s6-rc.d -type f -exec sed -i 's/\r$//' {} +
```

### Patch B: RooSync cont-init.d scripts + CRLF strip

**Insert after line `COPY --chmod=0755 docker/cont-init.d/02-reconcile-profiles /etc/cont-init.d/02-reconcile-profiles`:**

```dockerfile
# RooSync: auto-backup critical files before restore
COPY --chmod=0755 docker/cont-init.d/012-roosync-backup /etc/cont-init.d/012-roosync-backup
# RooSync: restore custom deployment config from persistent volume
COPY --chmod=0755 docker/cont-init.d/013-roosync-restore /etc/cont-init.d/013-roosync-restore
# Strip CRLF from cont-init.d scripts (Windows git checkout may introduce \r)
RUN find /etc/cont-init.d -type f -exec sed -i 's/\r$//' {} +
```

---

## 2. docker/main-wrapper.sh — shebang + HOME override + .env loading

**Full patched file content:**

```bash
#!/command/with-contenv sh
# shellcheck shell=sh
# /opt/hermes/docker/main-wrapper.sh — wraps the container's CMD with
# the same argument-routing logic the pre-s6 entrypoint.sh used. Runs
# as /init's "main program" (Docker CMD) so it inherits stdin/stdout/
# stderr from the container.
#
# Routing:
#   no args                       → exec `hermes` (the default)
#   first arg is an executable    → exec it directly (sleep, bash, sh, …)
#   first arg is anything else    → exec `hermes <args>` (subcommand passthrough)
#
# We drop to the hermes user via `s6-setuidgid` so the supervised
# workload runs unprivileged (UID 10000 by default).
set -e

# Override HOME so s6-setuidgid hermes can write state/lock files.
# with-contenv injects HOME=/root from the Docker environment, but the
# hermes user (UID 10000) cannot write to /root/.  Point HOME at the
# persistent data volume instead.
export HOME="/opt/data"

cd /opt/data

# Load persistent .env (tokens, API keys) so they're available to the gateway
# and its child processes (cron terminal tool, gh CLI calls).
if [ -f /opt/data/.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /opt/data/.env
    set +a
fi

# shellcheck disable=SC1091
. /opt/hermes/.venv/bin/activate

if [ $# -eq 0 ]; then
    exec s6-setuidgid hermes hermes
fi

if command -v "$1" >/dev/null 2>&1; then
    # Bare executable — pass through directly.
    exec s6-setuidgid hermes "$@"
fi

# Hermes subcommand pass-through.
exec s6-setuidgid hermes hermes "$@"
```

**Key differences from upstream:**
1. Shebang: `#!/command/with-contenv sh` (upstream uses `#!/bin/sh`)
2. `# shellcheck shell=sh` added
3. `export HOME="/opt/data"` added before `cd /opt/data`
4. `.env` loading block added (`set -a`, source, `set +a`)

---

## 3. .gitattributes — LF enforcement for shell scripts

**Append to file:**

```
# Shell scripts must use LF — CRLF breaks shebang in Docker/Linux
*.sh text eol=lf
docker/entrypoint.sh text eol=lf
```

---

## 4. docker/cont-init.d/012-roosync-backup + 013-roosync-restore

These are **our files only** — they don't exist upstream, so they survive the merge automatically.

- `docker/cont-init.d/012-roosync-backup` — Auto-backup critical files on boot (before restore)
- `docker/cont-init.d/013-roosync-restore` — Shim that invokes `/opt/data/restore-config.sh`

---

## 5. roosync-cluster/scripts/hermes-restore-config.sh — XDG_STATE_HOME + HOME in s6 env

**Our file only** — doesn't exist upstream. Survives merge automatically.

Key additions (search for `XDG_STATE_HOME`):

1. In `.env` section (~line 237): `XDG_STATE_HOME=/opt/data/.local/state`
2. In s6 env injection section (~line 356-361):

   ```bash
   printf '/opt/data/.local/state' > "$S6_ENV/XDG_STATE_HOME"
   printf '/opt/data' > "$S6_ENV/HOME"
   ```

**Why:** `gateway/status.py` line 68 uses `Path.home()` when `XDG_STATE_HOME` is unset. s6-overlay injects `HOME=/root` → lock files under `/root/.local/state/` → Permission denied for hermes user. Setting both in s6 container environment ensures `with-contenv` scripts get the right paths.
