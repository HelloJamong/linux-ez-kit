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
# OpenSSL/OpenSSH 보안 패치 자동화 스크립트 v2.2
# Rocky Linux / RHEL 9.0 ~ 9.x 전 버전 지원
# 
# 사용법: 
#   1. 스크립트 상단의 CVE_LIST 변수에 점검할 CVE 코드 입력
#   2. ./patch.sh 실행
#

set -e  # 오류 발생 시 스크립트 중단

# ==================== 설정 (여기를 수정하세요) ====================
# 점검할 CVE 코드 (공백으로 구분)
CVE_LIST="CVE-2026-34181 CVE-2026-34182 CVE-2026-34183"

# ==================== 경로 설정 ====================
SCRIPT_DIR="/tmp/ssl_ssh_patch"
OPENSSH_DIR="$SCRIPT_DIR/openssh"
OPENSSL_DIR="$SCRIPT_DIR/openssl"
BACKUP_DIR="$SCRIPT_DIR/backup/backup_$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/patch_$(date +%Y%m%d_%H%M%S).log"
RESULT_FILE="$SCRIPT_DIR/result_patch_$(date +%Y%m%d_%H%M%S).log"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==================== 함수 정의 ====================

# 로그 함수
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# 성공 메시지
log_success() {
    log "${GREEN}✅ $1${NC}"
}

# 오류 메시지
log_error() {
    log "${RED}❌ $1${NC}"
}

# 경고 메시지
log_warning() {
    log "${YELLOW}⚠️  $1${NC}"
}

# 정보 메시지
log_info() {
    log "${BLUE}ℹ️  $1${NC}"
}

# 질문 함수
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

# OS 버전 감지
detect_os_version() {
    log "\n=== OS 버전 감지 ==="
    
    # /etc/redhat-release에서 버전 추출
    if [ -f /etc/redhat-release ]; then
        OS_RELEASE=$(cat /etc/redhat-release)
        log_info "OS: $OS_RELEASE"
        
        # Rocky Linux 9.x 버전 추출
        if echo "$OS_RELEASE" | grep -qE "Rocky Linux release 9\.[0-9]"; then
            OS_MAJOR=$(echo "$OS_RELEASE" | grep -oP 'release \K[0-9]+' | head -1)
            OS_MINOR=$(echo "$OS_RELEASE" | grep -oP 'release [0-9]+\.\K[0-9]+' | head -1)
            OS_VERSION="${OS_MAJOR}.${OS_MINOR}"
            log_success "Rocky Linux ${OS_VERSION} 감지"
        # RHEL 9.x 버전 추출
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
    
    # /etc/os-release에서도 확인
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "ID: $ID"
        log_info "VERSION_ID: $VERSION_ID"
    fi
    
    log_info "감지된 버전: ${OS_VERSION}"
}

# FIPS provider 타입 확인
detect_fips_provider() {
    log "\n=== FIPS Provider 확인 ==="
    
    # fips-provider-next 확인 (9.5 이상)
    if rpm -q fips-provider-next &>/dev/null; then
        FIPS_PROVIDER_TYPE="next"
        log_info "fips-provider-next 사용 중 (Rocky 9.5+)"
        log_warning "openssl-fips-provider는 설치하지 않습니다."
        return 0
    fi
    
    # openssl-fips-provider 확인 (9.4 이하)
    if rpm -q openssl-fips-provider &>/dev/null; then
        FIPS_PROVIDER_TYPE="legacy"
        log_info "openssl-fips-provider 사용 중 (Rocky 9.0-9.4)"
        return 0
    fi
    
    # 둘 다 없는 경우
    FIPS_PROVIDER_TYPE="none"
    log_info "FIPS provider 미설치"
    return 0
}

# RPM 파일 자동 검색
find_rpm_files() {
    local dir="$1"
    local pattern="$2"
    
    find "$dir" -maxdepth 1 -name "${pattern}*.rpm" -type f 2>/dev/null
}

