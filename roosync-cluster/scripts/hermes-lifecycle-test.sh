#!/bin/bash
# =============================================================================
# Hermes Container Lifecycle Diagnostic
# =============================================================================
# Tests ALL stages of the Hermes Docker container lifecycle to diagnose
# SIGTERM/crash-loop issues (typically ~15 min intervals).
#
# Usage:
#   ./hermes-lifecycle-test.sh                  # Full test, 20 min runtime monitor
#   ./hermes-lifecycle-test.sh -d 30            # Monitor for 30 minutes
#   ./hermes-lifecycle-test.sh --skip-start     # Skip container start (use running one)
#   ./hermes-lifecycle-test.sh --forensics-only # Only run crash forensics
#
# Requirements: docker, grep, jq, awk, sed (standard Linux/WSL tools)
# =============================================================================

set -uo pipefail

# --- Configuration ---
CONTAINER_NAME="hermes"
IMAGE_NAME="hermes-agent"
DATA_DIR="/opt/data"
HOST_DATA_DIR="${HOME}/.hermes"
GATEWAY_LOG="${DATA_DIR}/logs/gateway.log"
API_PORT=8642
DASHBOARD_PORT=9119
RUNTIME_MINUTES=20
SKIP_START=false
FORENSICS_ONLY=false
VERBOSE=false

# --- Expected config values ---
EXPECTED_MODEL="glm-5-turbo"
EXPECTED_PROVIDER="zai"
EXPECTED_AUX_MODEL="glm-4.5-air"
FORBIDDEN_BASE_URL="openrouter.ai"

# --- Color codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Counters ---
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
INFO_COUNT=0
CRASH_DETECTED=false
STARTUP_TIME=""

# --- Utility functions ---

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

pass()  { ((PASS_COUNT++));  echo -e "${GREEN}[PASS]${NC}  $1"; }
fail()  { ((FAIL_COUNT++));  echo -e "${RED}[FAIL]${NC}  $1"; }
warn()  { ((WARN_COUNT++));  echo -e "${YELLOW}[WARN]${NC}  $1"; }
info()  { ((INFO_COUNT++));  echo -e "${BLUE}[INFO]${NC}  $1"; }
header(){ echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
sub()   { echo -e "  ${CYAN}--- $1 ---${NC}"; }

# Run a command inside the container, handling path mangling
container_exec() {
    docker exec "$CONTAINER_NAME" bash -c "$1" 2>&1
}

# Check if container exists and is running
container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

# Get container exit code (0 if running)
container_exit_code() {
    docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "N/A"
}

# Get container status string
container_status() {
    docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not found"
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--duration)
            RUNTIME_MINUTES="$2"
            shift 2
            ;;
        --skip-start)
            SKIP_START=true
            shift
            ;;
        --forensics-only)
            FORENSICS_ONLY=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -d, --duration MIN     Runtime monitor duration (default: 20)"
            echo "  -n, --name NAME        Container name (default: hermes)"
            echo "  --skip-start           Use already-running container"
            echo "  --forensics-only       Only run crash forensics on existing container"
            echo "  -v, --verbose          Show extra detail"
            echo "  -h, --help             This help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# PHASE 1: PREFLIGHT CHECKS
