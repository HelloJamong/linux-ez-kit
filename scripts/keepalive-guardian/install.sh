#!/bin/bash

################################################################################
# Keepalive Guardian - 서비스 설치 스크립트
#
# 목적: keepalived 기반 Active-Standby HA 서비스 자동 구성
# 사용법:
#   대화형:     sudo ./install.sh
#   비대화형:   sudo ./install.sh --config install.conf
#               sudo ./install.sh --config install.conf --yes
# 환경: Rocky Linux 8.x / 9.x
################################################################################

# ------------------------------------------------------------------------------
# 변수 정의
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backup/keepalive-guardian/backup_${TIMESTAMP}"
REPORT_FILE="${SCRIPT_DIR}/install_report_${TIMESTAMP}.txt"

VERSION="v26.03.01"        # 스크립트 버전 (YY.MM.일련번호)

VRRP_ROUTER_ID=51          # 동일 L2 네트워크에서 고유한 VRRP 그룹 ID
HEALTH_CHECK_INTERVAL=2    # 헬스체크 실행 주기 (초, 고정)

NON_INTERACTIVE=false      # --config 옵션 사용 시 true
CONFIG_FILE=""             # --config 로 지정한 설정 파일 경로
AUTO_CONFIRM=false         # --yes 옵션 사용 시 최종 확인 자동 승인

# ------------------------------------------------------------------------------
# 컬러 정의
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# 출력 함수
# ------------------------------------------------------------------------------
print_banner() {
    echo ""
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "${BOLD}       Keepalive Guardian - 서비스 설치 스크립트${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "  버전:      ${CYAN}${VERSION}${NC}"
    echo -e "  설치 시작: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  대상 서버: $(hostname) ($(hostname -I | awk '{print $1}'))"
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
    echo -e "${RED}설치가 중단되었습니다. 보고서: ${REPORT_FILE}${NC}"
    exit 1
}

# ------------------------------------------------------------------------------
# 인수 파싱
# ------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                if [ -z "$2" ] || [[ "$2" == --* ]]; then
                    error_exit "--config 옵션에 설정 파일 경로가 필요합니다. (예: --config install.conf)"
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
                echo "사용법:"
                echo "  대화형:   sudo ./install.sh"
                echo "  비대화형: sudo ./install.sh --config <설정파일> [--yes]"
                echo ""
                echo "옵션:"
                echo "  --config <파일>  설정 파일을 지정하여 비대화형 설치 진행"
                echo "  --yes, -y        최종 확인 프롬프트 자동 승인"
                echo "  --help, -h       이 도움말 출력"
                echo ""
                exit 0
                ;;
            *)
                error_exit "알 수 없는 옵션: $1  (--help 로 사용법 확인)"
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 설정 파일 로드 (비대화형 모드)
# ------------------------------------------------------------------------------
load_from_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error_exit "설정 파일을 찾을 수 없습니다: ${CONFIG_FILE}"
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    log_info "설정 파일 로드: ${CONFIG_FILE}"

    # 필수 항목 검증
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
            errors+=("ROLE 이 설정되지 않았습니다. (active 또는 standby)")
            ;;
        *)
            errors+=("ROLE 값이 잘못되었습니다: '${ROLE}' (active 또는 standby 만 허용)")
            ;;
    esac

    if [ -z "$VIP" ]; then
        errors+=("VIP 가 설정되지 않았습니다.")
    elif ! validate_ip "$VIP"; then
        errors+=("VIP 형식이 잘못되었습니다: '${VIP}'")
    fi

    if [ -z "$PEER_IP" ]; then
        errors+=("PEER_IP 가 설정되지 않았습니다.")
    elif ! validate_ip "$PEER_IP"; then
        errors+=("PEER_IP 형식이 잘못되었습니다: '${PEER_IP}'")
    fi

    # FAILOVER_DELAY 기본값 및 검증
    FAILOVER_DELAY="${FAILOVER_DELAY:-10}"
    if ! [[ "$FAILOVER_DELAY" =~ ^[0-9]+$ ]] || [ "$FAILOVER_DELAY" -lt 2 ]; then
        errors+=("FAILOVER_DELAY 는 2 이상의 숫자여야 합니다: '${FAILOVER_DELAY}'")
    fi

    # 오류가 있으면 전부 출력 후 종료
    if [ "${#errors[@]}" -gt 0 ]; then
        log_error "설정 파일 오류 (${CONFIG_FILE}):"
        for err in "${errors[@]}"; do
            log_error "  - ${err}"
        done
        error_exit "설정 파일을 확인하고 다시 실행하세요."
    fi

    # 인터페이스 자동 감지 (미설정 시)
    if [ -z "$VRRP_INTERFACE" ]; then
        VRRP_INTERFACE=$(ip -o link show | awk '{print $2}' | sed 's/://' | grep -v "^lo$" | grep -v "@" | head -1)
        log_info "VRRP_INTERFACE 미설정 → 자동 감지: ${VRRP_INTERFACE}"
    fi

    if ! ip link show "$VRRP_INTERFACE" &>/dev/null; then
        error_exit "VRRP_INTERFACE '${VRRP_INTERFACE}' 가 존재하지 않습니다."
    fi

    # 현재 서버 IP 자동 감지 (미설정 시)
    if [ -z "$CURRENT_IP" ]; then
        CURRENT_IP=$(ip -o -4 addr show "$VRRP_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [ -z "$CURRENT_IP" ]; then
            error_exit "CURRENT_IP 를 자동 감지하지 못했습니다. 설정 파일에 직접 입력하세요."
        fi
        log_info "CURRENT_IP 미설정 → 자동 감지: ${CURRENT_IP}"
    elif ! validate_ip "$CURRENT_IP"; then
        error_exit "CURRENT_IP 형식이 잘못되었습니다: '${CURRENT_IP}'"
    fi

    if [ "$PEER_IP" == "$CURRENT_IP" ]; then
        error_exit "PEER_IP 와 CURRENT_IP 가 동일합니다. 상대 서버 IP를 확인하세요."
    fi

    # FAILBACK 감지 횟수 계산
    HEALTH_CHECK_FALL=$(( (FAILOVER_DELAY + HEALTH_CHECK_INTERVAL - 1) / HEALTH_CHECK_INTERVAL ))

    # VRRP 패스워드 자동 생성 (미설정 시)
    if [ -z "$AUTH_PASSWORD" ]; then
        AUTH_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 8 || echo "KAGuard1")
        log_info "AUTH_PASSWORD 미설정 → 자동 생성: ${AUTH_PASSWORD}"
        log_warn "상대 서버 설정 파일의 AUTH_PASSWORD 에 동일한 값을 입력하세요: ${AUTH_PASSWORD}"
    fi
    AUTH_PASSWORD="${AUTH_PASSWORD:0:8}"
}