# OpenSSH RPM 파일 확인
check_openssh_packages() {
    log "\n=== OpenSSH 패키지 확인 ==="
    
    local openssh_rpm=$(find_rpm_files "$OPENSSH_DIR" "openssh-[0-9]")
    local openssh_server_rpm=$(find_rpm_files "$OPENSSH_DIR" "openssh-server")
    local openssh_clients_rpm=$(find_rpm_files "$OPENSSH_DIR" "openssh-clients")
    
    if [ -z "$openssh_rpm" ] || [ -z "$openssh_server_rpm" ] || [ -z "$openssh_clients_rpm" ]; then
        log_error "필수 OpenSSH 패키지를 찾을 수 없습니다."
        log "필요한 파일: openssh, openssh-server, openssh-clients"
        log "위치: $OPENSSH_DIR"
        return 1
    fi
    
    log_info "발견된 OpenSSH 패키지:"
    for rpm in $openssh_rpm $openssh_server_rpm $openssh_clients_rpm; do
        log "  - $(basename $rpm)"
    done
    
    return 0
}

# OpenSSL RPM 파일 확인
check_openssl_packages() {
    log "\n=== OpenSSL 패키지 확인 ==="
    
    local openssl_rpm=$(find_rpm_files "$OPENSSL_DIR" "openssl-[0-9]")
    local openssl_libs_rpm=$(find_rpm_files "$OPENSSL_DIR" "openssl-libs")
    
    if [ -z "$openssl_rpm" ] || [ -z "$openssl_libs_rpm" ]; then
        log_error "필수 OpenSSL 패키지를 찾을 수 없습니다."
        log "필요한 파일: openssl, openssl-libs"
        log "위치: $OPENSSL_DIR"
        return 1
    fi
    
    log_info "발견된 OpenSSL 패키지:"
    for rpm in $(find_rpm_files "$OPENSSL_DIR" "openssl"); do
        log "  - $(basename $rpm)"
    done
    
    # FIPS provider 정보 표시
    detect_fips_provider
    
    # openssl-fips-provider 파일 존재 여부
    local fips_provider_rpm=$(find_rpm_files "$OPENSSL_DIR" "openssl-fips-provider")
    
    if [ "$FIPS_PROVIDER_TYPE" = "next" ]; then
        if [ -n "$fips_provider_rpm" ]; then
            log_warning "openssl-fips-provider 파일이 있지만 설치하지 않습니다."
            log_warning "현재 시스템은 fips-provider-next를 사용합니다."
        fi
    elif [ "$FIPS_PROVIDER_TYPE" = "legacy" ] || [ "$FIPS_PROVIDER_TYPE" = "none" ]; then
        if [ -n "$fips_provider_rpm" ]; then
            log_info "openssl-fips-provider 파일 발견 - 설치 예정"
        else
            log_warning "openssl-fips-provider 파일 없음 - 선택적 패키지"
        fi
    fi
    
    return 0
}

# CVE 패치 확인 (설치 전)
check_cve_in_package() {
    local package_file="$1"
    local cve_code="$2"
    
    if rpm -qp --changelog "$package_file" 2>/dev/null | grep -q "$cve_code"; then
        return 0
    else
        return 1
    fi
}

# 모든 CVE 패치 확인 (패키지 파일)
verify_cve_in_packages() {
    log "\n=== CVE 패치 사전 확인 ==="
    
    local openssl_rpm=$(find_rpm_files "$OPENSSL_DIR" "openssl-[0-9]" | head -1)
    
    if [ -z "$openssl_rpm" ]; then
        log_warning "OpenSSL 패키지를 찾을 수 없어 CVE 확인을 건너뜁니다."
        return 0
    fi
    
    local all_found=true
    
    for cve in $CVE_LIST; do
        log_info "확인 중: $cve"
        if check_cve_in_package "$openssl_rpm" "$cve"; then
            log_success "  ✓ $cve 패치 포함됨"
        else
            log_warning "  ✗ $cve 패치를 찾을 수 없음"
            all_found=false
        fi
    done
    
    if [ "$all_found" = false ]; then
        log_warning "\n일부 CVE 패치가 패키지에서 확인되지 않았습니다."
        log_warning "패키지가 해당 CVE가 공개되기 전 버전일 수 있습니다."
        if ! ask_yes_no "그래도 계속하시겠습니까?"; then
            log "패치를 중단합니다."
            exit 0
        fi
    fi
    
    return 0
}