# =============================================================================
phase_preflight() {
    header "PHASE 1: PREFLIGHT CHECKS"

    # 1.1 Docker daemon responsive
    sub "Docker daemon"
    if docker info >/dev/null 2>&1; then
        pass "Docker daemon is responsive"
    else
        fail "Docker daemon is NOT responsive — cannot proceed"
        return 1
    fi

    # 1.2 Docker Desktop Resource Saver status (Windows/WSL only)
    sub "Docker Desktop Resource Saver"
    # Check if running under Docker Desktop (has com.docker.backend process or WSL distro)
    if command -v wslpath >/dev/null 2>&1 || pgrep -f "com.docker.backend" >/dev/null 2>&1; then
        # Try to find Docker Desktop settings
        local dd_settings=""
        # WSL2 Docker Desktop settings
        if [ -f "/mnt/c/Users/$USER/AppData/Roaming/Docker/settings-store.json" ]; then
            dd_settings="/mnt/c/Users/$USER/AppData/Roaming/Docker/settings-store.json"
        elif [ -f "/mnt/c/Users/$USER/AppData/Roaming/Docker/settings.json" ]; then
            dd_settings="/mnt/c/Users/$USER/AppData/Roaming/Docker/settings.json"
        fi

        if [ -n "$dd_settings" ] && [ -f "$dd_settings" ]; then
            local rs_enabled
            rs_enabled=$(grep -o '"useResourceSaver"[[:space:]]*:[[:space:]]*true' "$dd_settings" 2>/dev/null)
            if [ -n "$rs_enabled" ]; then
                fail "Docker Desktop Resource Saver is ENABLED — this kills idle containers! Disable: Settings > Resources > Resource Saver"
            else
                pass "Docker Desktop Resource Saver appears disabled"
            fi
        else
            warn "Docker Desktop detected but settings file not found — manually verify Resource Saver is OFF"
        fi

        # Check monitor.log for Resource Saver kills
        local monitor_log=""
        for candidate in \
            "/mnt/c/Users/$USER/AppData/Local/Docker/log/monitor.log" \
            "/mnt/c/Users/$USER/AppData/Local/Docker/log/vm/monitor.log"; do
            if [ -f "$candidate" ]; then
                monitor_log="$candidate"
                break
            fi
        done

        if [ -n "$monitor_log" ]; then
            local recent_kills
            recent_kills=$(grep -i "resource.saver\|idle.*restart\|POST.*containers.*restart" "$monitor_log" 2>/dev/null | tail -5)
            if [ -n "$recent_kills" ]; then
                warn "Docker Desktop monitor.log shows recent restart activity:"
                echo "$recent_kills" | while read -r line; do
                    echo -e "    ${YELLOW}$line${NC}"
                done
            else
                pass "No Resource Saver kills in monitor.log"
            fi
        fi
    else
        info "Not running under Docker Desktop — Resource Saver check skipped"
    fi

    # 1.3 Image exists
    sub "Docker image"
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        local img_size
        img_size=$(docker image inspect "$IMAGE_NAME" --format '{{.Size}}' 2>/dev/null)
        local img_created
        img_created=$(docker image inspect "$IMAGE_NAME" --format '{{.Created}}' 2>/dev/null | cut -dT -f1)
        pass "Image '$IMAGE_NAME' exists (built: $img_created, size: $(( img_size / 1024 / 1024 )) MB)"
    else
        fail "Image '$IMAGE_NAME' not found — build with: docker compose build"
        return 1
    fi

    # 1.4 Volume mount path
    sub "Volume mount path ($HOST_DATA_DIR)"
    if [ -d "$HOST_DATA_DIR" ]; then
        pass "Volume mount path exists: $HOST_DATA_DIR"

        # Check write permission
        if touch "$HOST_DATA_DIR/.lifecycle-test-write" 2>/dev/null; then
            pass "Volume mount path is writable"
            rm -f "$HOST_DATA_DIR/.lifecycle-test-write"
        else
            fail "Volume mount path is NOT writable — container will fail to write state"
        fi
    else
        fail "Volume mount path does NOT exist: $HOST_DATA_DIR"
        warn "Create it with: mkdir -p $HOST_DATA_DIR"
    fi

    # 1.5 config.yaml exists and has correct settings
    sub "config.yaml validation"
    local config_path="$HOST_DATA_DIR/config.yaml"
    if [ -f "$config_path" ]; then
        pass "config.yaml exists at $config_path"

        # Check model.default
        local model
        model=$(grep -E '^\s+default:\s*"' "$config_path" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
        if [ "$model" = "$EXPECTED_MODEL" ]; then
            pass "model.default = '$EXPECTED_MODEL'"
        else
            fail "model.default = '$model' (expected '$EXPECTED_MODEL')"
        fi

        # Check provider — must have EXACTLY ONE active provider: "zai"
        local provider_count
        provider_count=$(grep -cE '^\s+provider:\s*"zai"' "$config_path")
        local auto_provider_count
        auto_provider_count=$(grep -cE '^\s+provider:\s*"(auto|openrouter)"' "$config_path")

        if [ "$provider_count" -ge 1 ] && [ "$auto_provider_count" -eq 0 ]; then
            pass "provider = 'zai' (no conflicting duplicates)"
        elif [ "$provider_count" -ge 1 ] && [ "$auto_provider_count" -gt 0 ]; then
            fail "provider = 'zai' found BUT $auto_provider_count duplicate provider:auto/openrouter line(s) exist — last one wins in YAML!"
            grep -n '^\s*provider:' "$config_path" | while read -r line; do
                echo -e "    ${RED}$line${NC}"
            done
        else
            fail "provider is NOT set to 'zai' (found $provider_count zai entries)"
        fi

        # Check for forbidden base_url (OpenRouter contamination)
        local bad_base
        bad_base=$(grep -n "$FORBIDDEN_BASE_URL" "$config_path" 2>/dev/null)
        if [ -z "$bad_base" ]; then
            pass "No OpenRouter base_url contamination"
        else
            fail "Found OpenRouter base_url — this overrides z.ai routing!"
            echo "$bad_base" | while read -r line; do
                echo -e "    ${RED}$line${NC}"
            done
        fi

        # Check auxiliary compression model
        local aux_model
        aux_model=$(grep -A2 'compression:' "$config_path" | grep 'model:' | head -1 | sed 's/.*:\s*"\?\([^"]*\)"\?.*/\1/' | tr -d ' ')
        if [ "$aux_model" = "$EXPECTED_AUX_MODEL" ]; then
            pass "auxiliary.compression.model = '$EXPECTED_AUX_MODEL'"
        else
            warn "auxiliary.compression.model = '$aux_model' (expected '$EXPECTED_AUX_MODEL')"
        fi

        # Check all auxiliary providers are zai
        local aux_non_zai
        aux_non_zai=$(grep -A1 'image:\|browser:\|web:' "$config_path" | grep 'provider:' | grep -v 'zai' | grep -v '^#')
        if [ -z "$aux_non_zai" ]; then
            pass "All auxiliary providers are zai"
        else
            warn "Some auxiliary providers are NOT zai (will default to OpenRouter):"
            echo "$aux_non_zai" | while read -r line; do
                echo -e "    ${YELLOW}$line${NC}"
            done
        fi

        # Check approvals configuration (gateway mode needs approvals off)
        local approvals_mode
        approvals_mode=$(grep -E '^\s+mode:\s*(off|deny|approve)' "$config_path" | head -1)
        if echo "$approvals_mode" | grep -q "off"; then
            pass "approvals.mode = off (required for gateway)"
        else
            warn "approvals.mode is NOT 'off' — cron tool approval blocks may cause SIGTERM loops"
        fi

        local cron_approvals
        cron_approvals=$(grep -E '^\s+cron_mode:\s*approve' "$config_path" | head -1)
        if [ -n "$cron_approvals" ]; then
            pass "approvals.cron_mode = approve"
        else
            warn "approvals.cron_mode is NOT 'approve' — cron -e/-c commands may block"
        fi
    else
        fail "config.yaml NOT found at $config_path"
        warn "Deployment config should be in roosync-cluster/config/config.yaml"
    fi

    # 1.6 .env exists with required vars
    sub ".env validation"
    local env_path="$HOST_DATA_DIR/.env"
    if [ -f "$env_path" ]; then
        pass ".env exists at $env_path"

        local required_env_vars=(
            "TELEGRAM_ALLOWED_USERS"
            "TELEGRAM_GROUP_ALLOWED_USERS"
            "TELEGRAM_HOME_CHANNEL"
            "GATEWAY_ALLOW_ALL_USERS"
        )

        for var in "${required_env_vars[@]}"; do
            if grep -q "^${var}=" "$env_path"; then
                pass ".env has $var"
            else
                fail ".env MISSING $var"
            fi
        done
    else
        fail ".env NOT found at $env_path"
    fi

    # 1.7 Port conflicts
    sub "Port conflicts"
    for port in "$API_PORT" "$DASHBOARD_PORT"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
            local listener
            listener=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 || netstat -tlnp 2>/dev/null | grep ":${port} " | head -1)
            if echo "$listener" | grep -q "docker"; then
                pass "Port $port in use by Docker (expected for running container)"
            else
                warn "Port $port in use by non-Docker process: $listener"
            fi
        else
            pass "Port $port is free"
        fi
    done

    # 1.8 Secrets via Docker env vars
    sub "Docker secret env vars"
    if container_running; then
        local required_secrets=(
            "TELEGRAM_BOT_TOKEN"
            "GLM_API_KEY"
        )
        for secret in "${required_secrets[@]}"; do
            local val
            val=$(container_exec "echo \$$secret" 2>/dev/null)
            if [ -n "$val" ] && [ "$val" != "" ] && [ ${#val} -gt 5 ]; then
                pass "Container has $secret set (${#val} chars)"
            else
                fail "Container MISSING $secret — pass via docker -e flag"
            fi
        done
    else
        info "Container not running — cannot check runtime env vars"
        info "Ensure docker run includes: -e TELEGRAM_BOT_TOKEN=... -e GLM_API_KEY=..."
    fi
}

# =============================================================================
# PHASE 2: CONTAINER START
# =============================================================================
phase_start() {
    header "PHASE 2: CONTAINER START"

    if [ "$SKIP_START" = true ]; then
        info "Skipping start (using existing container)"
        if container_running; then
            pass "Container '$CONTAINER_NAME' is already running (PID: $(docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME"))"
            return 0
        else
            fail "Container '$CONTAINER_NAME' is NOT running — cannot skip start"
            return 1
        fi
    fi

    # Check if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        info "Container '$CONTAINER_NAME' already exists — removing"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi

    # Start the container
    sub "Starting container"
    local start_time
    start_time=$(date +%s)

    # Use docker compose if available, otherwise docker run
    if [ -f "docker-compose.yml" ]; then
        info "Starting via docker compose..."
        HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose up -d 2>&1
    else
        info "Starting via docker run (no docker-compose.yml found)..."
        docker run -d \
            --name "$CONTAINER_NAME" \
            --restart unless-stopped \
            --network host \
            -v "${HOST_DATA_DIR}:${DATA_DIR}" \
            -e "HERMES_UID=$(id -u)" \
            -e "HERMES_GID=$(id -g)" \
            "$IMAGE_NAME" gateway run 2>&1
    fi

    if [ $? -ne 0 ]; then
        fail "Container start command failed"
        return 1
    fi

    # Wait for container to be running
    local waited=0
    local max_wait=30
    while [ $waited -lt $max_wait ]; do
        if container_running; then
            break
        fi
        sleep 1
        ((waited++))
    done

    local end_time
    end_time=$(date +%s)
    STARTUP_TIME=$(( end_time - start_time ))

    if container_running; then
        pass "Container started in ${STARTUP_TIME}s"
    else
        fail "Container did NOT start within ${max_wait}s"
        return 1
    fi

    # 2.1 Gateway process check
    sub "Gateway process"
    sleep 3  # Give process time to initialize
    local gateway_pid
    gateway_pid=$(container_exec "pgrep -f 'gateway run' | head -1" 2>/dev/null)
    if [ -n "$gateway_pid" ] && [ "$gateway_pid" != "" ]; then
        pass "Gateway process running (PID: $gateway_pid)"
    else
        # Try broader match
        gateway_pid=$(container_exec "pgrep -f 'python.*hermes' | head -1" 2>/dev/null)
        if [ -n "$gateway_pid" ] && [ "$gateway_pid" != "" ]; then
            pass "Hermes Python process running (PID: $gateway_pid)"
        else
            fail "No gateway/hermes process found inside container"
            # Show what IS running
            info "Processes in container:"
            container_exec "ps aux" | head -20 | while read -r line; do
                echo -e "    $line"
            done
        fi
    fi

    # 2.2 Telegram connection
    sub "Telegram connection"
    local telegram_connected=false
    local max_telegram_wait=30
    local waited=0
    while [ $waited -lt $max_telegram_wait ]; do
        if container_exec "tail -50 ${GATEWAY_LOG} 2>/dev/null | grep -qi 'connected to telegram\|telegram.*polling\|telegram.*started'"; then
            telegram_connected=true
            break
        fi
        sleep 2
        ((waited+=2))
    done

    if [ "$telegram_connected" = true ]; then
        pass "Telegram connection established"
    else
        warn "Telegram connection not detected within ${max_telegram_wait}s"
        info "Last 5 gateway.log lines:"
        container_exec "tail -5 ${GATEWAY_LOG} 2>/dev/null" | while read -r line; do
            echo -e "    $line"
        done
    fi

    # 2.3 MCP connections
    sub "MCP connections"
    local mcp_processes
    mcp_processes=$(container_exec "pgrep -fa mcp-remote" 2>/dev/null)
    if [ -n "$mcp_processes" ]; then
        local mcp_count
        mcp_count=$(echo "$mcp_processes" | wc -l)
        pass "$mcp_count MCP remote process(es) running"
        if [ "$VERBOSE" = true ]; then
            echo "$mcp_processes" | while read -r line; do
                echo -e "    $line"
            done
        fi
    else
        warn "No mcp-remote processes found — MCP may still be connecting"
    fi

    # Check MCP connection in gateway.log
    local mcp_log
    mcp_log=$(container_exec "grep -i 'mcp.*connect\|mcp.*ready\|mcp.*error' ${GATEWAY_LOG} 2>/dev/null | tail -5")
    if [ -n "$mcp_log" ]; then
        info "MCP log entries (last 5):"
        echo "$mcp_log" | while read -r line; do
            echo -e "    $line"
        done
    fi

    # 2.4 Cron scheduler
    sub "Cron scheduler"
    local cron_log
    cron_log=$(container_exec "grep -i 'cron.*start\|cron.*schedul\|cron.*loaded' ${GATEWAY_LOG} 2>/dev/null | tail -3")
    if [ -n "$cron_log" ]; then
        pass "Cron scheduler appears active"
        if [ "$VERBOSE" = true ]; then
            echo "$cron_log" | while read -r line; do
                echo -e "    $line"
            done
        fi
    else
        warn "No cron scheduler messages found in gateway.log"
    fi

    # Check jobs.json exists and has correct ownership
    local jobs_json="${DATA_DIR}/cron/jobs.json"
    local jobs_exists
    jobs_exists=$(container_exec "test -f $jobs_json && echo yes || echo no" 2>/dev/null)
    if [ "$jobs_exists" = "yes" ]; then
        pass "cron/jobs.json exists"
        local jobs_owner
        jobs_owner=$(container_exec "stat -c '%U:%G' $jobs_json" 2>/dev/null)
        if [ "$jobs_owner" = "hermes:hermes" ]; then
            pass "jobs.json owned by hermes:hermes"
        else
            fail "jobs.json owned by '$jobs_owner' (needs hermes:hermes) — Permission denied likely"
        fi

        # Validate JSON
        local jobs_valid
        jobs_valid=$(container_exec "python3 -c \"import json; json.load(open('$jobs_json'))\" 2>&1")
        if [ $? -eq 0 ]; then
            pass "jobs.json is valid JSON"
        else
            fail "jobs.json is NOT valid JSON: $jobs_valid"
        fi
    else
        warn "cron/jobs.json does NOT exist — no cron jobs configured"
    fi
}

