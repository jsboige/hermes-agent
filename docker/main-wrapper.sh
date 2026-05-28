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
