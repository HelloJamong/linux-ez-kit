#!/bin/bash
#
# CRLF 감지 및 자동 변환 후 재실행
if file "$0" 2>/dev/null | grep -q CRLF; then
    echo "[INFO] CRLF 줄바꿈 감지됨 - LF로 변환 후 재실행합니다."
    if command -v dos2unix &>/dev/null; then
        dos2unix "$0"
    else
        sed -i 's/\r//' "$0"
    fi
    exec bash "$0" "$@"
fi
#
# 커널 보안 패치 자동화 스크립트 v1.0
# Rocky Linux / RHEL 9.0 ~ 9.x 전 버전 지원
#
# 사용법:
#   1. 스크립트 상단의 CVE_LIST 변수에 점검할 CVE 코드 입력
#   2. sudo ./patch_script.sh 실행
#   3. 패치 완료 후 안내에 따라 수동 재부팅
#

set -e

# ==================== 설정 (여기를 수정하세요) ====================
CVE_LIST="CVE-2026-23111"

# ==================== 경로 설정 ====================
SCRIPT_DIR="/tmp/kernel_patch"
KERNEL_DIR="$SCRIPT_DIR/kernel"
BACKUP_DIR="$SCRIPT_DIR/backup/backup_$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/patch_$(date +%Y%m%d_%H%M%S).log"
RESULT_FILE="$SCRIPT_DIR/result_patch_$(date +%Y%m%d_%H%M%S).log"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 함수 정의 ====================

log()         { echo -e "$1" | tee -a "$LOG_FILE"; }
log_success() { log "${GREEN}✅ $1${NC}"; }
log_error()   { log "${RED}❌ $1${NC}"; }
log_warning() { log "${YELLOW}⚠️  $1${NC}"; }
log_info()    { log "${BLUE}ℹ️  $1${NC}"; }

ask_yes_no() {
    local question="$1"
    local response
    while true; do
        echo -ne "${YELLOW}$question (y/n): ${NC}"
        read -r response
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "y 또는 n을 입력하세요.";;
        esac
    done
}

# RPM 파일에서 새 커널 버전 문자열 추출 (예: 5.14.0-687.15.1.el9_8.x86_64)
get_new_kernel_version() {
    local rpm_file
    rpm_file=$(find "$KERNEL_DIR" -maxdepth 1 -name "kernel-[0-9]*.rpm" -type f | head -1)
    [ -n "$rpm_file" ] && rpm -qp --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' "$rpm_file" 2>/dev/null
}

detect_os_version() {
    log "\n=== OS 버전 감지 ==="

    if [ -f /etc/redhat-release ]; then
        OS_RELEASE=$(cat /etc/redhat-release)
        log_info "OS: $OS_RELEASE"

        if echo "$OS_RELEASE" | grep -qE "Rocky Linux release 9\.[0-9]"; then
            OS_MAJOR=$(echo "$OS_RELEASE" | grep -oP 'release \K[0-9]+' | head -1)
            OS_MINOR=$(echo "$OS_RELEASE" | grep -oP 'release [0-9]+\.\K[0-9]+' | head -1)
            OS_VERSION="${OS_MAJOR}.${OS_MINOR}"
            log_success "Rocky Linux ${OS_VERSION} 감지"
        elif echo "$OS_RELEASE" | grep -qE "Red Hat Enterprise Linux release 9\.[0-9]"; then
            OS_MAJOR=$(echo "$OS_RELEASE" | grep -oP 'release \K[0-9]+' | head -1)
            OS_MINOR=$(echo "$OS_RELEASE" | grep -oP 'release [0-9]+\.\K[0-9]+' | head -1)
            OS_VERSION="${OS_MAJOR}.${OS_MINOR}"
            log_success "RHEL ${OS_VERSION} 감지"
        else
            log_warning "Rocky Linux 또는 RHEL 9.x가 아닙니다."
            OS_VERSION="unknown"
        fi
    else
        log_error "/etc/redhat-release 파일을 찾을 수 없습니다."
        OS_VERSION="unknown"
    fi

    log_info "감지된 버전: ${OS_VERSION}"
}

