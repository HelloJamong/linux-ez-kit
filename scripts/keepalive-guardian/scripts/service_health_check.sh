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

CONFIG_FILE="/etc/keepalived/service_check.conf"
TIMER_FILE="/tmp/keepalive_recovery_timer"  # Stores failback stabilization timer start time
STATE_FILE="/tmp/keepalive_health_state"    # Tracks previous state (ok / fail / recovering)

# ------------------------------------------------------------------------------
# Load config file
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [FAIL] - Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

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