# /usr/local 확인 및 제거
check_and_remove_local_ssh() {
    log "\n=== /usr/local 수동 설치 확인 ==="
    
    if [ -f /usr/local/bin/ssh ] || [ -f /usr/local/sbin/sshd ]; then
        log_warning "/usr/local에 수동 설치된 SSH 발견"
        
        if ask_yes_no "백업 후 제거하시겠습니까?"; then
            mkdir -p "$BACKUP_DIR/local_ssh"
            
            mv /usr/local/bin/ssh* "$BACKUP_DIR/local_ssh/" 2>/dev/null || true
            mv /usr/local/sbin/sshd "$BACKUP_DIR/local_ssh/" 2>/dev/null || true
            
            hash -r
            log_success "/usr/local SSH 제거 완료"
            log "백업 위치: $BACKUP_DIR/local_ssh"
            log_warning "현재 셸의 ssh 명령 캐시가 남아있을 수 있습니다."
            log_warning "패치 완료 후 SSH를 재연결하거나 'hash -r' 명령을 실행하세요."
        else
            log_error "패치를 계속하려면 /usr/local SSH를 제거해야 합니다."
            exit 1
        fi
    else
        log_success "/usr/local에 수동 설치된 SSH 없음"
    fi
}

# OpenSSH 백업
backup_openssh() {
    log "\n=== OpenSSH 백업 중... ==="
    
    mkdir -p "$BACKUP_DIR/openssh"
    
    # 패키지 정보 백업
    rpm -qi openssh > "$BACKUP_DIR/openssh/package_info.txt" 2>&1 || true
    rpm -qi openssh-server >> "$BACKUP_DIR/openssh/package_info.txt" 2>&1 || true
    rpm -qi openssh-clients >> "$BACKUP_DIR/openssh/package_info.txt" 2>&1 || true
    
    # Changelog 백업
    rpm -q --changelog openssh-server > "$BACKUP_DIR/openssh/changelog.txt" 2>&1 || true
    
    # 현재 버전 저장
    rpm -q openssh openssh-server openssh-clients > "$BACKUP_DIR/openssh/versions.txt" 2>&1 || true
    
    # SSH 설정 백업
    cp -a /etc/ssh "$BACKUP_DIR/openssh/" 2>&1 | tee -a "$LOG_FILE"
    
    log_success "OpenSSH 백업 완료: $BACKUP_DIR/openssh"
}

# OpenSSL 백업
backup_openssl() {
    log "\n=== OpenSSL 백업 중... ==="
    
    mkdir -p "$BACKUP_DIR/openssl"
    
    # 패키지 정보 백업
    rpm -qi openssl > "$BACKUP_DIR/openssl/package_info.txt" 2>&1 || true
    rpm -qi openssl-libs >> "$BACKUP_DIR/openssl/package_info.txt" 2>&1 || true
    
    # Changelog 백업
    rpm -q --changelog openssl > "$BACKUP_DIR/openssl/changelog.txt" 2>&1 || true
    
    # 현재 버전 저장
    rpm -q openssl openssl-libs openssl-devel > "$BACKUP_DIR/openssl/versions.txt" 2>&1 || true
    
    # FIPS provider 정보 저장
    echo "FIPS Provider Type: $FIPS_PROVIDER_TYPE" > "$BACKUP_DIR/openssl/fips_info.txt"
    rpm -q fips-provider-next >> "$BACKUP_DIR/openssl/fips_info.txt" 2>&1 || echo "fips-provider-next: not installed" >> "$BACKUP_DIR/openssl/fips_info.txt"
    rpm -q openssl-fips-provider >> "$BACKUP_DIR/openssl/fips_info.txt" 2>&1 || echo "openssl-fips-provider: not installed" >> "$BACKUP_DIR/openssl/fips_info.txt"
    
    # 라이브러리 백업
    cp -a /usr/lib64/libssl.so* "$BACKUP_DIR/openssl/" 2>&1 | tee -a "$LOG_FILE"
    cp -a /usr/lib64/libcrypto.so* "$BACKUP_DIR/openssl/" 2>&1 | tee -a "$LOG_FILE"
    
    log_success "OpenSSL 백업 완료: $BACKUP_DIR/openssl"
}

