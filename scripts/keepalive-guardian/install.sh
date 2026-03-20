#!/bin/bash

################################################################################
# Keepalive Guardian - Service Installation Script
#
# Purpose: Automated Active-Standby HA service configuration based on keepalived
# Usage:
#   Interactive:     sudo ./install.sh
#   Non-interactive: sudo ./install.sh --config install.conf
#                    sudo ./install.sh --config install.conf --yes
# Environment: Rocky Linux 8.x / 9.x
################################################################################

# ------------------------------------------------------------------------------
# Variable definitions
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/conf"       # Configuration file directory
SCRIPTS_DIR="${SCRIPT_DIR}/scripts" # Script directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backup/keepalive-guardian/backup_${TIMESTAMP}"
REPORT_FILE="${SCRIPT_DIR}/install_report_${TIMESTAMP}.txt"

VERSION="v26.03.01"        # Script version (YY.MM.sequence)

VRRP_ROUTER_ID=51          # Unique VRRP group ID within the same L2 network
HEALTH_CHECK_INTERVAL=2    # Health check interval in seconds (fixed)

NON_INTERACTIVE=false      # Set to true when --config option is used
CONFIG_FILE=""             # Config file path specified by --config
AUTO_CONFIRM=false         # Auto-approve final confirmation when --yes is used

# ------------------------------------------------------------------------------
# Color definitions
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Output functions
# ------------------------------------------------------------------------------
print_banner() {
    echo ""
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "${BOLD}       Keepalive Guardian - Service Installation Script${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "  Version:    ${CYAN}${VERSION}${NC}"
    echo -e "  Started:    $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  Host:       $(hostname) ($(hostname -I | awk '{print $1}'))"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}${BOLD}[ $1 ]${NC}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

log_info()    { echo -e "  ${BLUE}[INFO]${NC}  $1"; echo "  [INFO]  $1"  >> "$REPORT_FILE"; }
log_success() { echo -e "  ${GREEN}[OK]${NC}    $1"; echo "  [OK]    $1"  >> "$REPORT_FILE"; }
log_warn()    { echo -e "  ${YELLOW}[WARN]${NC}  $1"; echo "  [WARN]  $1"  >> "$REPORT_FILE"; }
log_error()   { echo -e "  ${RED}[ERROR]${NC} $1"; echo "  [ERROR] $1" >> "$REPORT_FILE"; }

