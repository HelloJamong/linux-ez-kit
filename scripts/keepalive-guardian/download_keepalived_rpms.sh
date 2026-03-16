#!/bin/bash

################################################################################
# Keepalived RPM 다운로드 스크립트 (온라인 환경용)
#
# 목적: 오프라인 환경에 설치하기 위한 Keepalived 및 의존성 RPM 다운로드
# 사용법: ./download_keepalived_rpms.sh [--with-mariadb]
# 환경: Rocky Linux 8.10 또는 9.7 이상
################################################################################

set -e  # 오류 발생 시 즉시 종료

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 배너 출력
print_banner() {
    echo "========================================================================"
    echo "  Keepalived RPM 다운로드 스크립트 (오프라인 환경용)"
    echo "========================================================================"
    echo ""
}

# 사용법 출력
usage() {
    cat <<EOF
사용법: $0 [OPTIONS]

OPTIONS:
    --with-mariadb      MariaDB client 패키지도 함께 다운로드 (DB 복제 체크 사용 시)
    -h, --help          도움말 출력

예시:
    # Keepalived만 다운로드
    $0

    # Keepalived + MariaDB 다운로드
    $0 --with-mariadb
EOF
    exit 1
}

# 환경 검증
validate_environment() {
    log_info "환경 검증 중..."

    # Rocky Linux 확인
    if [ ! -f /etc/rocky-release ]; then
        log_error "이 스크립트는 Rocky Linux 전용입니다."
        exit 1
    fi

    # OS 버전 확인
    OS_VERSION=$(rpm -E %{rhel})
    if [[ "$OS_VERSION" != "8" && "$OS_VERSION" != "9" ]]; then
        log_error "지원되지 않는 OS 버전입니다. (감지: RHEL $OS_VERSION)"
        log_error "지원 버전: Rocky Linux 8.10 이상 또는 9.7 이상"
        exit 1
    fi

    log_success "OS 버전: Rocky Linux $OS_VERSION"

    # 인터넷 연결 확인
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log_error "인터넷 연결을 확인할 수 없습니다."
        log_error "이 스크립트는 온라인 환경에서 실행해야 합니다."
        exit 1
    fi

    log_success "인터넷 연결 확인됨"

    # dnf 명령어 확인
    if ! command -v dnf >/dev/null 2>&1; then
        log_error "dnf 명령어를 찾을 수 없습니다."
        exit 1
    fi

    log_success "환경 검증 완료"
}

# Keepalived 다운로드
download_keepalived() {
    log_info "Keepalived 및 의존성 다운로드 중..."

    dnf download --resolve --alldeps keepalived 2>&1 | tee -a "$LOG_FILE"

    if [ $? -ne 0 ]; then
        log_error "Keepalived 다운로드 실패"
        exit 1
    fi

    KEEPALIVED_COUNT=$(ls -1 keepalived-*.rpm 2>/dev/null | wc -l)
    if [ "$KEEPALIVED_COUNT" -eq 0 ]; then
        log_error "Keepalived 패키지를 찾을 수 없습니다."
        exit 1
    fi

    log_success "Keepalived 다운로드 완료"
}

# MariaDB 다운로드
download_mariadb() {
    log_info "MariaDB client 및 의존성 다운로드 중..."

    dnf download --resolve --alldeps mariadb 2>&1 | tee -a "$LOG_FILE"

    if [ $? -ne 0 ]; then
        log_warn "MariaDB 다운로드 실패 (선택사항이므로 계속 진행)"
        return 0
    fi

    MARIADB_COUNT=$(ls -1 mariadb-*.rpm 2>/dev/null | wc -l)
    if [ "$MARIADB_COUNT" -eq 0 ]; then
        log_warn "MariaDB 패키지를 찾을 수 없습니다."
        return 0
    fi

    log_success "MariaDB 다운로드 완료"
}

# 패키지 정보 생성
generate_package_info() {
    log_info "패키지 정보 파일 생성 중..."

    # 패키지 목록 저장
    ls -1 *.rpm > "$PACKAGE_LIST" 2>/dev/null

    RPM_COUNT=$(cat "$PACKAGE_LIST" | wc -l)

    # 상세 정보 파일 생성
    cat > "$INFO_FILE" <<EOF
======================================================================
Keepalived RPM 패키지 다운로드 정보
======================================================================

다운로드 일시: $(date '+%Y-%m-%d %H:%M:%S')
다운로드 서버 OS: Rocky Linux $OS_VERSION
다운로드 서버 호스트: $(hostname)

총 패키지 수: $RPM_COUNT 개

주요 패키지:
$(rpm -qp keepalived-*.rpm --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | head -1)
$(if [ -f mariadb-[0-9]*.rpm ]; then rpm -qp mariadb-[0-9]*.rpm --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | head -1; fi)

전체 패키지 목록:
$(cat "$PACKAGE_LIST")

======================================================================
오프라인 설치 방법:
======================================================================

1. 압축 파일을 오프라인 서버로 전송:
   scp $ARCHIVE_FILE user@offline-server:/tmp/

2. 압축 해제:
   cd /tmp
   tar -xzf $ARCHIVE_FILE

3. 설치 (방법 1 - 한번에 설치):
   cd keepalived-rpms-rocky$OS_VERSION
   sudo rpm -Uvh *.rpm

4. 설치 (방법 2 - 의존성 순서대로):
   sudo rpm -ivh glibc-*.rpm zlib-*.rpm pcre2-*.rpm
   sudo rpm -ivh libnl3-*.rpm openssl-libs-*.rpm glib2-*.rpm
   sudo rpm -ivh keepalived-*.rpm

5. 설치 확인:
   keepalived --version
   mysql --version  # MariaDB 포함 시

======================================================================
EOF

    log_success "패키지 정보 파일 생성 완료: $INFO_FILE"
}