# OpenSSH 설치
install_openssh() {
    log "\n=== OpenSSH 설치 중... ==="
    
    cd "$OPENSSH_DIR"
    
    # 패키지 파일 찾기
    local rpm_files=$(find . -maxdepth 1 -name "openssh*.rpm" -type f)
    
    if [ -z "$rpm_files" ]; then
        log_error "OpenSSH 패키지 파일을 찾을 수 없습니다: $OPENSSH_DIR"
        return 1
    fi
    
    # 설치 (파일명 순서대로)
    rpm -Uvh openssh-[0-9]*.rpm openssh-server*.rpm openssh-clients*.rpm 2>&1 | tee -a "$LOG_FILE"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "OpenSSH 설치 완료"
        return 0
    else
        log_error "OpenSSH 설치 실패"
        return 1
    fi
}

# OpenSSL 설치
install_openssl() {
    log "\n=== OpenSSL 설치 중... ==="
    
    cd "$OPENSSL_DIR"
    
    # 패키지 파일 확인
    local rpm_files=$(find . -maxdepth 1 -name "openssl*.rpm" -type f)
    
    if [ -z "$rpm_files" ]; then
        log_error "OpenSSL 패키지 파일을 찾을 수 없습니다: $OPENSSL_DIR"
        return 1
    fi
    
    # FIPS provider 타입에 따라 설치 방법 결정
    if [ "$FIPS_PROVIDER_TYPE" = "next" ]; then
        # fips-provider-next 사용 (9.5+)
        log_info "fips-provider-next 환경 - openssl-fips-provider 제외"
        
        # openssl-fips-provider 제외하고 설치
        local install_cmd="rpm -Uvh"
        
        # openssl-[숫자]로 시작하는 파일만 (fips-provider 제외)
        if ls openssl-[0-9]*.rpm >/dev/null 2>&1; then
            install_cmd="$install_cmd openssl-[0-9]*.rpm"
        fi
        
        if ls openssl-libs*.rpm >/dev/null 2>&1; then
            install_cmd="$install_cmd openssl-libs*.rpm"
        fi
        
        if ls openssl-devel*.rpm >/dev/null 2>&1; then
            install_cmd="$install_cmd openssl-devel*.rpm"
        fi
        
        eval "$install_cmd" 2>&1 | tee -a "$LOG_FILE"
        
    elif [ "$FIPS_PROVIDER_TYPE" = "legacy" ] || [ "$FIPS_PROVIDER_TYPE" = "none" ]; then
        # openssl-fips-provider 사용 또는 FIPS 없음 (9.0-9.4)
        log_info "Legacy FIPS 환경 또는 FIPS 미사용 - 모든 패키지 설치"
        
        # 모든 openssl 패키지 설치
        rpm -Uvh openssl*.rpm 2>&1 | tee -a "$LOG_FILE"
    else
        # 알 수 없는 경우 - 안전하게 fips-provider 제외
        log_warning "FIPS provider 타입을 확인할 수 없습니다. 안전하게 진행합니다."
        
        rpm -Uvh openssl-[0-9]*.rpm openssl-libs*.rpm openssl-devel*.rpm 2>&1 | tee -a "$LOG_FILE"
    fi
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "OpenSSL 설치 완료"
        return 0
    else
        log_error "OpenSSL 설치 실패"
        return 1
    fi
}

