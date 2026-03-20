#!/bin/bash

################################################################################
# Keepalive Guardian - MASTER Promotion Notification Script
#
# Location: /usr/local/bin/service_recovery_check.sh
# Purpose:  keepalived notify_master hook — runs automatically on VRRP MASTER transition
# Called:   keepalived notify_master (when this server is promoted to MASTER)
#
# Actions:
#   1. Log MASTER promotion event
#   2. Clean up stabilization timer file on Failback completion
#   3. Immediately verify and log service status after promotion
################################################################################

CONFIG_FILE="/etc/keepalived/service_check.conf"
TIMER_FILE="/tmp/keepalive_recovery_timer"
STATE_FILE="/tmp/keepalive_health_state"

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
# Port check (for immediate verification — result only)
# ------------------------------------------------------------------------------
verify_ports() {
    [ "${#PORT_LIST[@]}" -eq 0 ] && return 0

    local failed=()
    for port in "${PORT_LIST[@]}"; do
        if ! timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            failed+=("$port")
        fi
    done

    if [ "${#failed[@]}" -gt 0 ]; then
        log_msg "WARN" "Port(s) not responding after MASTER promotion: ${failed[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Process check (for immediate verification — result only)
# ------------------------------------------------------------------------------
verify_processes() {
    [ "${#PROCESS_LIST[@]}" -eq 0 ] && return 0

    local failed=()
    for proc in "${PROCESS_LIST[@]}"; do
        if ! pgrep -f "$proc" >/dev/null 2>&1; then
            failed+=("$proc")
        fi
    done

    if [ "${#failed[@]}" -gt 0 ]; then
        log_msg "WARN" "Process(es) not running after MASTER promotion: ${failed[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    local hostname host_ip
    hostname=$(hostname 2>/dev/null)
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # Log MASTER promotion event
    log_msg "INFO" "══════════════════════════════════════════════════════════"
    log_msg "INFO" "VRRP MASTER promoted: ${hostname} (${host_ip})"
    log_msg "INFO" "══════════════════════════════════════════════════════════"

    # Failback completion — clean up stabilization timer file
    if [ -f "$TIMER_FILE" ]; then
        local start_time elapsed
        start_time=$(cat "$TIMER_FILE" 2>/dev/null)
        if [ -n "$start_time" ]; then
            elapsed=$(( $(date +%s) - start_time ))
            log_msg "RECOVERY" "Failback stabilization complete — MASTER restored after ${elapsed}s"
        fi
        rm -f "$TIMER_FILE"
    fi

    # Reset state file (sync with health check script)
    echo "ok" > "$STATE_FILE"

    # Immediately verify service status after promotion
    log_msg "INFO" "Verifying service status immediately after MASTER promotion"

    local all_ok=true
    verify_ports     || all_ok=false
    verify_processes || all_ok=false

    if $all_ok; then
        log_msg "SUCCESS" "Service status healthy after MASTER promotion — HA failover complete"
    else
        log_msg "WARN" "Some services are unhealthy after MASTER promotion"
        log_msg "WARN" "keepalived track_script will re-evaluate automatically"
        log_msg "WARN" "Immediate action required: tail -f ${LOG_FILE}"
    fi
}

main
exit 0