error_exit() {
    log_error "$1"
    echo ""
    echo -e "${RED}Installation aborted. Report: ${REPORT_FILE}${NC}"
    exit 1
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                if [ -z "$2" ] || [[ "$2" == --* ]]; then
                    error_exit "--config requires a file path. (e.g. --config install.conf)"
                fi
                CONFIG_FILE="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            --yes|-y)
                AUTO_CONFIRM=true
                shift
                ;;
            --help|-h)
                echo ""
                echo "Usage:"
                echo "  Interactive:    sudo ./install.sh"
                echo "  Non-interactive: sudo ./install.sh --config <config-file> [--yes]"
                echo ""
                echo "Options:"
                echo "  --config <file>  Specify config file for non-interactive installation"
                echo "  --yes, -y        Auto-approve final confirmation prompt"
                echo "  --help, -h       Show this help message"
                echo ""
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1  (use --help for usage)"
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Load config file (non-interactive mode)
# ------------------------------------------------------------------------------
load_from_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error_exit "Config file not found: ${CONFIG_FILE}"
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    log_info "Config file loaded: ${CONFIG_FILE}"

    # Validate required fields
    local errors=()

    case "$ROLE" in
        active)
            VRRP_STATE="MASTER"
            VRRP_PRIORITY=100
            ;;
        standby)
            VRRP_STATE="BACKUP"
            VRRP_PRIORITY=90
            ;;
        "")
            errors+=("ROLE is not set. (active or standby)")
            ;;
        *)
            errors+=("Invalid ROLE value: '${ROLE}' (only active or standby allowed)")
            ;;
    esac

    if [ -z "$VIP" ]; then
        errors+=("VIP is not set.")
    elif ! validate_ip "$VIP"; then
        errors+=("Invalid VIP format: '${VIP}'")
    fi

    if [ -z "$PEER_IP" ]; then
        errors+=("PEER_IP is not set.")
    elif ! validate_ip "$PEER_IP"; then
        errors+=("Invalid PEER_IP format: '${PEER_IP}'")
    fi

    # FAILOVER_DELAY default value and validation
    FAILOVER_DELAY="${FAILOVER_DELAY:-10}"
    if ! [[ "$FAILOVER_DELAY" =~ ^[0-9]+$ ]] || [ "$FAILOVER_DELAY" -lt 2 ]; then
        errors+=("FAILOVER_DELAY must be a number >= 2: '${FAILOVER_DELAY}'")
    fi

    # Report all errors and exit
    if [ "${#errors[@]}" -gt 0 ]; then
        log_error "Config file error (${CONFIG_FILE}):"
        for err in "${errors[@]}"; do
            log_error "  - ${err}"
        done
        error_exit "Please fix the config file and retry."
    fi

    # Auto-detect interface if not set
    if [ -z "$VRRP_INTERFACE" ]; then
        VRRP_INTERFACE=$(ip -o link show | awk '{print $2}' | sed 's/://' | grep -v "^lo$" | grep -v "@" | head -1)
        log_info "VRRP_INTERFACE not set — auto-detected: ${VRRP_INTERFACE}"
    fi

    if ! ip link show "$VRRP_INTERFACE" &>/dev/null; then
        error_exit "VRRP_INTERFACE '${VRRP_INTERFACE}' does not exist."
    fi

    # Auto-detect current server IP if not set
    if [ -z "$CURRENT_IP" ]; then
        CURRENT_IP=$(ip -o -4 addr show "$VRRP_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [ -z "$CURRENT_IP" ]; then
            error_exit "Could not auto-detect CURRENT_IP. Please set it manually in the config file."
        fi
        log_info "CURRENT_IP not set — auto-detected: ${CURRENT_IP}"
    elif ! validate_ip "$CURRENT_IP"; then
        error_exit "Invalid CURRENT_IP format: '${CURRENT_IP}'"
    fi

    if [ "$PEER_IP" == "$CURRENT_IP" ]; then
        error_exit "PEER_IP and CURRENT_IP are the same. Please check the peer server IP."
    fi

    # Calculate failback detection count
    HEALTH_CHECK_FALL=$(( (FAILOVER_DELAY + HEALTH_CHECK_INTERVAL - 1) / HEALTH_CHECK_INTERVAL ))

    # Auto-generate VRRP password if not set
    if [ -z "$AUTH_PASSWORD" ]; then
        AUTH_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 8 || echo "KAGuard1")
        log_info "AUTH_PASSWORD not set — auto-generated: ${AUTH_PASSWORD}"
        log_warn "Set the same AUTH_PASSWORD on the peer server config: ${AUTH_PASSWORD}"
    fi
    AUTH_PASSWORD="${AUTH_PASSWORD:0:8}"
}

# ------------------------------------------------------------------------------
# IP address validation
# ------------------------------------------------------------------------------
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            [ "$octet" -le 255 ] || return 1
        done
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# List network interfaces
# ------------------------------------------------------------------------------
list_interfaces() {
    ip -o link show | awk '{print $2}' | sed 's/://' | grep -v "^lo$" | grep -v "@" | while read -r iface; do
        local state ip_addr
        state=$(ip -o link show "$iface" 2>/dev/null | awk '{print $9}')
        ip_addr=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
        printf "    %-20s %-8s %s\n" "$iface" "$state" "${ip_addr:-not assigned}"
    done
}