# =============================================================================
# PHASE 3: RUNTIME STABILITY MONITOR
# =============================================================================
phase_runtime() {
    header "PHASE 3: RUNTIME STABILITY (${RUNTIME_MINUTES} min)"

    if ! container_running; then
        fail "Container is not running — cannot monitor"
        CRASH_DETECTED=true
        return 1
    fi

    local total_seconds=$(( RUNTIME_MINUTES * 60 ))
    local interval=30
    local elapsed=0
    local iterations=0
    local prev_restart_count
    prev_restart_count=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
    local prev_log_lines
    prev_log_lines=$(container_exec "wc -l < ${GATEWAY_LOG} 2>/dev/null" || echo "0")
    local error_count=0
    local sigterm_count=0

    echo ""
    info "Monitoring every ${interval}s for ${RUNTIME_MINUTES} min..."
    info "Press Ctrl+C to stop early (forensics will still run)"
    echo ""

    # Start Docker event monitoring in background
    local event_log_file
    event_log_file=$(mktemp /tmp/hermes-events.XXXXXX)
    docker events --filter "container=$CONTAINER_NAME" --format '{{.Time}} {{.Action}} {{.Actor.Attributes}}' > "$event_log_file" 2>/dev/null &
    local event_pid=$!

    # Trap to clean up background process
    trap "kill $event_pid 2>/dev/null; rm -f $event_log_file" EXIT

    while [ $elapsed -lt $total_seconds ]; do
        iterations=$((iterations + 1))
        local now
        now=$(timestamp)
        local mins_elapsed=$(( elapsed / 60 ))
        local secs_elapsed=$(( elapsed % 60 ))

        # Check container status
        if ! container_running; then
            echo -e "\n${RED}[$now] CRASH DETECTED at +${mins_elapsed}m${secs_elapsed}s!${NC}"
            CRASH_DETECTED=true
            break
        fi

        # Get metrics
        local mem_usage
        mem_usage=$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null | head -1)
        local cpu_pct
        cpu_pct=$(docker stats --no-stream --format '{{.CPUPerc}}' "$CONTAINER_NAME" 2>/dev/null | head -1)
        local current_restarts
        current_restarts=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo "?")

        # Check for new errors in gateway.log
        local current_log_lines
        current_log_lines=$(container_exec "wc -l < ${GATEWAY_LOG} 2>/dev/null" || echo "0")
        local new_lines=$(( current_log_lines - prev_log_lines ))
        local new_errors=0
        local new_sigterms=0

        if [ "$new_lines" -gt 0 ]; then
            new_errors=$(container_exec "tail -${new_lines} ${GATEWAY_LOG} 2>/dev/null | grep -ci 'error\|exception\|traceback'" || echo "0")
            new_sigterms=$(container_exec "tail -${new_lines} ${GATEWAY_LOG} 2>/dev/null | grep -ci 'SIGTERM\|signal.*15\|shutdown\|received signal'" || echo "0")
        fi

        error_count=$(( error_count + new_errors ))
        sigterm_count=$(( sigterm_count + new_sigterms ))

        # Detect restart
        local restart_marker=""
        if [ "$current_restarts" != "$prev_restart_count" ] && [ "$current_restarts" != "?" ]; then
            restart_marker=" ${RED}[RESTART DETECTED: $prev_restart_count -> $current_restarts]${NC}"
            CRASH_DETECTED=true
        fi

        # Print status line
        echo -e "[$now] +${mins_elapsed}m${secs_elapsed}s | CPU: ${cpu_pct:-?} | MEM: ${mem_usage:-?} | Restarts: ${current_restarts}${restart_marker}"

        if [ "$new_errors" -gt 0 ]; then
            echo -e "  ${YELLOW}  +$new_errors error(s) in gateway.log (total: $error_count)${NC}"
        fi

        if [ "$new_sigterms" -gt 0 ]; then
            echo -e "  ${RED}  +$new_sigterms SIGTERM/shutdown signal(s) in gateway.log (total: $sigterm_count)${NC}"
            CRASH_DETECTED=true
        fi

        # Show verbose log tail
        if [ "$VERBOSE" = true ] && [ "$new_lines" -gt 0 ]; then
            container_exec "tail -3 ${GATEWAY_LOG} 2>/dev/null" | while read -r line; do
                echo -e "    $line"
            done
        fi

        prev_log_lines=$current_log_lines
        prev_restart_count=$current_restarts

        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    # Check Docker events log
    echo ""
    sub "Docker events during monitoring"
    if [ -f "$event_log_file" ] && [ -s "$event_log_file" ]; then
        local event_count
        event_count=$(wc -l < "$event_log_file")
        info "Captured $event_count Docker event(s):"
        cat "$event_log_file" | while read -r line; do
            local event_time
            event_time=$(date -d "@${line%% *}" '+%H:%M:%S' 2>/dev/null || echo "?")
            local event_action
            event_action=$(echo "$line" | awk '{print $2}')
            case "$event_action" in
                die|kill|stop)
                    echo -e "  ${RED}[$event_time] $event_action${NC} $(echo "$line" | cut -d' ' -f3-)"
                    ;;
                restart|start)
                    echo -e "  ${YELLOW}[$event_time] $event_action${NC} $(echo "$line" | cut -d' ' -f3-)"
                    ;;
                *)
                    echo -e "  ${BLUE}[$event_time] $event_action${NC} $(echo "$line" | cut -d' ' -f3-)"
                    ;;
            esac
        done
    else
        pass "No Docker events captured (container stayed stable)"
    fi

    # Cleanup
    kill "$event_pid" 2>/dev/null
    rm -f "$event_log_file"
    trap - EXIT

    # Runtime summary
    echo ""
    sub "Runtime summary"
    local final_mem
    final_mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null | head -1)
    info "Final memory: ${final_mem:-?}"
    info "Total errors in gateway.log: $error_count"
    info "Total SIGTERM/shutdown signals: $sigterm_count"
    info "Container restarts during monitoring: $(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo "?")"

    if [ "$error_count" -gt 20 ]; then
        warn "High error count ($error_count) — investigate gateway.log patterns"
    fi

    if [ "$sigterm_count" -gt 0 ]; then
        fail "SIGTERM signals detected — container is being killed externally"
        warn "Common causes: Docker Resource Saver, OOM killer, manual stop, healthcheck failure"
    fi
}

