#!/bin/bash

################################################################################
# Keepalive Guardian - 환경 점검 및 패키지 설치 스크립트
#
# 목적: keepalive-guardian 설치 전 환경 요구사항 점검 및 필수 패키지 자동 설치
# 사용법: sudo ./check_environment.sh
# 환경: Rocky Linux 8.x / 9.x
################################################################################

# ------------------------------------------------------------------------------
# 변수 정의
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${SCRIPT_DIR}/environment_check_report_${TIMESTAMP}.txt"
PKG_DIR="${SCRIPT_DIR}/install_package"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# 미설치 패키지 추적 배열
MISSING_PKGS=()

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
    echo -e "${BOLD}    Keepalive Guardian - 환경 점검 및 패키지 설치 스크립트${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "  점검 시작: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  대상 서버: $(hostname) ($(hostname -I | awk '{print $1}'))"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}${BOLD}[ $1 ]${NC}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

result_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    echo "  [PASS] $1" >> "$REPORT_FILE"
    ((PASS_COUNT++))
}

result_warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    echo "  [WARN] $1" >> "$REPORT_FILE"
    ((WARN_COUNT++))
}

result_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    echo "  [FAIL] $1" >> "$REPORT_FILE"
    ((FAIL_COUNT++))
}

result_info() {
    echo -e "  ${BLUE}[INFO]${NC} $1"
    echo "  [INFO] $1" >> "$REPORT_FILE"
}

# ------------------------------------------------------------------------------
# 보고서 헤더 초기화
# ------------------------------------------------------------------------------
init_report() {
    cat > "$REPORT_FILE" <<EOF
======================================================================
  Keepalive Guardian - 환경 점검 보고서
======================================================================
  점검 일시: $(date '+%Y-%m-%d %H:%M:%S')
  대상 서버: $(hostname)
  IP 주소:   $(hostname -I | awk '{print $1}')
======================================================================

EOF
}

