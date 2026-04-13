#!/bin/bash

################################################################################
# Keepalive Guardian - Maintenance Mode Control Script
#
# Location: /usr/local/bin/service_maintenance_mode.sh
# Purpose:  Enable/disable planned maintenance mode for keepalived health checks
#
# Modes:
#   bypass : Health check returns success while maintenance is active
#            Use for Standby patching or planned full-service maintenance.
#   demote : Health check returns failure while maintenance is active
#            Use on the current MASTER when you want VIP to move to the peer.
################################################################################

CONFIG_FILE="${CONFIG_FILE:-/etc/keepalived/service_check.conf}"
HEALTH_CHECK_SCRIPT="${HEALTH_CHECK_SCRIPT:-/usr/local/bin/service_health_check.sh}"
TIMER_FILE="${TIMER_FILE:-/tmp/keepalive_recovery_timer}"
STATE_FILE="${STATE_FILE:-/tmp/keepalive_health_state}"
MAINT_LAST_LOG_FILE="${MAINT_LAST_LOG_FILE:-/tmp/keepalive_maintenance_last_log}"

# Load optional settings from service_check.conf.
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

LOG_FILE="${LOG_FILE:-/var/log/service_ha_check.log}"
MAINTENANCE_FILE="${MAINTENANCE_FILE:-/run/keepalive-guardian/maintenance.conf}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_msg() {
    local level="$1"
    local message="$2"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [${level}] - ${message}" >> "$LOG_FILE"
}

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  on [--mode bypass|demote] [--reason TEXT]
      Enable maintenance mode.
      Default mode: bypass

  off [--no-check]
      Disable maintenance mode and run service health check by default.

  status
      Show maintenance mode status.

  check
      Run service health check now.

Modes:
  bypass  Health check returns success while maintenance is active.
          WARNING: If used on the MASTER while the service is stopped, VIP can
          remain on a node that is not serving traffic.

  demote  Health check returns failure while maintenance is active.
          Use on the current MASTER to move VIP to a healthy peer before patching.

Examples:
  # Standby planned patch: suppress health-check failures on the Standby
  $0 on --mode bypass --reason "patch standby"
  $0 off

  # Active planned patch: move VIP away first
  $0 on --mode demote --reason "patch active"
  # verify VIP moved to peer, then patch
  $0 off
EOF
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} Root privilege required. Run with sudo." >&2
        exit 1
    fi
}

read_value() {
    local key="$1"
    [ -f "$MAINTENANCE_FILE" ] || return 1
    grep -E "^${key}=" "$MAINTENANCE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

sanitize_reason() {
    local reason="$*"
    reason="${reason//$'\n'/ }"
    reason="${reason//$'\r'/ }"
    [ -n "$reason" ] || reason="not specified"
    printf '%s' "$reason"
}

enable_maintenance() {
    require_root

    local mode="bypass"
    local reason="not specified"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                mode="$2"
                shift 2
                ;;
            --reason)
                shift
                reason=$(sanitize_reason "$@")
                break
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                reason=$(sanitize_reason "$@")
                break
                ;;
        esac
    done

    case "$mode" in
        bypass|demote)
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Invalid mode: ${mode} (allowed: bypass, demote)" >&2
            exit 1
            ;;
    esac

    mkdir -p "$(dirname "$MAINTENANCE_FILE")"
    chmod 755 "$(dirname "$MAINTENANCE_FILE")"

    cat > "$MAINTENANCE_FILE" <<EOF
MODE=${mode}
STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')
STARTED_BY=$(whoami)@$(hostname)
REASON=${reason}
EOF
    chmod 600 "$MAINTENANCE_FILE"

    rm -f "$TIMER_FILE" "$MAINT_LAST_LOG_FILE"
    echo "maintenance-${mode}" > "$STATE_FILE"

    log_msg "MAINT" "Maintenance mode enabled: mode=${mode}; reason=${reason}"

    echo -e "${GREEN}[OK]${NC} Maintenance mode enabled"
    echo "  mode:   ${mode}"
    echo "  file:   ${MAINTENANCE_FILE}"
    echo "  reason: ${reason}"

    if [ "$mode" = "bypass" ]; then
        echo -e "  ${YELLOW}warning:${NC} bypass forces health checks to success; do not stop the MASTER service unless service interruption is acceptable."
    else
        echo -e "  ${YELLOW}note:${NC} demote forces health checks to failure; verify VIP moves to the peer before patching."
    fi
}

disable_maintenance() {
    require_root

    local run_check=true
    local was_active=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-check)
                run_check=false
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR]${NC} Unknown option for off: $1" >&2
                exit 1
                ;;
        esac
    done

    if [ -f "$MAINTENANCE_FILE" ]; then
        was_active=true
        local mode reason
        mode=$(read_value "MODE")
        reason=$(read_value "REASON")
        rm -f "$MAINTENANCE_FILE"
        log_msg "MAINT" "Maintenance mode disabled: mode=${mode:-unknown}; reason=${reason:-not specified}"
        echo -e "${GREEN}[OK]${NC} Maintenance mode disabled"
    else
        echo -e "${YELLOW}[WARN]${NC} Maintenance mode was not active"
    fi

    if $was_active; then
        rm -f "$TIMER_FILE" "$STATE_FILE" "$MAINT_LAST_LOG_FILE"
    fi

    if $run_check; then
        run_health_check
    fi
}

show_status() {
    if [ -f "$MAINTENANCE_FILE" ]; then
        echo -e "${YELLOW}${BOLD}Maintenance mode: ACTIVE${NC}"
        echo "  file:       ${MAINTENANCE_FILE}"
        echo "  mode:       $(read_value "MODE")"
        echo "  started_at: $(read_value "STARTED_AT")"
        echo "  started_by: $(read_value "STARTED_BY")"
        echo "  reason:     $(read_value "REASON")"
    else
        echo -e "${GREEN}Maintenance mode: inactive${NC}"
    fi
}

run_health_check() {
    local script="$HEALTH_CHECK_SCRIPT"

    if [ ! -x "$script" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -x "${script_dir}/service_health_check.sh" ]; then
            script="${script_dir}/service_health_check.sh"
        else
            echo -e "${RED}[ERROR]${NC} Health check script not executable: ${HEALTH_CHECK_SCRIPT}" >&2
            exit 1
        fi
    fi

    echo -e "${BLUE}[INFO]${NC} Running service health check: ${script}"
    if "$script"; then
        log_msg "SUCCESS" "Manual health check passed after maintenance command"
        echo -e "${GREEN}[OK]${NC} Service health check passed"
        return 0
    fi

    local rc=$?
    log_msg "FAIL" "Manual health check failed after maintenance command (exit=${rc})"
    echo -e "${RED}[FAIL]${NC} Service health check failed (exit=${rc})"
    echo "  Check log: ${LOG_FILE}"
    return "$rc"
}

main() {
    local command="${1:-}"
    [ $# -gt 0 ] && shift

    case "$command" in
        on|enable|start)
            enable_maintenance "$@"
            ;;
        off|disable|stop)
            disable_maintenance "$@"
            ;;
        status)
            show_status
            ;;
        check)
            run_health_check
            ;;
        --help|-h|help)
            usage
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown command: ${command}" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