# OpenSSH 롤백
rollback_openssh() {
    log_warning "\n=== OpenSSH 롤백 중... ==="
    
    if [ ! -f "$BACKUP_DIR/openssh/versions.txt" ]; then
        log_error "백업 파일을 찾을 수 없습니다."
        return 1
    fi
    
    # 백업된 버전 정보 읽기
    local old_packages=$(cat "$BACKUP_DIR/openssh/versions.txt")
    
    log "이전 버전으로 롤백 시도..."
    log "$old_packages"
    
    # 온라인 환경이 아니므로 수동 롤백 안내
    log_error "자동 롤백 불가 - 수동으로 이전 RPM 파일 설치 필요"
    log "백업 위치: $BACKUP_DIR/openssh"
    
    return 1
}

# OpenSSL 롤백
rollback_openssl() {
    log_warning "\n=== OpenSSL 롤백 중... ==="
    
    if [ ! -d "$BACKUP_DIR/openssl" ]; then
        log_error "백업 디렉토리를 찾을 수 없습니다."
        return 1
    fi
    
    # 라이브러리 복구 시도
    log "라이브러리 파일 복구 중..."
    cp -af "$BACKUP_DIR/openssl/libssl.so"* /usr/lib64/ 2>&1 | tee -a "$LOG_FILE"
    cp -af "$BACKUP_DIR/openssl/libcrypto.so"* /usr/lib64/ 2>&1 | tee -a "$LOG_FILE"
    
    ldconfig
    
    log_warning "라이브러리 복구 완료 - RPM 패키지는 수동 설치 필요"
    log "백업 위치: $BACKUP_DIR/openssl"
    
    return 1
}

# OpenSSH 버전 확인
verify_openssh() {
    log "\n=== OpenSSH 버전 확인 ==="
    
    local installed_version=$(rpm -q openssh-server)
    log "설치된 버전: $installed_version"
    
    ssh -V 2>&1 | tee -a "$LOG_FILE"
    
    log_success "OpenSSH 설치 확인됨"
    return 0
}

# OpenSSL 버전 확인 및 CVE 검증
verify_openssl() {
    log "\n=== OpenSSL 버전 확인 ==="
    
    local installed_version=$(rpm -q openssl)
    log "설치된 버전: $installed_version"
    
    openssl version | tee -a "$LOG_FILE"
    
    # CVE 패치 확인
    log "\n=== CVE 패치 확인 ==="
    local all_found=true
    
    for cve in $CVE_LIST; do
        log_info "확인 중: $cve"
        if rpm -q --changelog openssl | grep -q "$cve"; then
            rpm -q --changelog openssl | grep -A 2 "$cve" | head -4 | tee -a "$LOG_FILE"
            log_success "  ✓ $cve 패치 확인됨"
        else
            log_warning "  ✗ $cve 패치를 찾을 수 없음"
            all_found=false
        fi
    done
    
    if [ "$all_found" = true ]; then
        log_success "\n모든 CVE 패치 확인 완료"
        return 0
    else
        log_warning "\n일부 CVE 패치가 확인되지 않았습니다."
        return 1
    fi
}

# SSH 서비스 재시작
restart_sshd() {
    log "\n=== SSH 서비스 재시작 ==="
    
    systemctl restart sshd 2>&1 | tee -a "$LOG_FILE"
    
    if systemctl is-active --quiet sshd; then
        log_success "SSH 서비스 정상 작동"
        systemctl status sshd --no-pager | tee -a "$LOG_FILE"
        return 0
    else
        log_error "SSH 서비스 재시작 실패"
        systemctl status sshd --no-pager | tee -a "$LOG_FILE"
        return 1
    fi
}