# ------------------------------------------------------------------------------
# 1. Root 권한 확인
# ------------------------------------------------------------------------------
check_root() {
    print_section "1. 실행 권한 확인"
    echo "[ 1. 실행 권한 확인 ]" >> "$REPORT_FILE"

    if [ "$EUID" -eq 0 ]; then
        result_pass "Root 권한으로 실행 중"
    else
        result_fail "Root 권한 필요 (현재 사용자: $(whoami)) — sudo ./check_environment.sh 로 실행하세요"
        echo ""
        echo -e "${RED}Root 권한이 없으면 패키지 설치를 진행할 수 없습니다. 스크립트를 종료합니다.${NC}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 2. OS 버전 확인
# ------------------------------------------------------------------------------
check_os() {
    print_section "2. OS 버전 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 2. OS 버전 확인 ]" >> "$REPORT_FILE"

    if [ ! -f /etc/rocky-release ] && [ ! -f /etc/redhat-release ]; then
        result_fail "지원되지 않는 OS — Rocky Linux 8/9 또는 RHEL 계열이 필요합니다"
        return
    fi

    local os_name os_version full_ver kernel
    os_name=$(grep "^NAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    os_version=$(rpm -E %{rhel} 2>/dev/null)
    full_ver=$(grep "^VERSION=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    kernel=$(uname -r)

    if [[ "$os_version" == "9" || "$os_version" == "8" ]]; then
        result_pass "OS: ${os_name} ${full_ver} (RHEL ${os_version} 계열) — 지원 환경"
    else
        result_warn "OS: ${os_name} (RHEL ${os_version}) — 미검증 환경 (Rocky Linux 8/9 권장)"
    fi

    result_info "커널 버전: ${kernel}"
}

# ------------------------------------------------------------------------------
# 3. 필수 명령어 확인
# ------------------------------------------------------------------------------
check_commands() {
    print_section "3. 필수 명령어 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 3. 필수 명령어 확인 ]" >> "$REPORT_FILE"

    local required_cmds=(
        "ip:iproute"
        "systemctl:systemd"
        "pgrep:procps-ng"
        "firewall-cmd:firewalld"
        "nmcli:NetworkManager"
        "sed:sed"
        "awk:gawk"
    )

    for entry in "${required_cmds[@]}"; do
        local cmd="${entry%%:*}"
        local pkg="${entry##*:}"
        if command -v "$cmd" &>/dev/null; then
            result_pass "명령어 존재: ${cmd}"
        else
            result_fail "명령어 없음: ${cmd} — ${pkg} 패키지 설치 필요"
        fi
    done

    # mysql/mariadb 클라이언트 (선택)
    if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
        result_pass "DB 클라이언트: $(command -v mysql 2>/dev/null || command -v mariadb)"
    else
        result_warn "DB 클라이언트 없음 (mysql/mariadb) — DB 복제 체크 사용 시 설치 필요"
    fi
}

# ------------------------------------------------------------------------------
# 4. 필수 패키지 설치 여부 확인 (미설치 시 MISSING_PKGS 배열에 추가)
# ------------------------------------------------------------------------------
check_packages() {
    print_section "4. 패키지 설치 여부 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 4. 패키지 설치 여부 확인 ]" >> "$REPORT_FILE"

    # keepalived (필수)
    if rpm -q keepalived &>/dev/null; then
        result_pass "keepalived 설치됨: $(rpm -q keepalived)"
    else
        result_warn "keepalived 미설치"
        MISSING_PKGS+=("keepalived")
    fi

    # net-snmp-libs (keepalived 의존성)
    if rpm -q net-snmp-libs &>/dev/null; then
        result_pass "net-snmp-libs 설치됨: $(rpm -q net-snmp-libs | head -1)"
    else
        result_warn "net-snmp-libs 미설치 — keepalived 의존성"
        MISSING_PKGS+=("net-snmp-libs")
    fi

    # net-snmp-agent-libs (keepalived 의존성)
    if rpm -q net-snmp-agent-libs &>/dev/null; then
        result_pass "net-snmp-agent-libs 설치됨: $(rpm -q net-snmp-agent-libs | head -1)"
    else
        result_warn "net-snmp-agent-libs 미설치 — keepalived 의존성"
        MISSING_PKGS+=("net-snmp-agent-libs")
    fi

    # mariadb (선택 — DB 복제 체크용)
    if rpm -q mariadb &>/dev/null; then
        result_pass "mariadb 설치됨: $(rpm -q mariadb)"
    else
        result_warn "mariadb 미설치 — DB 복제 체크(DB_ENABLED=yes) 사용 시 필요"
        MISSING_PKGS+=("mariadb")
    fi
}

# ------------------------------------------------------------------------------
# 5. 네트워크 인터페이스 확인
# ------------------------------------------------------------------------------
check_network() {
    print_section "5. 네트워크 인터페이스 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 5. 네트워크 인터페이스 확인 ]" >> "$REPORT_FILE"

    local up_interfaces
    up_interfaces=$(ip -o link show | awk '{print $2}' | sed 's/://' | grep -v "^lo$" | grep -v "@")

    if [ -z "$up_interfaces" ]; then
        result_fail "활성 네트워크 인터페이스 없음"
        return
    fi

    local up_count=0
    while IFS= read -r iface; do
        local state ip_addr
        state=$(ip -o link show "$iface" 2>/dev/null | awk '{print $9}')
        ip_addr=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)

        if [[ "$state" == "UP" ]]; then
            if [ -n "$ip_addr" ]; then
                result_pass "인터페이스 UP: ${iface} — IP: ${ip_addr}"
            else
                result_info "인터페이스 UP: ${iface} — IP 미할당 (브리지/본딩 슬레이브)"
            fi
            ((up_count++))
        else
            result_info "인터페이스 DOWN: ${iface}"
        fi
    done <<< "$up_interfaces"

    [ "$up_count" -eq 0 ] && result_fail "UP 상태의 네트워크 인터페이스 없음"
    result_info "VRRP 인터페이스는 install.sh 실행 시 --interface 옵션으로 지정하세요"
}

# ------------------------------------------------------------------------------
# 6. 방화벽 설정 확인
# ------------------------------------------------------------------------------
check_firewall() {
    print_section "6. 방화벽 설정 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 6. 방화벽 설정 확인 ]" >> "$REPORT_FILE"

    if systemctl is-active firewalld &>/dev/null; then
        result_info "firewalld 실행 중"

        local vrrp_allowed
        vrrp_allowed=$(firewall-cmd --list-rich-rules 2>/dev/null | grep -c "protocol.*vrrp")

        if [ "$vrrp_allowed" -gt 0 ]; then
            result_pass "VRRP 프로토콜(112) 방화벽 허용됨"
        else
            result_warn "VRRP 프로토콜(112) 방화벽 미허용 — install.sh 실행 시 자동 설정됨"
            result_info "수동 설정: firewall-cmd --add-rich-rule='rule protocol value=\"vrrp\" accept' --permanent"
        fi

        local active_zone
        active_zone=$(firewall-cmd --get-active-zones 2>/dev/null | head -1)
        result_info "활성 Zone: ${active_zone:-확인 불가}"
    else
        result_warn "firewalld 미실행 — VRRP 통신은 가능하나 방화벽 관리 권장"
    fi
}

# ------------------------------------------------------------------------------
# 7. SELinux 상태 확인
# ------------------------------------------------------------------------------
check_selinux() {
    print_section "7. SELinux 상태 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 7. SELinux 상태 확인 ]" >> "$REPORT_FILE"

    if ! command -v getenforce &>/dev/null; then
        result_info "SELinux 도구 없음"
        return
    fi

    local selinux_status
    selinux_status=$(getenforce 2>/dev/null)

    case "$selinux_status" in
        Disabled)
            result_pass "SELinux: Disabled — 별도 설정 불필요"
            ;;
        Permissive)
            result_warn "SELinux: Permissive — Enforcing 전환 시 정책 확인 필요"
            ;;
        Enforcing)
            result_warn "SELinux: Enforcing — keepalived 실행 시 AVC 거부 발생 여부 모니터링 필요"
            result_info "문제 발생 시: audit2allow -a | audit2allow -M keepalived_custom"
            ;;
        *)
            result_info "SELinux 상태 확인 불가: ${selinux_status}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 8. 시스템 리소스 확인