# =============================================================================
# PHASE 4: CRASH FORENSICS
# =============================================================================
phase_forensics() {
    header "PHASE 4: CRASH FORENSICS"

    local is_running=false
    if container_running; then
        is_running=true
        info "Container is currently running — forensics will check last crash indicators"
    else
        fail "Container is NOT running — performing full crash forensics"
    fi

    # 4.1 Container exit code and status
    sub "Container exit state"
    local exit_code
    exit_code=$(container_exit_code)
    local status
    status=$(container_status)
    local finished_at
    finished_at=$(docker inspect -f '{{.State.FinishedAt}}' "$CONTAINER_NAME" 2>/dev/null)
    local error_msg
    error_msg=$(docker inspect -f '{{.State.Error}}' "$CONTAINER_NAME" 2>/dev/null)
    local oom
    oom=$(docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null)

    info "Status: $status"
    info "Exit code: $exit_code"
    info "Finished at: $finished_at"
    info "Error: ${error_msg:-none}"
    info "OOM Killed: $oom"

    # Decode exit code
    case "$exit_code" in
        0)
            if [ "$is_running" = false ]; then
                info "Exit code 0 — clean shutdown"
            fi
            ;;
        1)
            warn "Exit code 1 — application error (check gateway.log traceback)"
            ;;
        137)
            fail "Exit code 137 — SIGKILL (OOM killer or docker kill)"
            if [ "$oom" = "true" ]; then
                fail "OOM Killed = TRUE — container exceeded memory limit"
            else
                warn "OOM Killed = FALSE — killed externally (docker kill, Resource Saver, systemd)"
            fi
            ;;
        143)
            warn "Exit code 143 — SIGTERM received (graceful shutdown requested)"
            warn "Common causes: docker stop, Resource Saver, healthcheck timeout"
            ;;
        -1)
            warn "Exit code -1 — Python unhandled exception in tool loop"
            warn "This often means tool approval blocked in gateway mode (no user to approve)"
            ;;
        *)
            warn "Exit code $exit_code — see Docker docs for signal mapping"
            ;;
    esac

    # 4.2 Last 100 lines of gateway.log
    sub "gateway.log (last 100 lines)"
    local log_content
    log_content=$(container_exec "tail -100 ${GATEWAY_LOG} 2>/dev/null" 2>/dev/null)
    if [ -n "$log_content" ]; then
        # Highlight errors
        echo "$log_content" | while IFS= read -r line; do
            case "$line" in
                *SIGTERM*|*signal*15*|*Received*signal*)
                    echo -e "  ${RED}$line${NC}"
                    ;;
                *Error*|*error*|*exception*|*Traceback*)
                    echo -e "  ${YELLOW}$line${NC}"
                    ;;
                *Connected*|*started*|*ready*)
                    echo -e "  ${GREEN}$line${NC}"
                    ;;
                *)
                    echo -e "  $line"
                    ;;
            esac
        done
    else
        warn "Could not read gateway.log (container stopped or log missing)"
    fi

    # 4.3 Docker inspect for restart policy and health
    sub "Docker inspect (restart + health)"
    local restart_policy
    restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME" 2>/dev/null)
    info "Restart policy: ${restart_policy:-N/A}"

    local health_status
    health_status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null)
    info "Health status: ${health_status:-N/A}"

    if [ "$health_status" = "unhealthy" ]; then
        fail "Container is marked UNHEALTHY"
        docker inspect -f '{{range .State.Health.Log}}{{.ExitCode}}: {{.Output}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | tail -3 | while read -r line; do
            echo -e "  ${RED}$line${NC}"
        done
    fi

    # 4.4 Docker Desktop Resource Saver check (detailed)
    sub "Docker Desktop monitor.log analysis"
    local monitor_found=false
    for monitor_log in \
        "/mnt/c/Users/$USER/AppData/Local/Docker/log/monitor.log" \
        "/mnt/c/Users/$USER/AppData/Local/Docker/log/vm/monitor.log"; do
        if [ -f "$monitor_log" ]; then
            monitor_found=true
            info "Analyzing: $monitor_log"

            # Look for Resource Saver kills targeting our container
            local rs_kills
            rs_kills=$(grep -i "hermes\|resource.saver\|idle.*container\|restart.*policy" "$monitor_log" 2>/dev/null | tail -20)
            if [ -n "$rs_kills" ]; then
                warn "Found relevant entries in monitor.log:"
                echo "$rs_kills" | while read -r line; do
                    echo -e "  ${YELLOW}$line${NC}"
                done
            else
                pass "No Resource Saver kills for hermes in monitor.log"
            fi
            break
        fi
    done

    if [ "$monitor_found" = false ]; then
        info "Docker Desktop monitor.log not found — not a Docker Desktop environment"
    fi

    # 4.5 dmesg for OOM
    sub "Kernel OOM check (dmesg)"
    if command -v dmesg >/dev/null 2>&1 && dmesg >/dev/null 2>&1; then
        local oom_events
        oom_events=$(dmesg 2>/dev/null | grep -i "oom\|out of memory\|killed process" | tail -5)
        if [ -n "$oom_events" ]; then
            fail "OOM events found in dmesg:"
            echo "$oom_events" | while read -r line; do
                echo -e "  ${RED}$line${NC}"
            done
        else
            pass "No OOM events in dmesg"
        fi
    else
        info "dmesg not accessible — skipping OOM kernel check"
    fi

    # 4.6 Docker log analysis for crash patterns
    sub "Docker log crash pattern analysis"
    local docker_logs
    docker_logs=$(docker logs "$CONTAINER_NAME" --tail 200 2>&1)

    # Check for known crash patterns
    local patterns=(
        "SIGTERM:shutdown.*Shutdown diagnostic"
        "exit_with_failure.*True"
        "_exit_with_failure"
        "TelegramAdapter.*fatal.*retryable"
        "Resource temporarily unavailable"
        "Connection refused"
        "marking.*unhealthy"
        "tool_use_error"
        "compaction.*error"
    )

    local pattern_names=(
        "SIGTERM/shutdown diagnostic"
        "exit_with_failure=True"
        "exit_with_failure flag"
        "Telegram fatal retryable error"
        "Resource temporarily unavailable"
        "Connection refused"
        "Provider marked unhealthy"
        "tool_use_error (post-compaction)"
        "Compaction error"
    )

    for i in "${!patterns[@]}"; do
        local match_count
        match_count=$(echo "$docker_logs" | grep -cE "${patterns[$i]}" 2>/dev/null || echo "0")
        if [ "$match_count" -gt 0 ]; then
            warn "Found $match_count occurrence(s) of: ${pattern_names[$i]}"
            # Show first occurrence
            echo "$docker_logs" | grep -E "${patterns[$i]}" | head -2 | while read -r line; do
                echo -e "    ${YELLOW}$(echo "$line" | cut -c1-120)${NC}"
            done
        fi
    done
}