# 압축 파일 생성
create_archive() {
    log_info "압축 파일 생성 중..."

    cd "$SCRIPT_DIR"

    tar -czf "$ARCHIVE_FILE" -C "$DOWNLOAD_DIR" . 2>&1 | tee -a "$LOG_FILE"

    if [ $? -ne 0 ]; then
        log_error "압축 파일 생성 실패"
        exit 1
    fi

    ARCHIVE_SIZE=$(du -h "$ARCHIVE_FILE" | awk '{print $1}')
    log_success "압축 파일 생성 완료: $ARCHIVE_FILE ($ARCHIVE_SIZE)"
}

# 체크섬 생성
generate_checksum() {
    log_info "체크섬 생성 중..."

    cd "$SCRIPT_DIR"

    sha256sum "$ARCHIVE_FILE" > "${ARCHIVE_FILE}.sha256"

    log_success "체크섬 파일 생성 완료: ${ARCHIVE_FILE}.sha256"
}

# 결과 출력
print_summary() {
    echo ""
    echo "========================================================================"
    echo "  다운로드 완료!"
    echo "========================================================================"
    echo ""
    echo "다운로드 디렉토리: $DOWNLOAD_DIR"
    echo "총 패키지 수: $RPM_COUNT 개"
    echo "압축 파일: $ARCHIVE_FILE"
    echo "압축 파일 크기: $(du -h "$ARCHIVE_FILE" | awk '{print $1}')"
    echo "체크섬 파일: ${ARCHIVE_FILE}.sha256"
    echo ""
    echo "다음 단계:"
    echo "1. $ARCHIVE_FILE 파일을 오프라인 서버로 전송하세요."
    echo "2. 오프라인 서버에서 압축을 해제하세요."
    echo "3. keepalive-guardian/install.sh 스크립트로 설치하세요."
    echo ""
    echo "상세 정보는 $DOWNLOAD_DIR/DOWNLOAD_INFO.txt 파일을 참고하세요."
    echo "========================================================================"
}

# 메인 함수
main() {
    print_banner

    # 인자 파싱
    DOWNLOAD_MARIADB=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --with-mariadb)
                DOWNLOAD_MARIADB=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "알 수 없는 옵션: $1"
                usage
                ;;
        esac
    done

    # 환경 검증
    validate_environment

    # 변수 설정
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DOWNLOAD_DIR="${SCRIPT_DIR}/keepalived-rpms-rocky${OS_VERSION}"
    ARCHIVE_FILE="keepalived-rpms-rocky${OS_VERSION}.tar.gz"
    PACKAGE_LIST="package-list-rocky${OS_VERSION}.txt"
    INFO_FILE="DOWNLOAD_INFO.txt"
    LOG_FILE="download-${TIMESTAMP}.log"

    # 다운로드 디렉토리 생성
    if [ -d "$DOWNLOAD_DIR" ]; then
        log_warn "기존 다운로드 디렉토리 발견: $DOWNLOAD_DIR"
        log_warn "기존 디렉토리를 백업하고 새로 생성합니다."
        mv "$DOWNLOAD_DIR" "${DOWNLOAD_DIR}.backup.${TIMESTAMP}"
    fi

    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"

    log_info "다운로드 디렉토리: $DOWNLOAD_DIR"
    log_info "로그 파일: $LOG_FILE"

    # Keepalived 다운로드
    download_keepalived

    # MariaDB 다운로드 (옵션)
    if [ "$DOWNLOAD_MARIADB" = true ]; then
        download_mariadb
    else
        log_info "MariaDB 다운로드 건너뛰기 (--with-mariadb 옵션 미사용)"
    fi

    # 패키지 정보 생성
    generate_package_info

    # 압축 파일 생성
    create_archive

    # 체크섬 생성
    generate_checksum

    # 결과 출력
    print_summary
}

# 스크립트 실행
main "$@"