# ------------------------------------------------------------------------------
# 1. Check and install packages
# ------------------------------------------------------------------------------
check_and_install_packages() {
    print_section "1. Package Installation Check"

    if rpm -q keepalived &>/dev/null; then
        log_success "keepalived already installed: $(rpm -q keepalived)"
        return 0
    fi

    log_warn "keepalived is not installed."

    local pkg_dir="${SCRIPT_DIR}/install_package"
    local keepalived_rpm
    keepalived_rpm=$(find "$pkg_dir" -name "keepalived-*.rpm" 2>/dev/null | head -1)

    if [ -z "$keepalived_rpm" ]; then
        log_error "No keepalived RPM file found in install_package/ directory."
        error_exit "Place RPM files in install_package/ or run check_environment.sh first."
    fi

    local rpm_count
    rpm_count=$(find "$pkg_dir" -name "*.rpm" 2>/dev/null | wc -l)
    log_info "Available RPMs: ${pkg_dir} (total: ${rpm_count})"
    log_info "keepalived: $(basename "$keepalived_rpm")"
    echo ""

    local install_choice="Y"
    if ! $AUTO_CONFIRM; then
        read -r -p "  Install keepalived and dependencies? [Y/n]: " install_choice
        install_choice="${install_choice:-Y}"
    else
        log_info "Auto-installing via --yes option"
    fi

    if [[ "$install_choice" =~ ^[Nn]$ ]]; then
        error_exit "keepalived installation skipped. Install it and retry."
    fi

    log_info "Installing packages..."
    if rpm -ivh --nodeps "${pkg_dir}"/*.rpm >> "$REPORT_FILE" 2>&1; then
        log_success "Package installation complete"
    else
        rpm -ivh --nodeps --force "${pkg_dir}"/*.rpm >> "$REPORT_FILE" 2>&1 || \
            error_exit "Package installation failed. Check the report: ${REPORT_FILE}"
        log_success "Package installation complete (forced)"
    fi

    rpm -q keepalived &>/dev/null || error_exit "keepalived installation verification failed"
    log_success "keepalived installation verified: $(rpm -q keepalived)"
}

# ------------------------------------------------------------------------------
# 2. Pre-condition checks
# ------------------------------------------------------------------------------
check_preconditions() {
    print_section "2. Pre-condition Check"

    # Root privilege check
    if [ "$EUID" -ne 0 ]; then
        error_exit "Root privilege required. Run as: sudo ./install.sh"
    fi
    log_success "Root privilege confirmed"

    # OS check
    if [ ! -f /etc/rocky-release ] && [ ! -f /etc/redhat-release ]; then
        error_exit "Unsupported OS. Rocky Linux 8/9 or RHEL-based system required."
    fi
    local os_ver
    os_ver=$(grep "^VERSION=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    log_success "OS verified: $(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"') ${os_ver}"

    # keepalived installation check
    if ! rpm -q keepalived &>/dev/null; then
        error_exit "keepalived is not installed. Run check_environment.sh to install packages first."
    fi
    log_success "keepalived installation verified: $(rpm -q keepalived)"

    # Template file existence check
    if [ ! -f "${CONF_DIR}/keepalived.conf.template" ]; then
        error_exit "keepalived.conf.template not found. (path: ${CONF_DIR}/keepalived.conf.template)"
    fi
    log_success "keepalived.conf.template found"

    if [ ! -f "${CONF_DIR}/service_check.conf" ]; then
        error_exit "service_check.conf not found. (path: ${CONF_DIR}/service_check.conf)"
    fi
    log_success "service_check.conf found"
}

# ------------------------------------------------------------------------------
# 3. Review service_check.conf
# ------------------------------------------------------------------------------
review_service_check_conf() {
    # Skip in non-interactive mode
    if $NON_INTERACTIVE; then
        log_info "Non-interactive mode — skipping service_check.conf review"
        return 0
    fi

    print_section "3. Review service_check.conf"

    local conf_file="${CONF_DIR}/service_check.conf"
    if [ ! -f "$conf_file" ]; then
        log_warn "service_check.conf not found. Create it manually after installation."
        return 0
    fi

    while true; do
        # Re-read file to reflect latest values
        unset PORT_LIST PROCESS_LIST DB_ENABLED DB_HOST DB_PORT DB_USER FAILBACK_DELAY REPLICATION_LAG_LIMIT
        # shellcheck source=/dev/null
        source "$conf_file"

        echo ""
        echo -e "  ${BOLD}Current service_check.conf settings:${NC}"
        echo ""
        printf "    %-22s %s\n" "Port check:"       "${PORT_LIST[*]:-not set}"
        printf "    %-22s %s\n" "Process check:"    "${PROCESS_LIST[*]:-not set}"
        printf "    %-22s %s\n" "DB replication:"   "${DB_ENABLED:-no}"
        if [ "${DB_ENABLED}" == "yes" ]; then
            printf "    %-22s %s\n" "DB connection:"    "${DB_HOST}:${DB_PORT} (user: ${DB_USER})"
        fi
        printf "    %-22s %s\n" "Failback delay:"   "${FAILBACK_DELAY:-300}s"
        printf "    %-22s %s\n" "Replication lag:"  "${REPLICATION_LAG_LIMIT:-30}s"
        echo ""

        read -r -p "  Proceed with these settings? [y/N/e(edit)]: " choice
        echo ""
        case "$choice" in
            y|Y)
                log_success "service_check.conf settings confirmed"
                break
                ;;
            e|E)
                ${EDITOR:-vi} "$conf_file"
                ;;
            *)
                echo -e "${YELLOW}Installation cancelled.${NC}"
                exit 0
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 4. Collect installation info (interactive)
# ------------------------------------------------------------------------------
collect_install_info() {
    print_section "4. Installation Info"

    # Non-interactive mode: load from config file
    if $NON_INTERACTIVE; then
        load_from_config

        echo ""
        echo -e "${BOLD}  ┌─────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}  │           Installation Info (from config file)        │${NC}"
        echo -e "${BOLD}  ├─────────────────────────────────────────────────────┤${NC}"
        printf "  │  %-20s %-30s │\n" "Config file:"  "${CONFIG_FILE}"
        printf "  │  %-20s %-30s │\n" "Server role:"  "${ROLE} (${VRRP_STATE}, priority=${VRRP_PRIORITY})"
        printf "  │  %-20s %-30s │\n" "Virtual IP:"   "${VIP}"
        printf "  │  %-20s %-30s │\n" "Interface:"    "${VRRP_INTERFACE}"
        printf "  │  %-20s %-30s │\n" "Server IP:"    "${CURRENT_IP}"
        printf "  │  %-20s %-30s │\n" "Peer IP:"      "${PEER_IP}"
        printf "  │  %-20s %-30s │\n" "Failover delay:" "~$((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))s (${HEALTH_CHECK_INTERVAL}s x ${HEALTH_CHECK_FALL} fails)"
        printf "  │  %-20s %-30s │\n" "VRRP password:" "${AUTH_PASSWORD}"
        echo -e "${BOLD}  └─────────────────────────────────────────────────────┘${NC}"
        echo ""

        if $AUTO_CONFIRM; then
            log_info "Auto-confirmed via --yes option"
        else
            read -r -p "  Proceed with installation using the above settings? [y/N]: " final_confirm
            echo ""
            if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Installation cancelled.${NC}"
                exit 0
            fi
        fi
        return
    fi

    # Interactive mode
    echo -e "  Enter information required for keepalived HA configuration."
    echo -e "  ${YELLOW}(Press Enter to use the default value where available)${NC}"
    echo ""

    # ── Server role ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[Server Role]${NC}"
    echo -e "    1) active  — MASTER server (holds VIP normally, priority 100)"
    echo -e "    2) standby — BACKUP server (takes over VIP on failure, priority 90)"
    echo ""
    while true; do
        read -r -p "  Select role [1/2]: " role_input
        case "$role_input" in
            1|active)
                ROLE="active"
                VRRP_STATE="MASTER"
                VRRP_PRIORITY=100
                echo -e "  → Configured as ${GREEN}Active (MASTER)${NC} server."
                break
                ;;
            2|standby)
                ROLE="standby"
                VRRP_STATE="BACKUP"
                VRRP_PRIORITY=90
                echo -e "  → Configured as ${GREEN}Standby (BACKUP)${NC} server."
                break
                ;;
            *)
                echo -e "  ${RED}Please enter 1 or 2.${NC}"
                ;;
        esac
    done
    echo ""

    # ── VIP address ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[Virtual IP (VIP)]${NC}"
    echo -e "  Virtual IP address shared between Active and Standby servers."
    echo -e "  Must be in the same subnet as the server IP and must not be in use."
    echo ""
    while true; do
        read -r -p "  Enter VIP (e.g. 192.168.0.100): " VIP
        if validate_ip "$VIP"; then
            echo -e "  → VIP: ${GREEN}${VIP}${NC}"
            break
        else
            echo -e "  ${RED}Enter a valid IP address. (e.g. 192.168.0.100)${NC}"
        fi
    done
    echo ""

    # ── Network interface ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[Network Interface]${NC}"
    echo -e "  Interface to bind VIP. Available interfaces on this server:"
    echo ""
    list_interfaces
    echo ""
    local default_iface
    default_iface=$(ip -o link show | awk '{print $2}' | sed 's/://' | grep -v "^lo$" | grep -v "@" | head -1)
    while true; do
        read -r -p "  Enter interface [default: ${default_iface}]: " VRRP_INTERFACE
        VRRP_INTERFACE="${VRRP_INTERFACE:-$default_iface}"
        if ip link show "$VRRP_INTERFACE" &>/dev/null; then
            CURRENT_IP=$(ip -o -4 addr show "$VRRP_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
            echo -e "  → Interface: ${GREEN}${VRRP_INTERFACE}${NC} (IP: ${CURRENT_IP:-not assigned})"
            if [ -z "$CURRENT_IP" ]; then
                echo -e "  ${YELLOW}Warning: No IP assigned to the selected interface.${NC}"
                read -r -p "  Continue anyway? [y/N]: " cont
                [[ "$cont" =~ ^[Yy]$ ]] || continue
            fi
            break
        else
            echo -e "  ${RED}Interface not found. Please select from the list.${NC}"
        fi
    done
    echo ""

    # ── Current server IP ────────────────────────────────────────────────────────
    if [ -z "$CURRENT_IP" ]; then
        echo -e "  ${BOLD}[Current Server IP]${NC}"
        while true; do
            read -r -p "  Enter current server IP: " CURRENT_IP
            validate_ip "$CURRENT_IP" && break
            echo -e "  ${RED}Enter a valid IP address.${NC}"
        done
        echo -e "  → Current server IP: ${GREEN}${CURRENT_IP}${NC}"
        echo ""
    fi

    # ── Peer server IP ───────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[Peer Server IP]${NC}"
    echo -e "  IP address of the peer server in HA configuration."
    if [[ "$ROLE" == "active" ]]; then
        echo -e "  (Enter the Standby server IP)"
    else
        echo -e "  (Enter the Active server IP)"
    fi
    echo ""
    while true; do
        read -r -p "  Enter peer server IP: " PEER_IP
        if validate_ip "$PEER_IP"; then
            if [ "$PEER_IP" == "$CURRENT_IP" ]; then
                echo -e "  ${RED}Same as current server IP. Enter a different IP.${NC}"
            else
                echo -e "  → Peer server IP: ${GREEN}${PEER_IP}${NC}"
                break
            fi
        else
            echo -e "  ${RED}Enter a valid IP address.${NC}"
        fi
    done
    echo ""

    # ── Failover detection delay ─────────────────────────────────────────────────
    echo -e "  ${BOLD}[Failover Detection Delay]${NC}"
    echo -e "  Time from service failure detection to VIP failover."
    echo -e "  Determined by: health check interval (${HEALTH_CHECK_INTERVAL}s) × consecutive failure count."
    echo -e "  ${YELLOW}Recommended: 10s or more (too short may trigger failover on transient issues)${NC}"
    echo ""
    while true; do
        read -r -p "  Enter failover detection delay [default: 10s]: " FAILOVER_DELAY_INPUT
        FAILOVER_DELAY_INPUT="${FAILOVER_DELAY_INPUT:-10}"
        if [[ "$FAILOVER_DELAY_INPUT" =~ ^[0-9]+$ ]] && [ "$FAILOVER_DELAY_INPUT" -ge 2 ]; then
            FAILOVER_DELAY="$FAILOVER_DELAY_INPUT"
            # Calculate consecutive failure count: ceil(delay / interval)
            HEALTH_CHECK_FALL=$(( (FAILOVER_DELAY + HEALTH_CHECK_INTERVAL - 1) / HEALTH_CHECK_INTERVAL ))
            local actual_delay=$(( HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL ))
            echo -e "  → Failover detection: ${GREEN}~${actual_delay}s${NC} (${HEALTH_CHECK_INTERVAL}s interval × ${HEALTH_CHECK_FALL} consecutive failures)"
            break
        else
            echo -e "  ${RED}Enter a number >= 2.${NC}"
        fi
    done
    echo ""

    # ── VRRP authentication password ─────────────────────────────────────────────
    echo -e "  ${BOLD}[VRRP Authentication Password]${NC}"
    echo -e "  Used for VRRP communication authentication between servers. (max 8 chars)"
    echo -e "  Must be identical on both Active and Standby servers."
    local default_pass
    default_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 8 || echo "KAGuard1")
    echo ""
    read -r -p "  Enter password [default: ${default_pass}]: " AUTH_PASSWORD_INPUT
    AUTH_PASSWORD="${AUTH_PASSWORD_INPUT:-$default_pass}"
    AUTH_PASSWORD="${AUTH_PASSWORD:0:8}"
    echo -e "  → VRRP password: ${GREEN}${AUTH_PASSWORD}${NC}"
    echo ""

    # ── Final confirmation ───────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}  │              Final Installation Summary               │${NC}"
    echo -e "${BOLD}  ├─────────────────────────────────────────────────────┤${NC}"
    printf "  │  %-20s %-30s │\n" "Server role:"  "${ROLE} (${VRRP_STATE}, priority=${VRRP_PRIORITY})"
    printf "  │  %-20s %-30s │\n" "Virtual IP:"   "${VIP}"
    printf "  │  %-20s %-30s │\n" "Interface:"    "${VRRP_INTERFACE}"
    printf "  │  %-20s %-30s │\n" "Server IP:"    "${CURRENT_IP}"
    printf "  │  %-20s %-30s │\n" "Peer IP:"      "${PEER_IP}"
    printf "  │  %-20s %-30s │\n" "Failover delay:" "~$((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))s (${HEALTH_CHECK_INTERVAL}s x ${HEALTH_CHECK_FALL} fails)"
    printf "  │  %-20s %-30s │\n" "VRRP password:" "${AUTH_PASSWORD}"
    echo -e "${BOLD}  └─────────────────────────────────────────────────────┘${NC}"
    echo ""
    read -r -p "  Proceed with installation using the above settings? [y/N]: " final_confirm
    echo ""
    if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# 3. Backup existing config
# ------------------------------------------------------------------------------
backup_configs() {
    print_section "5. Backup Existing Config"

    mkdir -p "$BACKUP_DIR"
    log_info "Backup directory: ${BACKUP_DIR}"

    local backed_up=false

    if [ -f /etc/keepalived/keepalived.conf ]; then
        cp /etc/keepalived/keepalived.conf "${BACKUP_DIR}/keepalived.conf"
        log_success "Backed up: keepalived.conf"
        backed_up=true
    fi

    if [ -f /etc/keepalived/service_check.conf ]; then
        cp /etc/keepalived/service_check.conf "${BACKUP_DIR}/service_check.conf"
        log_success "Backed up: service_check.conf"
        backed_up=true
    fi

    if [ -f /usr/local/bin/service_health_check.sh ]; then
        cp /usr/local/bin/service_health_check.sh "${BACKUP_DIR}/service_health_check.sh"
        log_success "Backed up: service_health_check.sh"
        backed_up=true
    fi

    if [ -f /usr/local/bin/service_recovery_check.sh ]; then
        cp /usr/local/bin/service_recovery_check.sh "${BACKUP_DIR}/service_recovery_check.sh"
        log_success "Backed up: service_recovery_check.sh"
        backed_up=true
    fi

    if ! $backed_up; then
        log_info "No existing config files found — fresh installation"
    fi

    # Auto-generate restore script
    cat > "${BACKUP_DIR}/restore.sh" <<'RESTORE_EOF'
#!/bin/bash
# Keepalive Guardian Restore Script
# Generated: TIMESTAMP_PLACEHOLDER

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Stopping keepalived service..."
systemctl stop keepalived 2>/dev/null

echo "Restoring config files..."
[ -f "${BACKUP_DIR}/keepalived.conf" ]        && cp "${BACKUP_DIR}/keepalived.conf"        /etc/keepalived/
[ -f "${BACKUP_DIR}/service_check.conf" ]     && cp "${BACKUP_DIR}/service_check.conf"     /etc/keepalived/
[ -f "${BACKUP_DIR}/service_health_check.sh" ]   && cp "${BACKUP_DIR}/service_health_check.sh"   /usr/local/bin/ && chmod +x /usr/local/bin/service_health_check.sh
[ -f "${BACKUP_DIR}/service_recovery_check.sh" ] && cp "${BACKUP_DIR}/service_recovery_check.sh" /usr/local/bin/ && chmod +x /usr/local/bin/service_recovery_check.sh

echo "Starting keepalived service..."
systemctl start keepalived 2>/dev/null
systemctl status keepalived --no-pager

echo "Restore complete."
RESTORE_EOF
    sed -i "s/TIMESTAMP_PLACEHOLDER/${TIMESTAMP}/" "${BACKUP_DIR}/restore.sh"
    chmod +x "${BACKUP_DIR}/restore.sh"
    log_success "Restore script created: ${BACKUP_DIR}/restore.sh"
}

# ------------------------------------------------------------------------------
# 4. Generate keepalived.conf
# ------------------------------------------------------------------------------
generate_keepalived_conf() {
    print_section "6. Generate keepalived.conf"

    mkdir -p /etc/keepalived

    sed \
        -e "s/{{ROUTER_ID}}/$(hostname)/g" \
        -e "s/{{VRRP_STATE}}/${VRRP_STATE}/g" \
        -e "s/{{VRRP_INTERFACE}}/${VRRP_INTERFACE}/g" \
        -e "s/{{VRRP_ROUTER_ID}}/${VRRP_ROUTER_ID}/g" \
        -e "s/{{VRRP_PRIORITY}}/${VRRP_PRIORITY}/g" \
        -e "s/{{VRRP_VIRTUAL_IP}}/${VIP}/g" \
        -e "s/{{AUTH_PASSWORD}}/${AUTH_PASSWORD}/g" \
        -e "s/{{HEALTH_CHECK_INTERVAL}}/${HEALTH_CHECK_INTERVAL}/g" \
        -e "s/{{HEALTH_CHECK_FALL}}/${HEALTH_CHECK_FALL}/g" \
        -e "s/{{CURRENT_IP}}/${CURRENT_IP}/g" \
        -e "s/{{PEER_IP}}/${PEER_IP}/g" \
        "${CONF_DIR}/keepalived.conf.template" > /etc/keepalived/keepalived.conf

    log_success "keepalived.conf generated: /etc/keepalived/keepalived.conf"

    # Review generated config
    log_info "Key settings in generated keepalived.conf:"
    grep -E "state|priority|interface|virtual_router_id|virtual_ipaddress|unicast_src_ip|unicast_peer|interval|fall" \
        /etc/keepalived/keepalived.conf | sed 's/^/      /'
}

# ------------------------------------------------------------------------------
# 5. Deploy service_check.conf
# ------------------------------------------------------------------------------
deploy_service_check_conf() {
    print_section "7. Deploy service_check.conf"

    cp "${CONF_DIR}/service_check.conf" /etc/keepalived/service_check.conf
    chmod 600 /etc/keepalived/service_check.conf
    log_success "service_check.conf deployed: /etc/keepalived/service_check.conf"
    log_info "File permission set to 600 (DB password protection)"
    log_info "Edit the file below to configure service ports/processes/DB:"
    log_info "  vi /etc/keepalived/service_check.conf"
}

# ------------------------------------------------------------------------------
# 6. Deploy health check scripts
# ------------------------------------------------------------------------------
deploy_health_check_scripts() {
    print_section "8. Deploy Health Check Scripts"

    local scripts=("service_health_check.sh" "service_recovery_check.sh")

    for script in "${scripts[@]}"; do
        if [ -f "${SCRIPTS_DIR}/${script}" ]; then
            cp "${SCRIPTS_DIR}/${script}" /usr/local/bin/
            chmod +x "/usr/local/bin/${script}"
            log_success "${script} deployed: /usr/local/bin/${script}"
        else
            log_warn "${script} not found — deploy manually later"
            log_info "  Source: ${SCRIPTS_DIR}/${script}"
        fi
    done
}

# ------------------------------------------------------------------------------
# 7. Allow VRRP through firewall
# ------------------------------------------------------------------------------
configure_firewall() {
    print_section "9. Firewall Configuration"

    if ! systemctl is-active firewalld &>/dev/null; then
        log_warn "firewalld not running — skipping firewall configuration"
        return
    fi

    local vrrp_allowed
    vrrp_allowed=$(firewall-cmd --list-rich-rules 2>/dev/null | grep -c "protocol.*vrrp")

    if [ "$vrrp_allowed" -gt 0 ]; then
        log_info "VRRP firewall rule already configured"
    else
        firewall-cmd --add-rich-rule='rule protocol value="vrrp" accept' --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_success "VRRP protocol (112) firewall rule added"
    fi
}

# ------------------------------------------------------------------------------
# 8. Configure log rotation
# ------------------------------------------------------------------------------
configure_logrotate() {
    print_section "10. Log Rotation Configuration"

    cat > /etc/logrotate.d/service-ha-check <<'EOF'
/var/log/service_ha_check.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
    log_success "Log rotation configured: /etc/logrotate.d/service-ha-check"
}

# ------------------------------------------------------------------------------
# 9. Start keepalived service
# ------------------------------------------------------------------------------
start_keepalived() {
    print_section "11. Start keepalived Service"

    systemctl enable keepalived &>/dev/null
    log_success "keepalived enabled for auto-start"

    if systemctl restart keepalived 2>/dev/null; then
        sleep 2
        if systemctl is-active keepalived &>/dev/null; then
            log_success "keepalived service started successfully"
        else
            log_error "keepalived service failed to start"
            log_info "Check logs: journalctl -u keepalived -n 30 --no-pager"
            return 1
        fi
    else
        log_error "keepalived restart failed"
        log_info "Check logs: journalctl -u keepalived -n 30 --no-pager"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 10. Verify installation
# ------------------------------------------------------------------------------
verify_installation() {
    print_section "12. Verify Installation"

    # Service status
    if systemctl is-active keepalived &>/dev/null; then
        log_success "keepalived service: running"
    else
        log_error "keepalived service: stopped"
    fi

    # VIP assignment check (only Active server holds VIP)
    if [[ "$ROLE" == "active" ]]; then
        sleep 3
        if ip addr show "$VRRP_INTERFACE" | grep -q "$VIP"; then
            log_success "VIP assigned: ${VIP} → ${VRRP_INTERFACE}"
        else
            log_warn "VIP not yet assigned — waiting for VRRP to stabilize (will be assigned shortly)"
        fi
    else
        log_info "Standby server — VIP will be assigned automatically on Active failure"
    fi

    # Config file check
    [ -f /etc/keepalived/keepalived.conf ]    && log_success "Config file exists: /etc/keepalived/keepalived.conf"
    [ -f /etc/keepalived/service_check.conf ] && log_success "Config file exists: /etc/keepalived/service_check.conf"
    [ -x /usr/local/bin/service_health_check.sh ]   && log_success "Script exists: /usr/local/bin/service_health_check.sh"
    [ -x /usr/local/bin/service_recovery_check.sh ] && log_success "Script exists: /usr/local/bin/service_recovery_check.sh"
}

# ------------------------------------------------------------------------------
# Final completion message
# ------------------------------------------------------------------------------
print_completion() {
    echo ""
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "${BOLD}  Installation Complete${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Keepalive Guardian has been installed successfully.${NC}"
    echo ""
    echo -e "  ${BOLD}Configuration Summary:${NC}"
    printf "    %-20s %s\n" "Role:"         "${ROLE} (${VRRP_STATE})"
    printf "    %-20s %s\n" "Virtual IP:"   "${VIP}"
    printf "    %-20s %s\n" "Interface:"    "${VRRP_INTERFACE}"
    printf "    %-20s %s\n" "Server IP:"    "${CURRENT_IP}"
    printf "    %-20s %s\n" "Peer IP:"      "${PEER_IP}"
    printf "    %-20s %s\n" "Failover:"     "~$((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))s"
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo -e "  1. Configure health check targets:"
    echo -e "     ${CYAN}vi /etc/keepalived/service_check.conf${NC}"
    echo -e "  2. Run install.sh on the peer server (${PEER_IP}) as well"
    echo -e "  3. Verify VIP assignment:"
    echo -e "     ${CYAN}ip addr show ${VRRP_INTERFACE} | grep ${VIP}${NC}"
    echo -e "  4. Monitor HA logs:"
    echo -e "     ${CYAN}tail -f /var/log/service_ha_check.log${NC}"
    echo ""
    echo -e "  ${BOLD}Backup location:${NC} ${BACKUP_DIR}"
    echo -e "  ${BOLD}Install report:${NC} ${REPORT_FILE}"
    echo -e "  ${BOLD}Restore script:${NC} ${BACKUP_DIR}/restore.sh"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""

    # Write completion info to report
    cat >> "$REPORT_FILE" <<EOF

======================================================================
  Installation Complete Report
======================================================================
  Completed:  $(date '+%Y-%m-%d %H:%M:%S')
  Role:       ${ROLE} (${VRRP_STATE}, priority=${VRRP_PRIORITY})
  Virtual IP: ${VIP}
  Interface:  ${VRRP_INTERFACE}
  Server IP:  ${CURRENT_IP}
  Peer IP:    ${PEER_IP}
  Failover:   ~$((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))s (${HEALTH_CHECK_INTERVAL}s x ${HEALTH_CHECK_FALL} fails)
  Backup:     ${BACKUP_DIR}
======================================================================
EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Initialize report
    mkdir -p "$(dirname "$REPORT_FILE")"
    echo "Keepalive Guardian Install Report — $(date '+%Y-%m-%d %H:%M:%S')" > "$REPORT_FILE"
    echo "Server: $(hostname) ($(hostname -I | awk '{print $1}'))" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    print_banner

    check_and_install_packages
    check_preconditions
    review_service_check_conf
    collect_install_info
    backup_configs
    generate_keepalived_conf
    deploy_service_check_conf
    deploy_health_check_scripts
    configure_firewall
    configure_logrotate
    start_keepalived
    verify_installation
    print_completion
}

main "$@"