# 최종 검증
final_verification() {
    log "\n=========================================="
    log "=== 최종 검증 ==="
    log "=========================================="
    
    log "\n[설치된 패키지]"
    rpm -q openssl openssl-libs openssh openssh-server | tee -a "$LOG_FILE"
    
    log "\n[OpenSSL 버전]"
    openssl version | tee -a "$LOG_FILE"
    
    log "\n[SSH 버전]"
    ssh -V 2>&1 | tee -a "$LOG_FILE"
    
    log "\n[SSH 서비스 상태]"
    systemctl is-active sshd | tee -a "$LOG_FILE"
    
    log_success "\n패치 완료!"
    log "로그 파일: $LOG_FILE"
    log "백업 위치: $BACKUP_DIR"
    log "결과 파일: $RESULT_FILE"
    log_warning "\n⚠️  SSH 명령 캐시 초기화 안내"
    log_warning "현재 터미널에서 'ssh -V' 실행 시 오류가 발생할 수 있습니다."
    log_warning "해결 방법: SSH를 재연결하거나 아래 명령을 실행하세요."
    log "  hash -r"
}

# 결과 파일 생성
generate_result_file() {
    log "\n=== 결과 파일 생성 중... ==="
    
    cat > "$RESULT_FILE" << EOF
========================================
OpenSSL/OpenSSH 보안 패치 결과 보고서
========================================

패치 완료 시간: $(date)
호스트명: $(hostname)

========================================
시스템 정보
========================================

OS 버전:
$(cat /etc/redhat-release)

감지된 버전: ${OS_VERSION}
FIPS Provider 타입: ${FIPS_PROVIDER_TYPE}

아키텍처: $(uname -m)

========================================
패치 전 버전 정보
========================================

$(cat $BACKUP_DIR/openssh/versions.txt 2>/dev/null || echo "백업 정보 없음")
$(cat $BACKUP_DIR/openssl/versions.txt 2>/dev/null || echo "백업 정보 없음")

========================================
패치 후 버전 정보
========================================

[설치된 패키지]
$(rpm -q openssl openssl-libs openssh openssh-server openssh-clients 2>/dev/null || echo "일부 패키지 확인 실패")

[OpenSSL 버전]
$(openssl version)

[SSH 버전]
$(ssh -V 2>&1)

[SSH 서비스 상태]
$(systemctl is-active sshd)

========================================
반영된 CVE 패치
========================================

EOF

    # 각 CVE에 대해 확인
    for cve in $CVE_LIST; do
        echo "[$cve]" >> "$RESULT_FILE"
        if rpm -q --changelog openssl 2>/dev/null | grep -q "$cve"; then
            echo "상태: ✅ 패치됨" >> "$RESULT_FILE"
            rpm -q --changelog openssl | grep -A 3 "$cve" | head -5 >> "$RESULT_FILE"
        else
            echo "상태: ⚠️  확인되지 않음" >> "$RESULT_FILE"
        fi
        echo "" >> "$RESULT_FILE"
    done

    cat >> "$RESULT_FILE" << EOF
========================================
백업 정보
========================================

백업 위치: $BACKUP_DIR
로그 파일: $LOG_FILE

백업된 파일:
- OpenSSH: $BACKUP_DIR/openssh/
- OpenSSL: $BACKUP_DIR/openssl/
- FIPS 정보: $BACKUP_DIR/openssl/fips_info.txt

========================================
EOF

    log_success "결과 파일 생성 완료: $RESULT_FILE"
    
    # 결과 파일 내용 출력
    log "\n=========================================="
    log "=== 결과 파일 내용 ==="
    log "=========================================="
    cat "$RESULT_FILE" | tee -a "$LOG_FILE"
}

# ==================== 메인 로직 ====================