# ------------------------------------------------------------------------------
# IP 유효성 검사
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
# 네트워크 인터페이스 목록 출력
# ------------------------------------------------------------------------------
list_interfaces() {
    ip -o link show | awk '{print $2}' | sed 's/://' | grep -v "^lo$" | grep -v "@" | while read -r iface; do
        local state ip_addr
        state=$(ip -o link show "$iface" 2>/dev/null | awk '{print $9}')
        ip_addr=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
        printf "    %-20s %-8s %s\n" "$iface" "$state" "${ip_addr:-IP 미할당}"
    done
}

# ------------------------------------------------------------------------------
# 1. 패키지 설치 확인 및 설치
# ------------------------------------------------------------------------------
check_and_install_packages() {
    print_section "1. 패키지 설치 확인"

    if rpm -q keepalived &>/dev/null; then
        log_success "keepalived 이미 설치됨: $(rpm -q keepalived)"
        return 0
    fi

    log_warn "keepalived 가 설치되어 있지 않습니다."

    local pkg_dir="${SCRIPT_DIR}/install_package"
    local keepalived_rpm
    keepalived_rpm=$(find "$pkg_dir" -name "keepalived-*.rpm" 2>/dev/null | head -1)

    if [ -z "$keepalived_rpm" ]; then
        log_error "install_package/ 폴더에 keepalived RPM 파일이 없습니다."
        error_exit "RPM 파일을 install_package/ 폴더에 준비하거나 check_environment.sh 를 먼저 실행하세요."
    fi

    local rpm_count
    rpm_count=$(find "$pkg_dir" -name "*.rpm" 2>/dev/null | wc -l)
    log_info "설치 가능한 RPM: ${pkg_dir} (총 ${rpm_count}개)"
    log_info "keepalived: $(basename "$keepalived_rpm")"
    echo ""

    local install_choice="Y"
    if ! $AUTO_CONFIRM; then
        read -r -p "  keepalived 및 의존성 패키지를 설치하시겠습니까? [Y/n]: " install_choice
        install_choice="${install_choice:-Y}"
    else
        log_info "--yes 옵션으로 자동 설치 진행"
    fi

    if [[ "$install_choice" =~ ^[Nn]$ ]]; then
        error_exit "keepalived 설치를 건너뛰었습니다. 설치 후 다시 실행하세요."
    fi

    log_info "패키지 설치 중..."
    if rpm -ivh --nodeps "${pkg_dir}"/*.rpm >> "$REPORT_FILE" 2>&1; then
        log_success "패키지 설치 완료"
    else
        rpm -ivh --nodeps --force "${pkg_dir}"/*.rpm >> "$REPORT_FILE" 2>&1 || \
            error_exit "패키지 설치 실패. 보고서를 확인하세요: ${REPORT_FILE}"
        log_success "패키지 설치 완료 (강제 설치)"
    fi

    rpm -q keepalived &>/dev/null || error_exit "keepalived 설치 확인 실패"
    log_success "keepalived 설치 확인: $(rpm -q keepalived)"
}

# ------------------------------------------------------------------------------
# 2. 사전 조건 확인
# ------------------------------------------------------------------------------
check_preconditions() {
    print_section "2. 사전 조건 확인"

    # Root 권한
    if [ "$EUID" -ne 0 ]; then
        error_exit "Root 권한이 필요합니다. sudo ./install.sh 로 실행하세요."
    fi
    log_success "Root 권한 확인"

    # OS 확인
    if [ ! -f /etc/rocky-release ] && [ ! -f /etc/redhat-release ]; then
        error_exit "지원되지 않는 OS입니다. Rocky Linux 8/9 또는 RHEL 계열이 필요합니다."
    fi
    local os_ver
    os_ver=$(grep "^VERSION=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    log_success "OS 확인: $(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"') ${os_ver}"

    # keepalived 설치 여부
    if ! rpm -q keepalived &>/dev/null; then
        error_exit "keepalived가 설치되어 있지 않습니다. 먼저 check_environment.sh 를 실행하여 패키지를 설치하세요."
    fi
    log_success "keepalived 설치 확인: $(rpm -q keepalived)"

    # 템플릿 파일 존재 확인
    if [ ! -f "${SCRIPT_DIR}/keepalived.conf.template" ]; then
        error_exit "keepalived.conf.template 파일이 없습니다. (경로: ${SCRIPT_DIR}/keepalived.conf.template)"
    fi
    log_success "keepalived.conf.template 확인"

    if [ ! -f "${SCRIPT_DIR}/service_check.conf" ]; then
        error_exit "service_check.conf 파일이 없습니다. (경로: ${SCRIPT_DIR}/service_check.conf)"
    fi
    log_success "service_check.conf 확인"
}

# ------------------------------------------------------------------------------
# 3. service_check.conf 검토
# ------------------------------------------------------------------------------
review_service_check_conf() {
    # 비대화형 모드에서는 건너뜀
    if $NON_INTERACTIVE; then
        log_info "비대화형 모드 — service_check.conf 검토 건너뜀"
        return 0
    fi

    print_section "3. service_check.conf 검토"

    local conf_file="${SCRIPT_DIR}/service_check.conf"
    if [ ! -f "$conf_file" ]; then
        log_warn "service_check.conf 파일이 없습니다. 설치 후 직접 생성하세요."
        return 0
    fi

    while true; do
        # 파일을 다시 읽어 최신 값 반영
        unset PORT_LIST PROCESS_LIST DB_ENABLED DB_HOST DB_PORT DB_USER FAILBACK_DELAY REPLICATION_LAG_LIMIT
        # shellcheck source=/dev/null
        source "$conf_file"

        echo ""
        echo -e "  ${BOLD}현재 service_check.conf 설정:${NC}"
        echo ""
        printf "    %-22s %s\n" "포트 체크:"       "${PORT_LIST[*]:-설정 없음}"
        printf "    %-22s %s\n" "프로세스 체크:"   "${PROCESS_LIST[*]:-설정 없음}"
        printf "    %-22s %s\n" "DB 복제 체크:"    "${DB_ENABLED:-no}"
        if [ "${DB_ENABLED}" == "yes" ]; then
            printf "    %-22s %s\n" "DB 접속:"     "${DB_HOST}:${DB_PORT} (사용자: ${DB_USER})"
        fi
        printf "    %-22s %s\n" "Failback 대기:"   "${FAILBACK_DELAY:-300}초"
        printf "    %-22s %s\n" "복제 지연 한계:"  "${REPLICATION_LAG_LIMIT:-30}초"
        echo ""

        read -r -p "  이 설정으로 진행하시겠습니까? [y/N/e(편집)]: " choice
        echo ""
        case "$choice" in
            y|Y)
                log_success "service_check.conf 설정 확인 완료"
                break
                ;;
            e|E)
                ${EDITOR:-vi} "$conf_file"
                ;;
            *)
                echo -e "${YELLOW}설치가 취소되었습니다.${NC}"
                exit 0
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 4. 설치 정보 입력 (대화형)
# ------------------------------------------------------------------------------
collect_install_info() {
    print_section "4. 설치 정보 입력"

    # 비대화형 모드: 설정 파일에서 로드
    if $NON_INTERACTIVE; then
        load_from_config

        echo ""
        echo -e "${BOLD}  ┌─────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}  │              설치 정보 (설정 파일 로드)              │${NC}"
        echo -e "${BOLD}  ├─────────────────────────────────────────────────────┤${NC}"
        printf "  │  %-20s %-30s │\n" "설정 파일:"    "${CONFIG_FILE}"
        printf "  │  %-20s %-30s │\n" "서버 역할:"    "${ROLE} (${VRRP_STATE}, priority=${VRRP_PRIORITY})"
        printf "  │  %-20s %-30s │\n" "Virtual IP:"   "${VIP}"
        printf "  │  %-20s %-30s │\n" "인터페이스:"   "${VRRP_INTERFACE}"
        printf "  │  %-20s %-30s │\n" "현재 서버 IP:" "${CURRENT_IP}"
        printf "  │  %-20s %-30s │\n" "상대 서버 IP:" "${PEER_IP}"
        printf "  │  %-20s %-30s │\n" "장애 감지 시간:" "약 $((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))초 (${HEALTH_CHECK_INTERVAL}초 × ${HEALTH_CHECK_FALL}회)"
        printf "  │  %-20s %-30s │\n" "VRRP 패스워드:" "${AUTH_PASSWORD}"
        echo -e "${BOLD}  └─────────────────────────────────────────────────────┘${NC}"
        echo ""

        if $AUTO_CONFIRM; then
            log_info "--yes 옵션으로 자동 확인"
        else
            read -r -p "  위 내용으로 설치를 진행하시겠습니까? [y/N]: " final_confirm
            echo ""
            if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}설치가 취소되었습니다.${NC}"
                exit 0
            fi
        fi
        return
    fi

    # 대화형 모드 (기존 로직)
    echo -e "  keepalived HA 구성에 필요한 정보를 입력합니다."
    echo -e "  ${YELLOW}(기본값이 있는 항목은 Enter 키로 기본값을 사용할 수 있습니다)${NC}"
    echo ""

    # ── 서버 역할 ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[서버 역할]${NC}"
    echo -e "    1) active  — MASTER 서버 (평상시 VIP 보유, 우선순위 100)"
    echo -e "    2) standby — BACKUP 서버 (장애 시 VIP 인계, 우선순위 90)"
    echo ""
    while true; do
        read -r -p "  역할 선택 [1/2]: " role_input
        case "$role_input" in
            1|active)
                ROLE="active"
                VRRP_STATE="MASTER"
                VRRP_PRIORITY=100
                echo -e "  → ${GREEN}Active (MASTER)${NC} 서버로 설정합니다."
                break
                ;;
            2|standby)
                ROLE="standby"
                VRRP_STATE="BACKUP"
                VRRP_PRIORITY=90
                echo -e "  → ${GREEN}Standby (BACKUP)${NC} 서버로 설정합니다."
                break
                ;;
            *)
                echo -e "  ${RED}1 또는 2를 입력하세요.${NC}"
                ;;
        esac
    done
    echo ""

    # ── VIP 주소 ───────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[Virtual IP (VIP)]${NC}"
    echo -e "  Active/Standby 두 서버가 공유할 가상 IP 주소입니다."
    echo -e "  현재 서버 IP와 동일 대역이어야 하며, 사용 중이지 않은 IP여야 합니다."
    echo ""
    while true; do
        read -r -p "  VIP 입력 (예: 192.168.0.100): " VIP
        if validate_ip "$VIP"; then
            echo -e "  → VIP: ${GREEN}${VIP}${NC}"
            break
        else
            echo -e "  ${RED}올바른 IP 형식을 입력하세요. (예: 192.168.0.100)${NC}"
        fi
    done
    echo ""

    # ── 네트워크 인터페이스 ────────────────────────────────────────────────────
    echo -e "  ${BOLD}[네트워크 인터페이스]${NC}"
    echo -e "  VIP를 바인딩할 인터페이스입니다. 현재 서버의 인터페이스 목록:"
    echo ""
    list_interfaces
    echo ""
    local default_iface
    default_iface=$(ip -o link show | awk '{print $2}' | sed 's/://' | grep -v "^lo$" | grep -v "@" | head -1)
    while true; do
        read -r -p "  인터페이스 입력 [기본값: ${default_iface}]: " VRRP_INTERFACE
        VRRP_INTERFACE="${VRRP_INTERFACE:-$default_iface}"
        if ip link show "$VRRP_INTERFACE" &>/dev/null; then
            CURRENT_IP=$(ip -o -4 addr show "$VRRP_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
            echo -e "  → 인터페이스: ${GREEN}${VRRP_INTERFACE}${NC} (IP: ${CURRENT_IP:-미할당})"
            if [ -z "$CURRENT_IP" ]; then
                echo -e "  ${YELLOW}경고: 선택한 인터페이스에 IP가 할당되어 있지 않습니다.${NC}"
                read -r -p "  계속 진행하시겠습니까? [y/N]: " cont
                [[ "$cont" =~ ^[Yy]$ ]] || continue
            fi
            break
        else
            echo -e "  ${RED}존재하지 않는 인터페이스입니다. 목록에서 선택하세요.${NC}"
        fi
    done
    echo ""

    # ── 현재 서버 IP 확인 ──────────────────────────────────────────────────────
    if [ -z "$CURRENT_IP" ]; then
        echo -e "  ${BOLD}[현재 서버 IP]${NC}"
        while true; do
            read -r -p "  현재 서버 IP 입력: " CURRENT_IP
            validate_ip "$CURRENT_IP" && break
            echo -e "  ${RED}올바른 IP 형식을 입력하세요.${NC}"
        done
        echo -e "  → 현재 서버 IP: ${GREEN}${CURRENT_IP}${NC}"
        echo ""
    fi

    # ── 상대 서버 IP ───────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[상대 서버 IP]${NC}"
    echo -e "  HA 구성 상대방 서버의 IP 주소입니다."
    if [[ "$ROLE" == "active" ]]; then
        echo -e "  (Standby 서버의 IP를 입력하세요)"
    else
        echo -e "  (Active 서버의 IP를 입력하세요)"
    fi
    echo ""
    while true; do
        read -r -p "  상대 서버 IP 입력: " PEER_IP
        if validate_ip "$PEER_IP"; then
            if [ "$PEER_IP" == "$CURRENT_IP" ]; then
                echo -e "  ${RED}현재 서버 IP와 동일합니다. 다른 IP를 입력하세요.${NC}"
            else
                echo -e "  → 상대 서버 IP: ${GREEN}${PEER_IP}${NC}"
                break
            fi
        else
            echo -e "  ${RED}올바른 IP 형식을 입력하세요.${NC}"
        fi
    done
    echo ""

    # ── 장애 전환 감지 시간 ────────────────────────────────────────────────────
    echo -e "  ${BOLD}[장애 전환 감지 시간]${NC}"
    echo -e "  서비스 장애 감지 후 VIP를 전환하기까지 걸리는 시간입니다."
    echo -e "  헬스체크 주기(${HEALTH_CHECK_INTERVAL}초) × 연속 실패 횟수로 결정됩니다."
    echo -e "  ${YELLOW}권장: 10초 이상 (너무 짧으면 일시적 장애에도 Failover 발생)${NC}"
    echo ""
    while true; do
        read -r -p "  장애 전환 감지 시간 입력 [기본값: 10초]: " FAILOVER_DELAY_INPUT
        FAILOVER_DELAY_INPUT="${FAILOVER_DELAY_INPUT:-10}"
        if [[ "$FAILOVER_DELAY_INPUT" =~ ^[0-9]+$ ]] && [ "$FAILOVER_DELAY_INPUT" -ge 2 ]; then
            FAILOVER_DELAY="$FAILOVER_DELAY_INPUT"
            # 연속 실패 횟수 계산: ceil(delay / interval)
            HEALTH_CHECK_FALL=$(( (FAILOVER_DELAY + HEALTH_CHECK_INTERVAL - 1) / HEALTH_CHECK_INTERVAL ))
            local actual_delay=$(( HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL ))
            echo -e "  → 장애 감지: ${GREEN}약 ${actual_delay}초${NC} (${HEALTH_CHECK_INTERVAL}초 간격 × ${HEALTH_CHECK_FALL}회 연속 실패)"
            break
        else
            echo -e "  ${RED}2 이상의 숫자를 입력하세요.${NC}"
        fi
    done
    echo ""

    # ── VRRP 인증 패스워드 ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}[VRRP 인증 패스워드]${NC}"
    echo -e "  두 서버 간 VRRP 통신 인증에 사용됩니다. (최대 8자)"
    echo -e "  Active/Standby 양쪽에 동일한 값을 입력해야 합니다."
    local default_pass
    default_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 8 || echo "KAGuard1")
    echo ""
    read -r -p "  패스워드 입력 [기본값: ${default_pass}]: " AUTH_PASSWORD_INPUT
    AUTH_PASSWORD="${AUTH_PASSWORD_INPUT:-$default_pass}"
    AUTH_PASSWORD="${AUTH_PASSWORD:0:8}"
    echo -e "  → VRRP 패스워드: ${GREEN}${AUTH_PASSWORD}${NC}"
    echo ""

    # ── 입력 정보 최종 확인 ────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}  │              설치 정보 최종 확인                    │${NC}"
    echo -e "${BOLD}  ├─────────────────────────────────────────────────────┤${NC}"
    printf "  │  %-20s %-30s │\n" "서버 역할:"    "${ROLE} (${VRRP_STATE}, priority=${VRRP_PRIORITY})"
    printf "  │  %-20s %-30s │\n" "Virtual IP:"   "${VIP}"
    printf "  │  %-20s %-30s │\n" "인터페이스:"   "${VRRP_INTERFACE}"
    printf "  │  %-20s %-30s │\n" "현재 서버 IP:" "${CURRENT_IP}"
    printf "  │  %-20s %-30s │\n" "상대 서버 IP:" "${PEER_IP}"
    printf "  │  %-20s %-30s │\n" "장애 감지 시간:" "약 $((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))초 (${HEALTH_CHECK_INTERVAL}초 × ${HEALTH_CHECK_FALL}회)"
    printf "  │  %-20s %-30s │\n" "VRRP 패스워드:" "${AUTH_PASSWORD}"
    echo -e "${BOLD}  └─────────────────────────────────────────────────────┘${NC}"
    echo ""
    read -r -p "  위 내용으로 설치를 진행하시겠습니까? [y/N]: " final_confirm
    echo ""
    if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}설치가 취소되었습니다.${NC}"
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# 3. 기존 설정 백업
# ------------------------------------------------------------------------------
backup_configs() {
    print_section "5. 기존 설정 백업"

    mkdir -p "$BACKUP_DIR"
    log_info "백업 디렉토리: ${BACKUP_DIR}"

    local backed_up=false

    if [ -f /etc/keepalived/keepalived.conf ]; then
        cp /etc/keepalived/keepalived.conf "${BACKUP_DIR}/keepalived.conf"
        log_success "백업 완료: keepalived.conf"
        backed_up=true
    fi

    if [ -f /etc/keepalived/service_check.conf ]; then
        cp /etc/keepalived/service_check.conf "${BACKUP_DIR}/service_check.conf"
        log_success "백업 완료: service_check.conf"
        backed_up=true
    fi

    if [ -f /usr/local/bin/service_health_check.sh ]; then
        cp /usr/local/bin/service_health_check.sh "${BACKUP_DIR}/service_health_check.sh"
        log_success "백업 완료: service_health_check.sh"
        backed_up=true
    fi

    if [ -f /usr/local/bin/service_recovery_check.sh ]; then
        cp /usr/local/bin/service_recovery_check.sh "${BACKUP_DIR}/service_recovery_check.sh"
        log_success "백업 완료: service_recovery_check.sh"
        backed_up=true
    fi

    if ! $backed_up; then
        log_info "기존 설정 파일 없음 — 신규 설치"
    fi

    # 복구 스크립트 자동 생성
    cat > "${BACKUP_DIR}/restore.sh" <<'RESTORE_EOF'
#!/bin/bash
# Keepalive Guardian 복구 스크립트
# 생성 시각: TIMESTAMP_PLACEHOLDER

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "keepalived 서비스 중지..."
systemctl stop keepalived 2>/dev/null

echo "설정 파일 복구 중..."
[ -f "${BACKUP_DIR}/keepalived.conf" ]        && cp "${BACKUP_DIR}/keepalived.conf"        /etc/keepalived/
[ -f "${BACKUP_DIR}/service_check.conf" ]     && cp "${BACKUP_DIR}/service_check.conf"     /etc/keepalived/
[ -f "${BACKUP_DIR}/service_health_check.sh" ]   && cp "${BACKUP_DIR}/service_health_check.sh"   /usr/local/bin/ && chmod +x /usr/local/bin/service_health_check.sh
[ -f "${BACKUP_DIR}/service_recovery_check.sh" ] && cp "${BACKUP_DIR}/service_recovery_check.sh" /usr/local/bin/ && chmod +x /usr/local/bin/service_recovery_check.sh

echo "keepalived 서비스 시작..."
systemctl start keepalived 2>/dev/null
systemctl status keepalived --no-pager

echo "복구 완료."
RESTORE_EOF
    sed -i "s/TIMESTAMP_PLACEHOLDER/${TIMESTAMP}/" "${BACKUP_DIR}/restore.sh"
    chmod +x "${BACKUP_DIR}/restore.sh"
    log_success "복구 스크립트 생성: ${BACKUP_DIR}/restore.sh"
}

# ------------------------------------------------------------------------------
# 4. keepalived.conf 생성
# ------------------------------------------------------------------------------
generate_keepalived_conf() {
    print_section "6. keepalived.conf 생성"

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
        "${SCRIPT_DIR}/keepalived.conf.template" > /etc/keepalived/keepalived.conf

    log_success "keepalived.conf 생성 완료: /etc/keepalived/keepalived.conf"

    # 생성된 설정 내용 확인
    log_info "생성된 keepalived.conf 주요 내용:"
    grep -E "state|priority|interface|virtual_router_id|virtual_ipaddress|unicast_src_ip|unicast_peer|interval|fall" \
        /etc/keepalived/keepalived.conf | sed 's/^/      /'
}

# ------------------------------------------------------------------------------
# 5. service_check.conf 배포
# ------------------------------------------------------------------------------
deploy_service_check_conf() {
    print_section "7. service_check.conf 배포"

    cp "${SCRIPT_DIR}/service_check.conf" /etc/keepalived/service_check.conf
    chmod 600 /etc/keepalived/service_check.conf
    log_success "service_check.conf 배포 완료: /etc/keepalived/service_check.conf"
    log_info "파일 권한 600 설정 완료 (DB 패스워드 보호)"
    log_info "서비스 포트/프로세스/DB 정보는 아래 파일을 편집하세요:"
    log_info "  vi /etc/keepalived/service_check.conf"
}

# ------------------------------------------------------------------------------
# 6. 헬스체크 스크립트 배포
# ------------------------------------------------------------------------------
deploy_health_check_scripts() {
    print_section "8. 헬스체크 스크립트 배포"

    local scripts=("service_health_check.sh" "service_recovery_check.sh")

    for script in "${scripts[@]}"; do
        if [ -f "${SCRIPT_DIR}/${script}" ]; then
            cp "${SCRIPT_DIR}/${script}" /usr/local/bin/
            chmod +x "/usr/local/bin/${script}"
            log_success "${script} 배포 완료: /usr/local/bin/${script}"
        else
            log_warn "${script} 파일 없음 — 나중에 수동으로 배포하세요"
            log_info "  위치: ${SCRIPT_DIR}/${script}"
        fi
    done
}

# ------------------------------------------------------------------------------
# 7. 방화벽 VRRP 허용
# ------------------------------------------------------------------------------
configure_firewall() {
    print_section "9. 방화벽 설정"

    if ! systemctl is-active firewalld &>/dev/null; then
        log_warn "firewalld 미실행 — 방화벽 설정 건너뜀"
        return
    fi

    local vrrp_allowed
    vrrp_allowed=$(firewall-cmd --list-rich-rules 2>/dev/null | grep -c "protocol.*vrrp")

    if [ "$vrrp_allowed" -gt 0 ]; then
        log_info "VRRP 방화벽 규칙 이미 설정됨"
    else
        firewall-cmd --add-rich-rule='rule protocol value="vrrp" accept' --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_success "VRRP 프로토콜(112) 방화벽 허용 설정 완료"
    fi
}

# ------------------------------------------------------------------------------
# 8. 로그 로테이션 설정
# ------------------------------------------------------------------------------
configure_logrotate() {
    print_section "10. 로그 로테이션 설정"

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
    log_success "로그 로테이션 설정 완료: /etc/logrotate.d/service-ha-check"
}

# ------------------------------------------------------------------------------
# 9. keepalived 서비스 시작
# ------------------------------------------------------------------------------
start_keepalived() {
    print_section "11. keepalived 서비스 시작"

    systemctl enable keepalived &>/dev/null
    log_success "keepalived 자동 시작 활성화 (enable)"

    if systemctl restart keepalived 2>/dev/null; then
        sleep 2
        if systemctl is-active keepalived &>/dev/null; then
            log_success "keepalived 서비스 시작 완료"
        else
            log_error "keepalived 서비스 시작 실패"
            log_info "로그 확인: journalctl -u keepalived -n 30 --no-pager"
            return 1
        fi
    else
        log_error "keepalived restart 실패"
        log_info "로그 확인: journalctl -u keepalived -n 30 --no-pager"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 10. 설치 결과 검증
# ------------------------------------------------------------------------------
verify_installation() {
    print_section "12. 설치 결과 검증"

    # 서비스 상태
    if systemctl is-active keepalived &>/dev/null; then
        log_success "keepalived 서비스: 실행 중"
    else
        log_error "keepalived 서비스: 중지 상태"
    fi

    # VIP 할당 확인 (Active 서버만 VIP 보유)
    if [[ "$ROLE" == "active" ]]; then
        sleep 3
        if ip addr show "$VRRP_INTERFACE" | grep -q "$VIP"; then
            log_success "VIP 할당 확인: ${VIP} → ${VRRP_INTERFACE}"
        else
            log_warn "VIP 미할당 — VRRP 통신 안정화 대기 중 (정상적으로 잠시 후 할당됩니다)"
        fi
    else
        log_info "Standby 서버 — VIP는 Active 장애 시 자동 할당됩니다"
    fi

    # 설정 파일 확인
    [ -f /etc/keepalived/keepalived.conf ]    && log_success "설정 파일 존재: /etc/keepalived/keepalived.conf"
    [ -f /etc/keepalived/service_check.conf ] && log_success "설정 파일 존재: /etc/keepalived/service_check.conf"
    [ -x /usr/local/bin/service_health_check.sh ]   && log_success "스크립트 존재: /usr/local/bin/service_health_check.sh"
    [ -x /usr/local/bin/service_recovery_check.sh ] && log_success "스크립트 존재: /usr/local/bin/service_recovery_check.sh"
}

# ------------------------------------------------------------------------------
# 최종 설치 완료 메시지
# ------------------------------------------------------------------------------
print_completion() {
    echo ""
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "${BOLD}  설치 완료${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Keepalive Guardian 설치가 완료되었습니다.${NC}"
    echo ""
    echo -e "  ${BOLD}구성 정보:${NC}"
    printf "    %-20s %s\n" "역할:"         "${ROLE} (${VRRP_STATE})"
    printf "    %-20s %s\n" "Virtual IP:"   "${VIP}"
    printf "    %-20s %s\n" "인터페이스:"   "${VRRP_INTERFACE}"
    printf "    %-20s %s\n" "현재 서버 IP:" "${CURRENT_IP}"
    printf "    %-20s %s\n" "상대 서버 IP:" "${PEER_IP}"
    printf "    %-20s %s\n" "장애 감지:"   "약 $((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))초"
    echo ""
    echo -e "  ${BOLD}다음 단계:${NC}"
    echo -e "  1. 헬스체크 대상 서비스 설정:"
    echo -e "     ${CYAN}vi /etc/keepalived/service_check.conf${NC}"
    echo -e "  2. 상대 서버(${PEER_IP})에서도 동일하게 install.sh 실행"
    echo -e "  3. VIP 동작 확인:"
    echo -e "     ${CYAN}ip addr show ${VRRP_INTERFACE} | grep ${VIP}${NC}"
    echo -e "  4. HA 로그 모니터링:"
    echo -e "     ${CYAN}tail -f /var/log/service_ha_check.log${NC}"
    echo ""
    echo -e "  ${BOLD}백업 위치:${NC} ${BACKUP_DIR}"
    echo -e "  ${BOLD}설치 보고서:${NC} ${REPORT_FILE}"
    echo -e "  ${BOLD}복구 스크립트:${NC} ${BACKUP_DIR}/restore.sh"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""

    # 보고서에 완료 정보 기록
    cat >> "$REPORT_FILE" <<EOF

======================================================================
  설치 완료 보고서
======================================================================
  설치 완료: $(date '+%Y-%m-%d %H:%M:%S')
  서버 역할: ${ROLE} (${VRRP_STATE}, priority=${VRRP_PRIORITY})
  Virtual IP: ${VIP}
  인터페이스: ${VRRP_INTERFACE}
  현재 서버:  ${CURRENT_IP}
  상대 서버:  ${PEER_IP}
  장애 감지:  약 $((HEALTH_CHECK_INTERVAL * HEALTH_CHECK_FALL))초 (${HEALTH_CHECK_INTERVAL}초 × ${HEALTH_CHECK_FALL}회)
  백업 위치:  ${BACKUP_DIR}
======================================================================
EOF
}

# ------------------------------------------------------------------------------
# 메인
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"

    # 보고서 초기화
    mkdir -p "$(dirname "$REPORT_FILE")"
    echo "Keepalive Guardian 설치 보고서 — $(date '+%Y-%m-%d %H:%M:%S')" > "$REPORT_FILE"
    echo "서버: $(hostname) ($(hostname -I | awk '{print $1}'))" >> "$REPORT_FILE"
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
