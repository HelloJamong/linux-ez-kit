#!/bin/bash

# Rocky Linux Network Bonding Configuration Script
# Author: Assistant
# Description: Configure network bonding using configuration file with backup/restore functionality

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration file path
CONFIG_FILE="bonding.conf"

# Backup directory
BACKUP_DIR="/backup/nic_info_backup"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CURRENT_BACKUP_DIR="${BACKUP_DIR}/${BACKUP_TIMESTAMP}"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to check if config file exists
check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file '$CONFIG_FILE' not found"
        print_info "Please create $CONFIG_FILE in the same directory as this script"
        exit 1
    fi
}

# Function to create backup directory
create_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        print_info "Creating backup directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
    fi
    
    mkdir -p "$CURRENT_BACKUP_DIR"
    print_info "Backup directory created: $CURRENT_BACKUP_DIR"
}

# Function to backup network configuration
backup_network_config() {
    print_step "Backing up current network configuration..."
    
    create_backup_dir
    
    # Backup nmcli connections
    print_info "Backing up NetworkManager connections..."
    nmcli connection show > "${CURRENT_BACKUP_DIR}/nmcli_connections.txt" 2>/dev/null || true
    
    # Backup detailed connection info for all connections
    print_info "Backing up detailed connection information..."
    local connections=$(nmcli -t -f NAME connection show)
    while IFS= read -r conn; do
        if [ -n "$conn" ]; then
            local safe_name=$(echo "$conn" | tr ' /' '_')
            nmcli connection show "$conn" > "${CURRENT_BACKUP_DIR}/connection_${safe_name}.txt" 2>/dev/null || true
        fi
    done <<< "$connections"
    
    # Backup NetworkManager connection files
    print_info "Backing up NetworkManager connection files..."
    if [ -d "/etc/NetworkManager/system-connections" ]; then
        mkdir -p "${CURRENT_BACKUP_DIR}/system-connections"
        cp -a /etc/NetworkManager/system-connections/* "${CURRENT_BACKUP_DIR}/system-connections/" 2>/dev/null || true
    fi
    
    if [ -d "/etc/sysconfig/network-scripts" ]; then
        mkdir -p "${CURRENT_BACKUP_DIR}/network-scripts"
        cp -a /etc/sysconfig/network-scripts/ifcfg-* "${CURRENT_BACKUP_DIR}/network-scripts/" 2>/dev/null || true
    fi
    
    # Backup current interface status
    print_info "Backing up interface status..."
    ip addr show > "${CURRENT_BACKUP_DIR}/ip_addr.txt"
    ip link show > "${CURRENT_BACKUP_DIR}/ip_link.txt"
    ip route show > "${CURRENT_BACKUP_DIR}/ip_route.txt"
    
    # Backup bonding information if exists
    if [ -d "/proc/net/bonding" ]; then
        print_info "Backing up existing bonding configuration..."
        mkdir -p "${CURRENT_BACKUP_DIR}/bonding"
        for bond in /proc/net/bonding/*; do
            if [ -f "$bond" ]; then
                bond_name=$(basename "$bond")
                cp "$bond" "${CURRENT_BACKUP_DIR}/bonding/${bond_name}.txt"
            fi
        done
    fi
    
    # Create backup info file
    cat > "${CURRENT_BACKUP_DIR}/backup_info.txt" <<EOF
Backup Timestamp: ${BACKUP_TIMESTAMP}
Backup Date: $(date)
Hostname: $(hostname)
OS: $(cat /etc/redhat-release 2>/dev/null || echo "Unknown")
Kernel: $(uname -r)
NetworkManager Version: $(NetworkManager --version 2>/dev/null || echo "Unknown")

This backup was created before applying bonding configuration.
To restore this backup, run: ./set_bonding.sh --restore ${BACKUP_TIMESTAMP}
EOF
    
    # Create restore script
    cat > "${CURRENT_BACKUP_DIR}/restore.sh" <<'RESTORE_SCRIPT'
#!/bin/bash

# Network Configuration Restore Script
# This script restores the network configuration from backup

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

BACKUP_DIR=$(dirname "$0")

print_info "Starting network configuration restore..."
print_warn "This will remove current network configuration and restore from backup"
read -p "Do you want to continue? (yes/no): " confirm

if [ "${confirm,,}" != "yes" ]; then
    print_warn "Restore cancelled"
    exit 0
fi

# Stop NetworkManager
print_info "Stopping NetworkManager..."
systemctl stop NetworkManager

# Remove current connections
print_info "Removing current connections..."
if [ -d "/etc/NetworkManager/system-connections" ]; then
    rm -f /etc/NetworkManager/system-connections/*
fi

# Restore system-connections
if [ -d "${BACKUP_DIR}/system-connections" ]; then
    print_info "Restoring NetworkManager connection files..."
    cp -a "${BACKUP_DIR}/system-connections"/* /etc/NetworkManager/system-connections/ 2>/dev/null || true
    chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true
fi

# Restore network-scripts if needed
if [ -d "${BACKUP_DIR}/network-scripts" ] && [ -d "/etc/sysconfig/network-scripts" ]; then
    print_info "Restoring network-scripts..."
    cp -a "${BACKUP_DIR}/network-scripts"/* /etc/sysconfig/network-scripts/ 2>/dev/null || true
fi

# Restart NetworkManager
print_info "Starting NetworkManager..."
systemctl start NetworkManager

# Wait for NetworkManager to initialize
sleep 3

# Reload connections
print_info "Reloading connections..."
nmcli connection reload

print_info "Restore completed!"
print_info "Current connections:"
nmcli connection show

echo ""
print_warn "Please verify your network connectivity"
print_info "If you have issues, you may need to manually activate connections:"
echo "  nmcli connection up <connection-name>"
RESTORE_SCRIPT

    chmod +x "${CURRENT_BACKUP_DIR}/restore.sh"
    
    print_info "Backup completed successfully!"
    print_info "Backup location: $CURRENT_BACKUP_DIR"
    print_info "To restore this backup later, run:"
    echo "  cd $CURRENT_BACKUP_DIR && sudo ./restore.sh"
    echo ""
}

# Function to list available backups
list_backups() {
    print_info "Available backups in $BACKUP_DIR:"
    echo ""
    
    if [ ! -d "$BACKUP_DIR" ]; then
        print_warn "No backup directory found"
        return
    fi
    
    local count=0
    for backup in "$BACKUP_DIR"/*; do
        if [ -d "$backup" ] && [ -f "$backup/backup_info.txt" ]; then
            count=$((count + 1))
            local backup_name=$(basename "$backup")
            echo "[$count] Backup: $backup_name"
            grep "Backup Date:" "$backup/backup_info.txt" 2>/dev/null || true
            echo "    Location: $backup"
            echo ""
        fi
    done
    
    if [ $count -eq 0 ]; then
        print_warn "No backups found"
    fi
}

# Function to restore from backup
restore_from_backup() {
    local backup_timestamp=$1
    local restore_dir="${BACKUP_DIR}/${backup_timestamp}"
    
    if [ ! -d "$restore_dir" ]; then
        print_error "Backup not found: $restore_dir"
        exit 1
    fi
    
    if [ ! -f "$restore_dir/restore.sh" ]; then
        print_error "Restore script not found in backup"
        exit 1
    fi
    
    print_info "Restoring from backup: $backup_timestamp"
    cd "$restore_dir"
    bash ./restore.sh
}

# Function to load configuration
load_config() {
    print_info "Loading configuration from $CONFIG_FILE..."
    source "$CONFIG_FILE"
}

# Function to validate interface exists
validate_interface() {
    local iface=$1
    if ! ip link show "$iface" &> /dev/null; then
        print_error "Interface $iface does not exist"
        return 1
    fi
    return 0
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        print_error "Invalid IP address format: $ip"
        return 1
    fi
    return 0
}

# Function to validate configuration
validate_bond0_config() {
    if [ "${BOND0_ENABLED,,}" != "yes" ]; then
        return 0
    fi

    print_step "Validating bond0 configuration..."

    if ! validate_interface "$BOND0_PRIMARY_NIC"; then
        return 1
    fi
    if ! validate_interface "$BOND0_SECONDARY_NIC"; then
        return 1
    fi

    if [ -z "$BOND0_IP" ]; then
        print_error "BOND0_IP is not set"
        return 1
    fi
    if ! validate_ip "$BOND0_IP"; then
        return 1
    fi

    if [ -z "$BOND0_PREFIX" ]; then
        print_error "BOND0_PREFIX is not set"
        return 1
    fi

    if [ -z "$BOND0_GATEWAY" ]; then
        print_error "BOND0_GATEWAY is not set"
        return 1
    fi
    if ! validate_ip "$BOND0_GATEWAY"; then
        return 1
    fi

    print_info "bond0 configuration is valid"
    return 0
}

# Function to validate bond1 configuration
validate_bond1_config() {
    if [ "${BOND1_ENABLED,,}" != "yes" ]; then
        return 0
    fi

    print_step "Validating bond1 configuration..."

    if ! validate_interface "$BOND1_PRIMARY_NIC"; then
        return 1
    fi
    if ! validate_interface "$BOND1_SECONDARY_NIC"; then
        return 1
    fi

    if [ -z "$BOND1_BRIDGE_MASTER" ]; then
        print_error "BOND1_BRIDGE_MASTER is not set"
        return 1
    fi

    print_info "bond1 configuration is valid"
    return 0
}

# Function to remove existing bond configuration
remove_existing_bond() {
    local bond_name=$1
    print_info "Checking for existing $bond_name configuration..."
    
    if nmcli connection show "$bond_name" &> /dev/null; then
        print_warn "Existing $bond_name found, removing..."
        nmcli connection delete "$bond_name" 2>/dev/null || true
    fi
    
    if nmcli connection show "${bond_name}-slave1" &> /dev/null; then
        nmcli connection delete "${bond_name}-slave1" 2>/dev/null || true
    fi
    
    if nmcli connection show "${bond_name}-slave2" &> /dev/null; then
        nmcli connection delete "${bond_name}-slave2" 2>/dev/null || true
    fi
}

# Function to configure bond0
configure_bond0() {
    if [ "${BOND0_ENABLED,,}" != "yes" ]; then
        print_info "bond0 is disabled, skipping..."
        return 0
    fi

    print_step "Configuring bond0..."

    remove_existing_bond "bond0"

    print_info "Creating bond0 interface..."
    nmcli connection add type bond con-name bond0 ifname bond0 \
        bond.options "mode=active-backup,miimon=100,fail_over_mac=active,primary=$BOND0_PRIMARY_NIC"

    print_info "Configuring IP settings for bond0..."
    local ip_with_prefix="${BOND0_IP}/${BOND0_PREFIX}"
    nmcli connection modify bond0 ipv4.method manual ipv4.addresses "$ip_with_prefix"
    nmcli connection modify bond0 ipv4.gateway "$BOND0_GATEWAY"
    
    if [ -n "$BOND0_DNS" ]; then
        nmcli connection modify bond0 ipv4.dns "$BOND0_DNS"
    fi

    nmcli connection modify bond0 ipv6.method ignore
    nmcli connection modify bond0 connection.autoconnect-slaves 1

    print_info "Adding slave interfaces to bond0..."
    nmcli connection add type ethernet con-name bond0-slave1 ifname "$BOND0_PRIMARY_NIC" master bond0
    nmcli connection add type ethernet con-name bond0-slave2 ifname "$BOND0_SECONDARY_NIC" master bond0

    print_info "Activating bond0 and its slaves..."
    nmcli connection up bond0-slave1
    nmcli connection up bond0-slave2
    nmcli connection up bond0

    print_info "bond0 configuration completed successfully!"
    echo ""
}

# Function to configure bond1
configure_bond1() {
    if [ "${BOND1_ENABLED,,}" != "yes" ]; then
        print_info "bond1 is disabled, skipping..."
        return 0
    fi

    print_step "Configuring bond1..."

    remove_existing_bond "bond1"

    print_info "Creating bond1 interface..."
    nmcli connection add type bond con-name bond1 ifname bond1 \
        bond.options "mode=active-backup,miimon=100,fail_over_mac=active,primary=$BOND1_PRIMARY_NIC"

    print_info "Configuring bond1 as bridge slave..."
    nmcli connection modify bond1 ipv4.method disabled
    nmcli connection modify bond1 ipv6.method ignore
    nmcli connection modify bond1 connection.autoconnect-slaves 1
    nmcli connection modify bond1 master "$BOND1_BRIDGE_MASTER"

    print_info "Adding slave interfaces to bond1..."
    nmcli connection add type ethernet con-name bond1-slave1 ifname "$BOND1_PRIMARY_NIC" master bond1
    nmcli connection add type ethernet con-name bond1-slave2 ifname "$BOND1_SECONDARY_NIC" master bond1

    print_info "Activating bond1 and its slaves..."
    nmcli connection up bond1-slave1
    nmcli connection up bond1-slave2
    nmcli connection up bond1

    print_info "bond1 configuration completed successfully!"
    echo ""
}

# Function to display configuration summary
display_summary() {
    echo ""
    echo "=========================================="
    echo "  Configuration Summary"
    echo "=========================================="
    
    if [ "${BOND0_ENABLED,,}" == "yes" ]; then
        echo ""
        echo "BOND0:"
        echo "  Status: Enabled"
        echo "  Primary NIC: $BOND0_PRIMARY_NIC"
        echo "  Secondary NIC: $BOND0_SECONDARY_NIC"
        echo "  IP Address: ${BOND0_IP}/${BOND0_PREFIX}"
        echo "  Gateway: $BOND0_GATEWAY"
        [ -n "$BOND0_DNS" ] && echo "  DNS: $BOND0_DNS"
    else
        echo ""
        echo "BOND0: Disabled"
    fi

    if [ "${BOND1_ENABLED,,}" == "yes" ]; then
        echo ""
        echo "BOND1:"
        echo "  Status: Enabled"
        echo "  Primary NIC: $BOND1_PRIMARY_NIC"
        echo "  Secondary NIC: $BOND1_SECONDARY_NIC"
        echo "  Bridge Master: $BOND1_BRIDGE_MASTER"
        echo "  IP Address: None (Bridge Slave)"
    else
        echo ""
        echo "BOND1: Disabled"
    fi
    
    echo ""
    echo "=========================================="
    echo ""
}

# Function to display status after configuration
display_status() {
    echo ""
    print_info "=========================================="
    print_info "  Bonding Status"
    print_info "=========================================="
    echo ""

    if [ "${BOND0_ENABLED,,}" == "yes" ]; then
        if [ -f "/proc/net/bonding/bond0" ]; then
            print_info "bond0 status:"
            cat /proc/net/bonding/bond0 | head -20
            echo ""
        fi
    fi

    if [ "${BOND1_ENABLED,,}" == "yes" ]; then
        if [ -f "/proc/net/bonding/bond1" ]; then
            print_info "bond1 status:"
            cat /proc/net/bonding/bond1 | head -20
            echo ""
        fi
    fi

    print_info "Network connections:"
    nmcli connection show | grep -E "bond|NAME"
    echo ""
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no options)           Run normal bonding configuration"
    echo "  --list-backups         List all available backups"
    echo "  --restore <timestamp>  Restore from specific backup"
    echo "  --help                 Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                              # Configure bonding with backup"
    echo "  $0 --list-backups               # List available backups"
    echo "  $0 --restore 20250126_143022    # Restore from backup"
    echo ""
}

# Main script
main() {
    # Parse command line arguments
    case "${1:-}" in
        --list-backups)
            list_backups
            exit 0
            ;;
        --restore)
            if [ -z "$2" ]; then
                print_error "Please specify backup timestamp"
                echo ""
                list_backups
                exit 1
            fi
            restore_from_backup "$2"
            exit 0
            ;;
        --help)
            show_usage
            exit 0
            ;;
        "")
            # Normal operation - continue below
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac

    clear
    echo "=========================================="
    echo "  Network Bonding Configuration Script"
    echo "=========================================="
    echo ""

    check_root
    check_config_file

    # Backup current configuration
    backup_network_config
    echo ""

    # Load and validate configuration
    load_config
    display_summary

    # Ask for confirmation
    read -p "Do you want to proceed with this configuration? (yes/no): " confirm
    if [ "${confirm,,}" != "yes" ]; then
        print_warn "Configuration cancelled by user"
        print_info "Backup has been saved at: $CURRENT_BACKUP_DIR"
        exit 0
    fi

    echo ""

    # Validate configurations
    if ! validate_bond0_config; then
        print_error "bond0 configuration validation failed"
        exit 1
    fi

    if ! validate_bond1_config; then
        print_error "bond1 configuration validation failed"
        exit 1
    fi

    echo ""

    # Configure bonding
    configure_bond0
    configure_bond1

    # Display final status
    display_status

    print_info "=========================================="
    print_info "Configuration completed successfully!"
    print_info "=========================================="
    echo ""
    print_info "Backup location: $CURRENT_BACKUP_DIR"
    print_info "To restore this backup, run:"
    echo "  cd $CURRENT_BACKUP_DIR && sudo ./restore.sh"
    echo ""
    print_info "You can also restore using:"
    echo "  sudo ./set_bonding.sh --restore $BACKUP_TIMESTAMP"
    echo ""
    print_info "To list all backups:"
    echo "  sudo ./set_bonding.sh --list-backups"
    echo ""
}

# Run main function
main "$@"