main() {
    # 초기화
    mkdir -p "$BACKUP_DIR" "$LOG_DIR"
    
    log "=========================================="
    log "OpenSSL/OpenSSH 보안 패치 스크립트 v2.1"
    log "Rocky Linux / RHEL 9.0 ~ 9.x 전체 지원"
    log "=========================================="
    log "시작 시간: $(date)"
    log "호스트: $(hostname)"
    
    # OS 버전 감지
    detect_os_version
    
    log "=========================================="
    
    # 점검 대상 CVE 표시
    log "\n점검 대상 CVE:"
    for cve in $CVE_LIST; do
        log "  - $cve"
    done
    
    # Root 권한 확인
    if [ "$EUID" -ne 0 ]; then
        log_error "이 스크립트는 root 권한이 필요합니다."
        exit 1
    fi
    
    # 디렉토리 확인
    if [ ! -d "$OPENSSH_DIR" ] || [ ! -d "$OPENSSL_DIR" ]; then
        log_error "패키지 디렉토리를 찾을 수 없습니다."
        log "필요: $OPENSSH_DIR, $OPENSSL_DIR"
        exit 1
    fi
    
    # 패키지 파일 확인
    if ! check_openssh_packages; then
        exit 1
    fi
    
    if ! check_openssl_packages; then
        exit 1
    fi
    
    # CVE 사전 확인
    verify_cve_in_packages
    
    # 현재 SSH 세션 경고
    log_warning "\n⚠️  중요: 현재 SSH 세션을 유지하세요!"
    log_warning "패치 중 SSH 연결이 끊어지지 않도록 주의하세요."
    echo ""
    
    # /usr/local 확인
    check_and_remove_local_ssh
    
    # ========== OpenSSH 패치 ==========
    if ask_yes_no "\nOpenSSH 패치를 진행하시겠습니까?"; then
        log "\n########## OpenSSH 패치 시작 ##########"
        
        # 백업
        if ! backup_openssh; then
            log_error "백업 실패"
            exit 1
        fi
        
        # 설치
        if ! install_openssh; then
            log_error "설치 실패 - 롤백 시도"
            rollback_openssh
            exit 1
        fi
        
        # 검증
        if ! verify_openssh; then
            log_warning "검증 경고 - 계속 진행합니다."
        fi
        
        log_success "\n########## OpenSSH 패치 완료 ##########"
    else
        log_warning "OpenSSH 패치를 건너뜁니다."
        log_warning "⚠️  OpenSSL 패치를 위해서는 OpenSSH를 먼저 업데이트해야 합니다!"
        
        if ! ask_yes_no "그래도 계속하시겠습니까?"; then
            log "패치를 중단합니다."
            exit 0
        fi
    fi
    
    # ========== OpenSSL 패치 ==========
    if ask_yes_no "\nOpenSSL 패치를 진행하시겠습니까?"; then
        log "\n########## OpenSSL 패치 시작 ##########"
        
        # 백업
        if ! backup_openssl; then
            log_error "백업 실패"
            exit 1
        fi
        
        # 설치
        if ! install_openssl; then
            log_error "설치 실패 - 롤백 시도"
            rollback_openssl
            exit 1
        fi
        
        # 라이브러리 캐시 갱신
        log "\n라이브러리 캐시 갱신 중..."
        ldconfig
        hash -r
        log_success "캐시 갱신 완료"
        
        # SSH 재시작
        if ! restart_sshd; then
            log_error "SSH 재시작 실패 - 롤백 시도"
            rollback_openssl
            exit 1
        fi
        
        # 검증
        if ! verify_openssl; then
            log_warning "일부 CVE 확인 실패 - 수동 확인 필요"
        fi
        
        log_success "\n########## OpenSSL 패치 완료 ##########"
    else
        log_warning "OpenSSL 패치를 건너뜁니다."
    fi
    
    # 최종 검증
    final_verification
    
    # 결과 파일 생성
    generate_result_file
    
    log "\n=========================================="
    log "종료 시간: $(date)"
    log "=========================================="
}

# 스크립트 실행
main "$@"