# ------------------------------------------------------------------------------
check_resources() {
    print_section "8. 시스템 리소스 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 8. 시스템 리소스 확인 ]" >> "$REPORT_FILE"

    local mem_free_mb mem_total_mb
    mem_free_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    mem_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    if [ "$mem_free_mb" -ge 512 ]; then
        result_pass "가용 메모리: ${mem_free_mb}MB / 전체: ${mem_total_mb}MB"
    elif [ "$mem_free_mb" -ge 64 ]; then
        result_warn "가용 메모리 부족: ${mem_free_mb}MB / 전체: ${mem_total_mb}MB (512MB 이상 권장)"
    else
        result_fail "가용 메모리 심각: ${mem_free_mb}MB / 전체: ${mem_total_mb}MB"
    fi

    local log_disk_mb root_disk_mb
    log_disk_mb=$(df /var/log --output=avail -m 2>/dev/null | tail -1 | tr -d ' ')
    root_disk_mb=$(df / --output=avail -m 2>/dev/null | tail -1 | tr -d ' ')

    if [ "$log_disk_mb" -ge 500 ]; then
        result_pass "/var/log 가용 디스크: ${log_disk_mb}MB"
    elif [ "$log_disk_mb" -ge 100 ]; then
        result_warn "/var/log 가용 디스크 부족: ${log_disk_mb}MB (500MB 이상 권장)"
    else
        result_fail "/var/log 가용 디스크 심각: ${log_disk_mb}MB"
    fi

    if [ "$root_disk_mb" -ge 100 ]; then
        result_pass "/ 가용 디스크: ${root_disk_mb}MB (백업 경로 포함)"
    else
        result_warn "/ 가용 디스크 부족: ${root_disk_mb}MB (백업 디렉토리 생성 공간 필요)"
    fi
}

# ------------------------------------------------------------------------------
# 9. keepalived 서비스 상태 확인 (기설치 시)
# ------------------------------------------------------------------------------
check_keepalived_service() {
    print_section "9. keepalived 서비스 상태 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 9. keepalived 서비스 상태 확인 ]" >> "$REPORT_FILE"

    if ! rpm -q keepalived &>/dev/null; then
        result_info "keepalived 미설치 — 아래 패키지 설치 단계에서 설치됩니다"
        return
    fi

    if systemctl is-enabled keepalived &>/dev/null; then
        result_info "keepalived 자동 시작: 활성화됨 (enabled)"
    else
        result_info "keepalived 자동 시작: 비활성화됨 (disabled)"
    fi

    if systemctl is-active keepalived &>/dev/null; then
        result_warn "keepalived 현재 실행 중 — 설정 변경 시 서비스 재시작 필요"
    else
        result_pass "keepalived 현재 중지 상태"
    fi

    if [ -f /etc/keepalived/keepalived.conf ]; then
        result_warn "기존 keepalived.conf 존재 — install.sh 실행 시 자동 백업됨"
    else
        result_pass "기존 keepalived.conf 없음 — 신규 설치 가능"
    fi
}