check_kernel_packages() {
    log "\n=== 커널 패키지 확인 ==="

    local missing=false
    for pattern in "kernel-[0-9]" "kernel-core-[0-9]" "kernel-modules-[0-9]" "kernel-modules-core-[0-9]"; do
        local found
        found=$(find "$KERNEL_DIR" -maxdepth 1 -name "${pattern}*.rpm" -type f | head -1)
        if [ -z "$found" ]; then
            log_error "필수 패키지 없음: ${pattern}*.rpm"
            missing=true
        else
            log_info "발견: $(basename "$found")"
        fi
    done

    [ "$missing" = true ] && return 1
    return 0
}

verify_cve_in_packages() {
    log "\n=== CVE 패치 사전 확인 ==="

    local kernel_rpm
    kernel_rpm=$(find "$KERNEL_DIR" -maxdepth 1 -name "kernel-[0-9]*.rpm" -type f | head -1)

    if [ -z "$kernel_rpm" ]; then
        log_warning "커널 패키지를 찾을 수 없어 CVE 확인을 건너뜁니다."
        return 0
    fi

    local all_found=true
    for cve in $CVE_LIST; do
        log_info "확인 중: $cve"
        if rpm -qp --changelog "$kernel_rpm" 2>/dev/null | grep -q "$cve"; then
            log_success "  ✓ $cve 패치 포함됨"
        else
            log_warning "  ✗ $cve 패치를 찾을 수 없음"
            all_found=false
        fi
    done

    if [ "$all_found" = false ]; then
        log_warning "\n일부 CVE 패치가 패키지에서 확인되지 않았습니다."
        if ! ask_yes_no "그래도 계속하시겠습니까?"; then
            log "패치를 중단합니다."
            exit 0
        fi
    fi
}

backup_kernel() {
    log "\n=== 커널 정보 백업 ==="
    mkdir -p "$BACKUP_DIR"

    # 현재 실행 중 커널 저장
    local current_kernel
    current_kernel=$(uname -r)
    echo "$current_kernel" > "$BACKUP_DIR/current_kernel.txt"
    log_info "현재 실행 커널: $current_kernel"

    # GRUB 기본 커널 저장
    grubby --default-kernel > "$BACKUP_DIR/grub_default.txt" 2>/dev/null || true
    log_info "GRUB 기본 커널: $(cat "$BACKUP_DIR/grub_default.txt" 2>/dev/null || echo '확인 불가')"

    # 설치된 커널 목록 저장
    rpm -q kernel --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
        > "$BACKUP_DIR/installed_kernels.txt" 2>/dev/null || true

    # grub.cfg 백업
    [ -f /boot/grub2/grub.cfg ] && cp /boot/grub2/grub.cfg "$BACKUP_DIR/grub.cfg.bak"

    # 롤백 안내 파일 생성
    cat > "$BACKUP_DIR/rollback_guide.txt" << EOF
=== 커널 롤백 방법 ===

패치 전 실행 커널: $current_kernel

롤백 명령어 (root 권한):
  grubby --set-default /boot/vmlinuz-${current_kernel}
  reboot

또는 서버 재부팅 시 GRUB 메뉴에서 이전 커널을 직접 선택할 수 있습니다.
EOF

    log_success "백업 완료: $BACKUP_DIR"
}

install_kernel() {
    log "\n=== 커널 설치 중... ==="
    log_info "설치 방식: rpm -ivh (기존 커널 유지, 새 커널 추가)"

    cd "$KERNEL_DIR"

    # core → modules-core → modules → kernel 순서로 의존성 해결
    rpm -ivh \
        kernel-core-[0-9]*.rpm \
        kernel-modules-core-[0-9]*.rpm \
        kernel-modules-[0-9]*.rpm \
        kernel-[0-9]*.rpm \
        2>&1 | tee -a "$LOG_FILE"

    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        log_success "커널 설치 완료"
        return 0
    else
        log_error "커널 설치 실패"
        return 1
    fi
}