# =============================================================================
# PHASE 5: CONFIG DRIFT DETECTION
# =============================================================================
phase_config_drift() {
    header "PHASE 5: CONFIG DRIFT DETECTION"

    if ! container_running; then
        warn "Container not running — checking host-side config files"
    fi

    local config_path
    config_path="${HOST_DATA_DIR}/config.yaml"

    # If container is running, read config from inside (more accurate)
    if container_running; then
        local container_config
        container_config=$(container_exec "cat ${DATA_DIR}/config.yaml" 2>/dev/null)
        if [ -n "$container_config" ]; then
            # Write to temp for analysis
            local tmp_config
            tmp_config=$(mktemp /tmp/hermes-config.XXXXXX)
            echo "$container_config" > "$tmp_config"
            config_path="$tmp_config"
            info "Using config from inside container"
        fi
    fi

    if [ ! -f "$config_path" ]; then
        fail "Cannot read config.yaml — skipping drift detection"
        return 1
    fi

    # 5.1 Model drift
    sub "Model configuration"
    local current_model
    current_model=$(grep -E '^\s+default:\s*"' "$config_path" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    if [ "$current_model" = "$EXPECTED_MODEL" ]; then
        pass "model.default = '$EXPECTED_MODEL' (no drift)"
    else
        fail "CONFIG DRIFT: model.default changed from '$EXPECTED_MODEL' to '$current_model'"
        warn "This typically happens after upstream sync + rebuild"
    fi

    # 5.2 Provider drift
    sub "Provider configuration"
    local provider_lines
    provider_lines=$(grep -n '^\s*provider:' "$config_path")
    local provider_count
    provider_count=$(echo "$provider_lines" | grep -c 'provider:' || echo "0")

    if [ "$provider_count" -eq 1 ]; then
        local current_provider
        current_provider=$(echo "$provider_lines" | sed 's/.*:\s*"\?\([^"]*\)"\?.*/\1/' | tr -d ' ')
        if [ "$current_provider" = "$EXPECTED_PROVIDER" ]; then
            pass "Exactly one provider = '$EXPECTED_PROVIDER' (no drift)"
        else
            fail "CONFIG DRIFT: provider changed to '$current_provider' (expected '$EXPECTED_PROVIDER')"
        fi
    else
        fail "CONFIG DRIFT: $provider_count provider lines found (should be exactly 1):"
        echo "$provider_lines" | while read -r line; do
            echo -e "  ${RED}$line${NC}"
        done
        warn "YAML takes the LAST duplicate — may silently override our zai setting"
    fi

    # 5.3 base_url contamination
    sub "base_url contamination check"
    local base_urls
    base_urls=$(grep -n 'base_url:' "$config_path" 2>/dev/null)
    if [ -z "$base_urls" ]; then
        pass "No base_url overrides (clean — will use provider defaults)"
    else
        warn "base_url lines found:"
        echo "$base_urls" | while read -r line; do
            if echo "$line" | grep -qi "$FORBIDDEN_BASE_URL"; then
                echo -e "  ${RED}$line  <-- FORBIDDEN (OpenRouter)${NC}"
            elif echo "$line" | grep -qi 'z\.ai\|zai'; then
                echo -e "  ${GREEN}$line  <-- OK (z.ai)${NC}"
            else
                echo -e "  ${YELLOW}$line  <-- UNKNOWN${NC}"
            fi
        done
    fi

    # 5.4 Auxiliary drift
    sub "Auxiliary provider configuration"
    local aux_sections=("compression" "image" "browser" "web")
    for section in "${aux_sections[@]}"; do
        local aux_provider
        aux_provider=$(grep -A3 "${section}:" "$config_path" | grep 'provider:' | head -1 | sed 's/.*:\s*"\?\([^"]*\)"\?.*/\1/' | tr -d ' ')
        if [ "$aux_provider" = "$EXPECTED_PROVIDER" ]; then
            pass "auxiliary.$section.provider = '$EXPECTED_PROVIDER'"
        elif [ -z "$aux_provider" ]; then
            warn "auxiliary.$section.provider not set — defaults to auto (OpenRouter)"
        else
            fail "CONFIG DRIFT: auxiliary.$section.provider = '$aux_provider' (expected '$EXPECTED_PROVIDER')"
        fi
    done

    # 5.5 jobs.json ownership
    sub "Cron jobs.json ownership"
    if container_running; then
        local jobs_path="${DATA_DIR}/cron/jobs.json"
        local jobs_exists
        jobs_exists=$(container_exec "test -f $jobs_path && echo yes || echo no" 2>/dev/null)
        if [ "$jobs_exists" = "yes" ]; then
            local jobs_owner
            jobs_owner=$(container_exec "stat -c '%U:%G' $jobs_path" 2>/dev/null)
            if [ "$jobs_owner" = "hermes:hermes" ]; then
                pass "jobs.json ownership: hermes:hermes (correct)"
            else
                fail "CONFIG DRIFT: jobs.json owned by '$jobs_owner' (needs hermes:hermes)"
                warn "Fix: docker exec hermes chown hermes:hermes $jobs_path"
            fi

            # Check cron toolsets
            local cron_toolsets
            cron_toolsets=$(container_exec "python3 -c \"import json; jobs=json.load(open('$jobs_path')); [print(j.get('name','?'), ':', j.get('enabled_toolsets','null')) for j in jobs.get('jobs',[])]\" 2>/dev/null")
            if [ -n "$cron_toolsets" ]; then
                info "Cron job toolsets:"
                echo "$cron_toolsets" | while read -r line; do
                    if echo "$line" | grep -q "mcp"; then
                        echo -e "  ${GREEN}$line${NC}"
                    else
                        echo -e "  ${YELLOW}$line  <-- MCP toolsets missing!${NC}"
                    fi
                done
            fi
        else
            warn "jobs.json not found — no cron jobs to check"
        fi
    else
        info "Container not running — checking host-side jobs.json"
        local host_jobs="${HOST_DATA_DIR}/cron/jobs.json"
        if [ -f "$host_jobs" ]; then
            local host_jobs_owner
            host_jobs_owner=$(stat -c '%U:%G' "$host_jobs" 2>/dev/null)
            info "Host-side jobs.json owner: $host_jobs_owner"
        else
            warn "No jobs.json found at $host_jobs"
        fi
    fi

    # 5.6 .env allowlists
    sub ".env allowlists"
    if container_running; then
        local env_content
        env_content=$(container_exec "cat ${DATA_DIR}/.env" 2>/dev/null)
    else
        if [ -f "${HOST_DATA_DIR}/.env" ]; then
            env_content=$(cat "${HOST_DATA_DIR}/.env")
        fi
    fi

    if [ -n "$env_content" ]; then
        local required_vars=(
            "TELEGRAM_ALLOWED_USERS"
            "TELEGRAM_GROUP_ALLOWED_USERS"
            "TELEGRAM_HOME_CHANNEL"
        )
        for var in "${required_vars[@]}"; do
            if echo "$env_content" | grep -q "^${var}="; then
                pass ".env has $var set"
            else
                fail "CONFIG DRIFT: .env missing $var"
            fi
        done

        # Check for blank/wiped .env
        local env_line_count
        env_line_count=$(echo "$env_content" | grep -c '^' || echo "0")
        if [ "$env_line_count" -lt 3 ]; then
            fail ".env has only $env_line_count line(s) — likely wiped by 'hermes mcp' command"
        fi
    else
        fail "Cannot read .env"
    fi

    # 5.7 auth.json ownership
    sub "auth.json ownership"
    if container_running; then
        local auth_exists
        auth_exists=$(container_exec "test -f ${DATA_DIR}/auth.json && echo yes || echo no" 2>/dev/null)
        if [ "$auth_exists" = "yes" ]; then
            local auth_owner
            auth_owner=$(container_exec "stat -c '%U:%G' ${DATA_DIR}/auth.json" 2>/dev/null)
            if [ "$auth_owner" = "hermes:hermes" ]; then
                pass "auth.json ownership: hermes:hermes"
            else
                fail "auth.json owned by '$auth_owner' — gateway gets Permission denied on credentials"
                warn "Fix: docker exec hermes chown hermes:hermes ${DATA_DIR}/auth.json"
            fi
        else
            info "auth.json does not exist (OK if no OAuth in use)"
        fi
    fi

    # Cleanup temp file
    if [ -n "${tmp_config:-}" ] && [ -f "$tmp_config" ]; then
        rm -f "$tmp_config"
    fi
}

# =============================================================================
# SUMMARY
# =============================================================================
phase_summary() {
    header "DIAGNOSTIC SUMMARY"
    local total=$(( PASS_COUNT + FAIL_COUNT + WARN_COUNT ))

    echo ""
    echo -e "  ${GREEN}PASS${NC}:  $PASS_COUNT"
    echo -e "  ${RED}FAIL${NC}:  $FAIL_COUNT"
    echo -e "  ${YELLOW}WARN${NC}:  $WARN_COUNT"
    echo -e "  ${BLUE}INFO${NC}:  $INFO_COUNT"
    echo ""

    if [ "$CRASH_DETECTED" = true ]; then
        echo -e "${RED}${BOLD}CRASH DETECTED during diagnostics!${NC}"
        echo ""
        echo -e "  Top SIGTERM causes (in order of likelihood):"
        echo -e "  1. Docker Desktop Resource Saver killing idle container"
        echo -e "     Fix: Docker Desktop > Settings > Resources > Resource Saver > Disable"
        echo ""
        echo -e "  2. Config drift: provider auto/base_url OpenRouter"
        echo -e "     Fix: Run hermes-restore-config.sh, then docker restart hermes"
        echo ""
        echo -e "  3. Telegram adapter timeout (15 min cycle)"
        echo -e "     Fix: Check DNS for api.telegram.org, check firewall"
        echo ""
        echo -e "  4. Tool approval block in gateway mode"
        echo -e "     Fix: Ensure approvals.mode=off and approvals.cron_mode=approve"
        echo ""
        echo -e "  5. OOM kill (memory limit exceeded)"
        echo -e "     Fix: Increase container memory, disable browser tools"
        echo ""
    elif [ "$FAIL_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}Issues found — review FAIL items above${NC}"
    else
        echo -e "${GREEN}${BOLD}All checks passed — container appears healthy${NC}"
    fi

    echo ""
    echo -e "Container: $CONTAINER_NAME | Image: $IMAGE_NAME | Runtime: ${RUNTIME_MINUTES} min"
    echo -e "Timestamp: $(timestamp)"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo -e "${BOLD}${CYAN}"
    echo "============================================="
    echo " Hermes Container Lifecycle Diagnostic"
    echo " $(timestamp)"
    echo "============================================="
    echo -e "${NC}"

    if [ "$FORENSICS_ONLY" = true ]; then
        phase_forensics
        phase_config_drift
        phase_summary
        exit $FAIL_COUNT
    fi

    # Phase 1: Preflight
    if ! phase_preflight; then
        echo -e "\n${RED}Preflight failed — cannot proceed. Fix issues above and retry.${NC}"
        exit 1
    fi

    # Phase 2: Start
    if ! phase_start; then
        echo -e "\n${RED}Container start failed — proceeding to forensics.${NC}"
        CRASH_DETECTED=true
    fi

    # Phase 3: Runtime monitor (only if container is running)
    if container_running; then
        phase_runtime
    else
        warn "Skipping runtime monitor — container not running"
    fi

    # Phase 4: Forensics (always run)
    phase_forensics

    # Phase 5: Config drift (always run)
    phase_config_drift

    # Summary
    phase_summary

    exit $FAIL_COUNT
}

main
