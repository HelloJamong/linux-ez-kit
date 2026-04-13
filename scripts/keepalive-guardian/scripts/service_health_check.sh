#!/bin/bash

################################################################################
# Keepalive Guardian - Service Health Check Script
#
# Location: /usr/local/bin/service_health_check.sh
# Purpose:  Check port / process status and determine service health
# Returns:  exit 0 (healthy), exit 1 (failure or failback stabilization pending)
# Called:   Keepalived track_script (every HEALTH_CHECK_INTERVAL seconds)
#
# Failback stabilization behavior:
#   After service recovery, does not immediately return to MASTER.
#   Waits for FAILBACK_DELAY seconds of continuous healthy state
#   before allowing priority recovery.
################################################################################

CONFIG_FILE="${CONFIG_FILE:-/etc/keepalived/service_check.conf}"
TIMER_FILE="${TIMER_FILE:-/tmp/keepalive_recovery_timer}"  # Stores failback stabilization timer start time
STATE_FILE="${STATE_FILE:-/tmp/keepalive_health_state}"    # Tracks previous state (ok / fail / recovering)
MAINT_LAST_LOG_FILE="${MAINT_LAST_LOG_FILE:-/tmp/keepalive_maintenance_last_log}"

# ------------------------------------------------------------------------------
# Load config file
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [FAIL] - Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

LOG_FILE="${LOG_FILE:-/var/log/service_ha_check.log}"
MAINTENANCE_FILE="${MAINTENANCE_FILE:-/run/keepalive-guardian/maintenance.conf}"
MAINTENANCE_LOG_INTERVAL="${MAINTENANCE_LOG_INTERVAL:-60}"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# ------------------------------------------------------------------------------
# Logging function
# ------------------------------------------------------------------------------
log_msg() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [${level}] - ${message}" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Maintenance mode
# Controlled by: /usr/local/bin/service_maintenance_mode.sh
#
# Modes:
#   bypass : return healthy during planned maintenance
#   demote : return unhealthy during planned maintenance to move VIP away
# ------------------------------------------------------------------------------
get_maintenance_value() {
    local key="$1"
    [ -f "$MAINTENANCE_FILE" ] || return 1
    grep -E "^${key}=" "$MAINTENANCE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

should_log_maintenance() {
    local now last_log
    now=$(date +%s)
    last_log=0
    [ -f "$MAINT_LAST_LOG_FILE" ] && last_log=$(cat "$MAINT_LAST_LOG_FILE" 2>/dev/null || echo 0)

    if ! [[ "$last_log" =~ ^[0-9]+$ ]] || [ $((now - last_log)) -ge "$MAINTENANCE_LOG_INTERVAL" ]; then
        echo "$now" > "$MAINT_LAST_LOG_FILE"
        return 0
    fi
    return 1
}

handle_maintenance_mode() {
    [ -f "$MAINTENANCE_FILE" ] || return 0

    local mode reason started_by started_at
    mode=$(get_maintenance_value "MODE")
    reason=$(get_maintenance_value "REASON")
    started_by=$(get_maintenance_value "STARTED_BY")
    started_at=$(get_maintenance_value "STARTED_AT")

    mode="${mode:-bypass}"
    reason="${reason:-not specified}"
    started_by="${started_by:-unknown}"
    started_at="${started_at:-unknown}"

    rm -f "$TIMER_FILE"

    case "$mode" in
        bypass)
            echo "maintenance" > "$STATE_FILE"
            if should_log_maintenance; then
                log_msg "MAINT" "Maintenance mode active (bypass) — health check forced healthy; started_at=${started_at}; started_by=${started_by}; reason=${reason}"
            fi
            exit 0
            ;;
        demote)
            echo "maintenance-demote" > "$STATE_FILE"
            if should_log_maintenance; then
                log_msg "MAINT" "Maintenance mode active (demote) — health check forced unhealthy to move VIP away; started_at=${started_at}; started_by=${started_by}; reason=${reason}"
            fi
            exit 1
            ;;
        *)
            log_msg "WARN" "Invalid maintenance mode '${mode}' in ${MAINTENANCE_FILE}; continuing with normal health checks"
            return 0
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Port check
# Check TCP connectivity (timeout 2s)
# ------------------------------------------------------------------------------
check_ports() {
    [ "${#PORT_LIST[@]}" -eq 0 ] && return 0

    local failed_ports=()
    for port in "${PORT_LIST[@]}"; do
        if ! timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            failed_ports+=("$port")
        fi
    done

    if [ "${#failed_ports[@]}" -gt 0 ]; then
        log_msg "FAIL" "Port(s) unreachable: ${failed_ports[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Process check
# Check process existence via pgrep -f <name>
# ------------------------------------------------------------------------------
check_processes() {
    [ "${#PROCESS_LIST[@]}" -eq 0 ] && return 0

    local failed_procs=()
    for proc in "${PROCESS_LIST[@]}"; do
        if ! pgrep -f "$proc" >/dev/null 2>&1; then
            failed_procs+=("$proc")
        fi
    done

    if [ "${#failed_procs[@]}" -gt 0 ]; then
        log_msg "FAIL" "Process(es) not running: ${failed_procs[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    handle_maintenance_mode

    local prev_state="ok"
    [ -f "$STATE_FILE" ] && prev_state=$(cat "$STATE_FILE" 2>/dev/null)

    # Run all checks — collect all failures before final judgment
    local all_ok=true
    check_ports     || all_ok=false
    check_processes || all_ok=false

    # ── Failure state ────────────────────────────────────────────────────────────
    if ! $all_ok; then
        if [ "$prev_state" == "recovering" ]; then
            log_msg "FAIL" "Re-failure during recovery — Failback timer reset"
        fi
        rm -f "$TIMER_FILE"
        echo "fail" > "$STATE_FILE"
        exit 1
    fi

    # ── Healthy state — Failback stabilization ──────────────────────────────────

    # First healthy check after failure: start stabilization timer
    if [ "$prev_state" == "fail" ]; then
        date +%s > "$TIMER_FILE"
        echo "recovering" > "$STATE_FILE"
        log_msg "INFO" "Service recovery detected — Failback stabilization timer started (${FAILBACK_DELAY}s required)"
        exit 1  # Stabilization incomplete — delay priority recovery
    fi

    # Stabilization timer in progress
    if [ -f "$TIMER_FILE" ]; then
        local start_time elapsed remaining
        start_time=$(cat "$TIMER_FILE" 2>/dev/null)
        elapsed=$(( $(date +%s) - start_time ))
        remaining=$(( FAILBACK_DELAY - elapsed ))

        if [ "$elapsed" -lt "$FAILBACK_DELAY" ]; then
            # Log every 60s only (avoid noise from 2s polling interval)
            if [ $(( elapsed % 60 )) -lt 3 ]; then
                log_msg "INFO" "Failback stabilization in progress: ${elapsed}/${FAILBACK_DELAY}s (${remaining}s remaining)"
            fi
            exit 1  # Stabilization incomplete — delay MASTER recovery
        fi

        # Stabilization complete — allow MASTER priority recovery
        log_msg "RECOVERY" "Failback stabilization complete (${elapsed}s elapsed) — MASTER priority recovery allowed"
        rm -f "$TIMER_FILE"
        echo "ok" > "$STATE_FILE"
        exit 0
    fi

    # Fully healthy state
    if [ "$prev_state" != "ok" ]; then
        log_msg "SUCCESS" "All health checks passed"
        echo "ok" > "$STATE_FILE"
    fi

    exit 0
}

main