set_default_kernel() {
    log "\n=== GRUB 기본 커널 설정 ==="

    local new_ver
    new_ver=$(get_new_kernel_version)
    local new_vmlinuz="/boot/vmlinuz-${new_ver}"

    if [ ! -f "$new_vmlinuz" ]; then
        log_error "새 커널 파일을 찾을 수 없습니다: $new_vmlinuz"
        return 1
    fi

    grubby --set-default="$new_vmlinuz" 2>&1 | tee -a "$LOG_FILE"

    local default_kernel
    default_kernel=$(grubby --default-kernel 2>/dev/null)

    if echo "$default_kernel" | grep -q "$new_ver"; then
        log_success "GRUB 기본 커널 설정 완료: $default_kernel"
    else
        log_error "GRUB 기본 커널 설정 실패 (현재 기본: $default_kernel)"
        return 1
    fi
}

verify_install() {
    log "\n=== 설치 검증 ==="

    local new_ver
    new_ver=$(get_new_kernel_version)

    # RPM 설치 확인
    if rpm -q "kernel-${new_ver}" &>/dev/null; then
        log_success "커널 RPM 설치 확인: kernel-${new_ver}"
    else
        log_error "커널 RPM 설치 확인 실패"
        return 1
    fi

    # CVE 패치 changelog 확인
    log "\n[CVE 패치 확인]"
    for cve in $CVE_LIST; do
        log_info "확인 중: $cve"
        if rpm -q --changelog "kernel-${new_ver}" 2>/dev/null | grep -q "$cve"; then
            log_success "  ✓ $cve 패치 확인됨"
        else
            log_warning "  ✗ $cve changelog 미기재 (버전 업그레이드로 조치됨)"
        fi
    done

    # GRUB 기본 설정 확인
    log_info "GRUB 기본 커널: $(grubby --default-kernel 2>/dev/null || echo '확인 불가')"
}

reboot_notice() {
    local new_ver
    new_ver=$(get_new_kernel_version)
    local current_kernel
    current_kernel=$(uname -r)

    log "\n"
    log "╔══════════════════════════════════════════╗"
    log "║         ⚠️  재부팅이 필요합니다           ║"
    log "╚══════════════════════════════════════════╝"
    log ""
    log_info "새 커널이 설치되었으나 재부팅 전까지 현재 커널로 동작합니다."
    log_info "CVE 취약점 조치를 완료하려면 수동으로 재부팅해야 합니다."
    log ""
    log "  현재 실행 커널 : ${YELLOW}${current_kernel}${NC}"
    log "  패치된 커널    : ${GREEN}${new_ver}${NC}"
    log ""
    log "【 재부팅 명령어 】"
    log "  ${GREEN}reboot${NC}"
    log ""
    log "【 재부팅 후 커널 확인 】"
    log "  ${GREEN}uname -r${NC}  →  예상: ${new_ver}"
    log ""
    log "【 롤백이 필요한 경우 (재부팅 전) 】"
    log "  ${YELLOW}grubby --set-default /boot/vmlinuz-${current_kernel}${NC}"
    log "  ${YELLOW}reboot${NC}"
    log ""
    log "롤백 상세 안내: $BACKUP_DIR/rollback_guide.txt"
    log "══════════════════════════════════════════════"
}