# ------------------------------------------------------------------------------
# 10. install_package 폴더 RPM 파일 확인
# ------------------------------------------------------------------------------
check_install_package() {
    print_section "10. install_package RPM 파일 확인"
    echo "" >> "$REPORT_FILE"
    echo "[ 10. install_package RPM 파일 확인 ]" >> "$REPORT_FILE"

    if [ ! -d "$PKG_DIR" ]; then
        result_fail "install_package/ 폴더 없음 — download_keepalived_rpms.sh 로 RPM 다운로드 후 재실행하세요"
        return
    fi

    local rpm_count
    rpm_count=$(ls -1 "${PKG_DIR}"/*.rpm 2>/dev/null | wc -l)

    if [ "$rpm_count" -eq 0 ]; then
        result_fail "install_package/ 폴더에 RPM 파일 없음 — download_keepalived_rpms.sh 로 다운로드하세요"
        return
    fi

    result_pass "install_package/ RPM 파일: ${rpm_count}개 존재"

    local required_rpms=("keepalived" "net-snmp-libs" "net-snmp-agent-libs")
    for pkg in "${required_rpms[@]}"; do
        if ls "${PKG_DIR}/${pkg}-"*.rpm &>/dev/null 2>&1; then
            local rpm_file
            rpm_file=$(basename "$(ls "${PKG_DIR}/${pkg}-"*.rpm 2>/dev/null | grep "x86_64\|noarch" | head -1)")
            result_pass "  RPM 존재: ${rpm_file}"
        else
            result_fail "  RPM 없음: ${pkg}-*.rpm — download_keepalived_rpms.sh 로 다운로드 필요"
        fi
    done
}

# ------------------------------------------------------------------------------
# 패키지 설치 함수
# ------------------------------------------------------------------------------
install_packages() {
    print_section "패키지 설치"
    echo "" >> "$REPORT_FILE"
    echo "[ 패키지 설치 ]" >> "$REPORT_FILE"

    # install_package 폴더 유효성 재확인
    if [ ! -d "$PKG_DIR" ] || [ "$(ls -1 "${PKG_DIR}"/*.rpm 2>/dev/null | wc -l)" -eq 0 ]; then
        echo -e "  ${RED}[ERROR]${NC} install_package/ 폴더에 RPM 파일이 없어 설치를 진행할 수 없습니다."
        echo "  [ERROR] install_package/ RPM 없음 — 설치 중단" >> "$REPORT_FILE"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}  다음 패키지가 미설치 상태입니다:${NC}"
    for pkg in "${MISSING_PKGS[@]}"; do
        echo -e "    - ${pkg}"
    done
    echo ""
    echo -e "  install_package/ 폴더의 RPM으로 전체 설치를 진행합니다."
    echo -e "  ${BOLD}(install_package/ 내 모든 RPM이 일괄 설치됩니다)${NC}"
    echo ""
    read -r -p "  설치를 진행하시겠습니까? [y/N] " confirm
    echo ""

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "  ${YELLOW}[SKIP]${NC} 사용자가 설치를 취소했습니다."
        echo "  [SKIP] 사용자 취소 — 패키지 설치 건너뜀" >> "$REPORT_FILE"
        return 0
    fi

    echo -e "  ${BLUE}[INFO]${NC} RPM 설치 시작..."
    echo "  [INFO] RPM 설치 시작: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"

    local install_log="${SCRIPT_DIR}/install_log_${TIMESTAMP}.txt"
    if rpm -Uvh --replacepkgs "${PKG_DIR}"/*.rpm > "$install_log" 2>&1; then
        echo -e "  ${GREEN}[PASS]${NC} RPM 설치 완료"
        echo "  [PASS] RPM 설치 완료" >> "$REPORT_FILE"
    else
        # rpm -Uvh는 이미 설치된 패키지에서 경고를 내지만 실제 필요한 패키지가 설치되면 성공
        echo -e "  ${YELLOW}[WARN]${NC} 일부 패키지에서 경고 발생 (이미 설치된 패키지 포함 가능) — 설치 로그 확인: ${install_log}"
        echo "  [WARN] 설치 중 경고 발생 — 로그: ${install_log}" >> "$REPORT_FILE"
    fi

    echo ""
    echo -e "  ${CYAN}${BOLD}[ 설치 후 패키지 상태 재확인 ]${NC}"
    echo "" >> "$REPORT_FILE"
    echo "  [ 설치 후 패키지 상태 재확인 ]" >> "$REPORT_FILE"

    local verify_pkgs=("keepalived" "net-snmp-libs" "net-snmp-agent-libs" "mariadb")
    local install_ok=true
    for pkg in "${verify_pkgs[@]}"; do
        if rpm -q "$pkg" &>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} ${pkg}: $(rpm -q "$pkg" | head -1)"
            echo "  [PASS] ${pkg}: $(rpm -q "$pkg" | head -1)" >> "$REPORT_FILE"
        else
            # mariadb는 선택사항이므로 WARN 처리
            if [[ "$pkg" == "mariadb" ]]; then
                echo -e "  ${YELLOW}[WARN]${NC} ${pkg}: 미설치 (DB 복제 체크 사용 시 수동 설치 필요)"
                echo "  [WARN] ${pkg}: 미설치" >> "$REPORT_FILE"
            else
                echo -e "  ${RED}[FAIL]${NC} ${pkg}: 설치 실패 — 설치 로그를 확인하세요: ${install_log}"
                echo "  [FAIL] ${pkg}: 설치 실패" >> "$REPORT_FILE"
                install_ok=false
            fi
        fi
    done

    echo ""
    if $install_ok; then
        echo -e "  ${GREEN}${BOLD}필수 패키지 설치 완료. install.sh 실행으로 서비스 구성을 진행하세요.${NC}"
        echo "  [결과] 필수 패키지 설치 완료" >> "$REPORT_FILE"
    else
        echo -e "  ${RED}${BOLD}일부 필수 패키지 설치에 실패했습니다. 설치 로그를 확인하세요.${NC}"
        echo -e "  로그 파일: ${install_log}"
        echo "  [결과] 일부 패키지 설치 실패" >> "$REPORT_FILE"
    fi
}

# ------------------------------------------------------------------------------
# 최종 결과 요약
# ------------------------------------------------------------------------------
print_summary() {
    local total=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))

    echo ""
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "${BOLD}  환경 점검 결과 요약${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "  총 점검 항목: ${total}개"
    echo -e "  ${GREEN}[PASS]${NC} ${PASS_COUNT}개"
    echo -e "  ${YELLOW}[WARN]${NC} ${WARN_COUNT}개"
    echo -e "  ${RED}[FAIL]${NC} ${FAIL_COUNT}개"
    echo ""

    if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}판정: 설치 진행 가능 (모든 항목 정상)${NC}"
    elif [ "$FAIL_COUNT" -eq 0 ]; then
        echo -e "  ${YELLOW}${BOLD}판정: 조건부 설치 가능 (WARN 항목 확인 후 진행)${NC}"
    else
        echo -e "  ${RED}${BOLD}판정: FAIL 항목 해결 후 재점검 필요${NC}"
    fi

    echo ""
    echo -e "  보고서 저장: ${REPORT_FILE}"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""

    cat >> "$REPORT_FILE" <<EOF

======================================================================
  환경 점검 결과 요약
======================================================================
  점검 완료: $(date '+%Y-%m-%d %H:%M:%S')
  총 점검:   ${total}개
  PASS:      ${PASS_COUNT}개
  WARN:      ${WARN_COUNT}개
  FAIL:      ${FAIL_COUNT}개
EOF
    if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
        echo "  판정: 설치 진행 가능 (모든 항목 정상)" >> "$REPORT_FILE"
    elif [ "$FAIL_COUNT" -eq 0 ]; then
        echo "  판정: 조건부 설치 가능" >> "$REPORT_FILE"
    else
        echo "  판정: FAIL 항목 해결 필요" >> "$REPORT_FILE"
    fi
    echo "======================================================================" >> "$REPORT_FILE"
}

# ------------------------------------------------------------------------------
# 메인
# ------------------------------------------------------------------------------
main() {
    init_report
    print_banner

    # 환경 점검
    check_root
    check_os
    check_commands
    check_packages
    check_network
    check_firewall
    check_selinux
    check_resources
    check_keepalived_service
    check_install_package

    # 점검 결과 요약 출력
    print_summary

    # 미설치 패키지가 있으면 설치 단계 진행
    if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
        install_packages
    else
        echo -e "  ${GREEN}모든 필수 패키지가 이미 설치되어 있습니다.${NC}"
        echo ""
    fi

    # 종료 코드: FAIL 있으면 1, WARN만 있으면 2, 정상이면 0
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    elif [ "$WARN_COUNT" -gt 0 ]; then
        exit 2
    else
        exit 0
    fi
}

main "$@"