generate_result_file() {
    log "\n=== 결과 파일 생성 중... ==="

    local new_ver
    new_ver=$(get_new_kernel_version)
    local current_kernel
    current_kernel=$(cat "$BACKUP_DIR/current_kernel.txt" 2>/dev/null || uname -r)

    cat > "$RESULT_FILE" << EOF
========================================
커널 보안 패치 결과 보고서
========================================

패치 완료 시간 : $(date)
호스트명       : $(hostname)

========================================
시스템 정보
========================================

OS 버전  : $(cat /etc/redhat-release 2>/dev/null || echo "확인 불가")
OS 버전  : ${OS_VERSION}
아키텍처 : $(uname -m)

========================================
커널 버전 정보
========================================

[패치 전]
실행 중 커널 : ${current_kernel}

[패치 후]
설치된 커널  : ${new_ver}
GRUB 기본    : $(grubby --default-kernel 2>/dev/null || echo "확인 불가")

⚠️  재부팅 후 새 커널이 적용됩니다.

========================================
CVE 패치 상태
========================================

EOF

    for cve in $CVE_LIST; do
        echo "[$cve]" >> "$RESULT_FILE"
        if rpm -q --changelog "kernel-${new_ver}" 2>/dev/null | grep -q "$cve"; then
            echo "상태: ✅ changelog 확인됨" >> "$RESULT_FILE"
        else
            echo "상태: ⚠️  changelog 미기재 (버전 업그레이드로 조치됨)" >> "$RESULT_FILE"
        fi
        echo "" >> "$RESULT_FILE"
    done

    cat >> "$RESULT_FILE" << EOF
========================================
재부팅 안내
========================================

CVE 조치 완료를 위해 아래 명령어로 수동 재부팅하세요:

  reboot

재부팅 후 적용 커널 확인:
  uname -r  →  예상: ${new_ver}

롤백 방법:
  grubby --set-default /boot/vmlinuz-${current_kernel}
  reboot

========================================
백업 정보
========================================

백업 위치 : $BACKUP_DIR
로그 파일 : $LOG_FILE

========================================
EOF

    log_success "결과 파일 생성 완료: $RESULT_FILE"
    cat "$RESULT_FILE" | tee -a "$LOG_FILE"
}

# ==================== 메인 로직 ====================

main() {
    mkdir -p "$BACKUP_DIR" "$LOG_DIR"

    log "=========================================="
    log "커널 보안 패치 스크립트 v1.0"
    log "Rocky Linux / RHEL 9.0 ~ 9.x 전체 지원"
    log "=========================================="
    log "시작 시간: $(date)"
    log "호스트   : $(hostname)"

    detect_os_version

    log "\n=========================================="
    log "점검 대상 CVE:"
    for cve in $CVE_LIST; do
        log "  - $cve"
    done
    log "=========================================="

    # root 권한 확인
    if [ "$EUID" -ne 0 ]; then
        log_error "이 스크립트는 root 권한이 필요합니다."
        exit 1
    fi

    # 패키지 디렉토리 확인
    if [ ! -d "$KERNEL_DIR" ]; then
        log_error "커널 패키지 디렉토리를 찾을 수 없습니다: $KERNEL_DIR"
        log "필요 위치: $KERNEL_DIR"
        exit 1
    fi

    # 패키지 파일 확인
    if ! check_kernel_packages; then
        exit 1
    fi

    # CVE 사전 확인
    verify_cve_in_packages

    log_warning "\n⚠️  패치 완료 후 수동 재부팅이 필요합니다."
    log_warning "재부팅 전까지 현재 커널로 계속 동작합니다."
    echo ""

    # 커널 정보 백업
    if ! backup_kernel; then
        log_error "백업 실패"
        exit 1
    fi

    # 패치 진행 확인
    if ! ask_yes_no "\n커널 패치를 진행하시겠습니까?"; then
        log "패치를 중단합니다."
        exit 0
    fi

    log "\n########## 커널 패치 시작 ##########"

    # 설치
    if ! install_kernel; then
        log_error "설치 실패 — 기존 커널은 유지됩니다."
        exit 1
    fi

    # GRUB 기본 커널 설정
    if ! set_default_kernel; then
        log_error "GRUB 설정 실패"
        log_warning "rpm -ivh로 커널은 설치됐습니다. 수동으로 grubby 설정이 필요합니다."
        exit 1
    fi

    # 설치 검증
    verify_install

    log_success "\n########## 커널 패치 완료 ##########"

    # 결과 파일 생성
    generate_result_file

    # 재부팅 안내 (스크립트 마지막 출력)
    reboot_notice

    log "\n=========================================="
    log "종료 시간: $(date)"
    log "=========================================="
}

main "$@"
