#!/bin/bash
#
# update-java.sh
# tar.gz로 수동 설치된 Eclipse Temurin JDK 21을 안전하게 업데이트합니다.
# 대상: Rocky Linux 9 (RHEL 계열)
#
# 사용법:
#   ./update-java.sh --check
#   ./update-java.sh --help
#   sudo ./update-java.sh [--dry-run] [--force] [--sha256 <SHA256>] <tar.gz>

set -Eeuo pipefail

# ==================== 색상/로그 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
error_exit(){ log_error "$*"; exit 1; }

trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO)."' ERR

# ==================== 고정 경로 ====================
JVM_DIR="/usr/lib/jvm"
SYMLINK_PATH="${JVM_DIR}/temurin-21"
PROFILE_SCRIPT="/etc/profile.d/java.sh"

# ==================== 전역 상태 ====================
MODE="update"
DRY_RUN=0
FORCE=0
SHA256_EXPECTED=""
TARBALL=""

TMP_DIR=""
STAGING_DIR=""
PREV_SYMLINK_TARGET=""

CUR_SYMLINK_TARGET=""
CUR_JDK_VERSION=""
NEW_JDK_NAME=""
NEW_JDK_SRC=""
NEW_JDK_PATH=""
NEW_JDK_VERSION=""
NEW_OS_ARCH=""

cleanup() {
    [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
    [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]] && rm -rf "${STAGING_DIR}"
    return 0
}
trap cleanup EXIT

# ==================== 도움말 ====================
print_help() {
    cat <<'EOF'
사용법:
  update-java.sh --check
  update-java.sh --help
  sudo update-java.sh [--dry-run] [--force] [--sha256 <SHA256>] <tar.gz>

옵션:
  --check           변경 없이 현재 Java 환경만 점검
  --dry-run         실제 변경 없이 검증(아카이브/버전/아키텍처)까지만 수행
  --force           신규 버전이 현재와 동일할 때도 재설치 허용 (다운그레이드는 허용하지 않음)
  --sha256 <hash>   설치 전 tar.gz 파일의 SHA-256 값을 검증
  --help            이 도움말 출력

예:
  ./update-java.sh --check
  sudo ./update-java.sh --dry-run OpenJDK21U-jdk_x64_linux_hotspot_21.0.11_9.tar.gz
  sudo ./update-java.sh --sha256 <hash> OpenJDK21U-jdk_x64_linux_hotspot_21.0.11_9.tar.gz
EOF
}

# ==================== 인자 파싱 ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) MODE="check"; shift ;;
            --help|-h) MODE="help"; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --force) FORCE=1; shift ;;
            --sha256)
                [[ $# -ge 2 ]] || error_exit "--sha256 옵션에는 값이 필요합니다."
                SHA256_EXPECTED="$2"; shift 2 ;;
            --*) error_exit "알 수 없는 옵션: $1" ;;
            *)
                [[ -z "$TARBALL" ]] || error_exit "tar.gz 인자는 하나만 지정할 수 있습니다."
                TARBALL="$1"; shift ;;
        esac
    done
}

require_root() {
    [[ "$EUID" -eq 0 ]] || error_exit "이 작업은 root 권한이 필요합니다. sudo로 실행하세요."
}

get_release_field() {
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'
}

# ==================== 현재 환경 점검 ====================
inspect_current_env() {
    log_info "=== 현재 Java 환경 점검 ==="

    command -v java &>/dev/null || error_exit "java 명령어를 찾을 수 없습니다."
    log_info "command -v java: $(command -v java)"
    log_info "readlink -f: $(readlink -f "$(command -v java)")"

    if [[ -n "${JAVA_HOME:-}" ]]; then
        log_info "JAVA_HOME (현재 쉘): ${JAVA_HOME}"
        log_info "JAVA_HOME 실제 경로: $(readlink -f "${JAVA_HOME}" 2>/dev/null || echo '(확인 불가)')"
    else
        log_warn "현재 쉘에 JAVA_HOME이 설정되어 있지 않습니다 (sudo 환경에서는 정상일 수 있음)."
    fi

    [[ -f "$PROFILE_SCRIPT" ]] || error_exit "${PROFILE_SCRIPT} 파일이 없습니다. 예상한 환경이 아닙니다."
    local profile_java_home
    profile_java_home=$(grep -E '^export[[:space:]]+JAVA_HOME=' "$PROFILE_SCRIPT" | head -1 | sed -E 's/^export[[:space:]]+JAVA_HOME=//' | tr -d '"'"'"'')
    [[ -n "$profile_java_home" ]] || error_exit "${PROFILE_SCRIPT} 에서 JAVA_HOME을 찾을 수 없습니다."
    log_info "JAVA_HOME (${PROFILE_SCRIPT}): ${profile_java_home}"
    [[ "$profile_java_home" == "$SYMLINK_PATH" ]] || \
        error_exit "JAVA_HOME이 예상 경로(${SYMLINK_PATH})를 가리키지 않습니다: ${profile_java_home}"

    [[ -L "$SYMLINK_PATH" ]] || error_exit "${SYMLINK_PATH} 가 심볼릭 링크가 아닙니다. 예상하지 못한 구조입니다."
    CUR_SYMLINK_TARGET=$(readlink -f "$SYMLINK_PATH")
    log_info "${SYMLINK_PATH} -> ${CUR_SYMLINK_TARGET}"
    [[ -d "$CUR_SYMLINK_TARGET" ]] || error_exit "심볼릭 링크 대상 디렉터리가 존재하지 않습니다: ${CUR_SYMLINK_TARGET}"

    if rpm -qf "$CUR_SYMLINK_TARGET" &>/dev/null; then
        error_exit "현재 JDK가 RPM 패키지로 관리되고 있습니다. 이 스크립트는 tar.gz 수동 설치 환경만 지원합니다."
    fi
    log_ok "RPM 비관리 설치 확인됨 (tar.gz 수동 설치)"

    local release_file="${CUR_SYMLINK_TARGET}/release"
    [[ -f "$release_file" ]] || error_exit "release 파일을 찾을 수 없습니다: ${release_file}"
    local implementor implementor_version
    implementor=$(get_release_field "$release_file" IMPLEMENTOR)
    implementor_version=$(get_release_field "$release_file" IMPLEMENTOR_VERSION)
    [[ "$implementor" == *"Adoptium"* && "$implementor_version" == Temurin-* ]] || \
        error_exit "현재 JDK가 Eclipse Temurin이 아닙니다 (IMPLEMENTOR=${implementor})."

    CUR_JDK_VERSION="${implementor_version#Temurin-}"
    log_info "Current JDK: ${CUR_SYMLINK_TARGET}"
    log_info "Current Java version: ${CUR_JDK_VERSION}"
    log_ok "현재 Java 환경 검증 완료"
}

# ==================== 아카이브 검증 ====================
validate_archive() {
    local file="$1"
    [[ -e "$file" ]] || error_exit "파일이 존재하지 않습니다: ${file}"
    [[ -f "$file" ]] || error_exit "일반 파일이 아닙니다: ${file}"
    case "$file" in
        *.tar.gz|*.tgz) ;;
        *) error_exit "파일은 .tar.gz 또는 .tgz 이어야 합니다: ${file}" ;;
    esac

    gzip -t "$file" 2>/dev/null || error_exit "손상된 gzip 아카이브입니다: ${file}"

    local entries
    entries=$(tar -tzf "$file" 2>/dev/null) || error_exit "손상되었거나 읽을 수 없는 tar 아카이브입니다: ${file}"

    if echo "$entries" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        error_exit "아카이브에 위험한 경로(절대경로 또는 '..')가 포함되어 있습니다: ${file}"
    fi

    local top_count top_name
    top_count=$(echo "$entries" | awk -F/ '{print $1}' | sort -u | wc -l)
    [[ "$top_count" -eq 1 ]] || error_exit "아카이브는 최상위 디렉터리 1개만 포함해야 합니다 (발견: ${top_count}개)."
    top_name=$(echo "$entries" | awk -F/ '{print $1}' | sort -u)

    echo "$entries" | grep -q "^${top_name}/bin/java$" || error_exit "아카이브에 bin/java 가 없습니다."
    echo "$entries" | grep -q "^${top_name}/bin/javac$" || error_exit "아카이브에 bin/javac 가 없습니다 (JDK 아카이브가 아닌 것으로 보임)."

    log_ok "아카이브 구조 검증 완료: ${file}"
}

verify_sha256() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ "${actual,,}" == "${expected,,}" ]] || \
        error_exit "SHA-256 불일치. expected=${expected} actual=${actual}"
    log_ok "SHA-256 검증 성공: ${actual}"
}

extract_archive() {
    local file="$1"
    TMP_DIR=$(mktemp -d /tmp/update-java.XXXXXX)
    chmod 700 "$TMP_DIR"
    log_info "임시 디렉터리에 압축 해제: ${TMP_DIR}"
    tar -xzf "$file" -C "$TMP_DIR"

    NEW_JDK_NAME=$(basename "$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d)")
    NEW_JDK_SRC="${TMP_DIR}/${NEW_JDK_NAME}"
    [[ -x "${NEW_JDK_SRC}/bin/java" && -x "${NEW_JDK_SRC}/bin/javac" ]] || \
        error_exit "압축 해제 후 bin/java 또는 bin/javac 실행 파일을 찾을 수 없습니다."
}

identify_new_jdk() {
    local release_file="${NEW_JDK_SRC}/release"
    [[ -f "$release_file" ]] || error_exit "release 파일을 찾을 수 없습니다: ${NEW_JDK_NAME}/release"

    local implementor implementor_version
    implementor=$(get_release_field "$release_file" IMPLEMENTOR)
    implementor_version=$(get_release_field "$release_file" IMPLEMENTOR_VERSION)
    NEW_OS_ARCH=$(get_release_field "$release_file" OS_ARCH)

    [[ "$implementor" == *"Adoptium"* ]] || error_exit "Eclipse Temurin 빌드가 아닙니다 (IMPLEMENTOR=${implementor})."
    [[ "$implementor_version" == Temurin-21.* ]] || error_exit "Temurin JDK 21 빌드가 아닙니다 (IMPLEMENTOR_VERSION=${implementor_version})."

    NEW_JDK_VERSION="${implementor_version#Temurin-}"
    log_info "New Java version: ${NEW_JDK_VERSION} (${NEW_OS_ARCH})"
}

check_architecture() {
    local sys_arch
    sys_arch=$(uname -m)
    [[ "$NEW_OS_ARCH" == "$sys_arch" ]] || \
        error_exit "아키텍처 불일치: archive=${NEW_OS_ARCH}, system=${sys_arch}"
}

# 버전 비교: "+" 를 "." 로 바꿔 sort -V 로 비교 (major.minor.patch.build)
version_relation() {
    local old="${1//+/.}" new="${2//+/.}"
    if [[ "$old" == "$new" ]]; then
        echo "same"
    elif [[ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -1)" == "$new" ]]; then
        echo "newer"
    else
        echo "older"
    fi
}

compare_and_gate_version() {
    local rel
    rel=$(version_relation "$CUR_JDK_VERSION" "$NEW_JDK_VERSION")
    case "$rel" in
        newer)
            log_info "신규 버전(${NEW_JDK_VERSION})이 현재 버전(${CUR_JDK_VERSION})보다 최신입니다." ;;
        same)
            [[ "$FORCE" -eq 1 ]] || \
                error_exit "신규 버전이 현재 버전과 동일합니다 (${NEW_JDK_VERSION}). 재설치하려면 --force를 사용하세요."
            log_warn "동일 버전(${NEW_JDK_VERSION})이지만 --force 옵션으로 계속 진행합니다." ;;
        older)
            error_exit "신규 버전(${NEW_JDK_VERSION})이 현재 버전(${CUR_JDK_VERSION})보다 낮습니다. 다운그레이드는 지원하지 않습니다." ;;
    esac
}

check_running_java_processes() {
    local procs
    procs=$(pgrep -a java 2>/dev/null || true)
    [[ -n "$procs" ]] || return 0

    log_warn "현재 실행 중인 Java 프로세스가 존재합니다."
    log_warn "실행 중인 JVM은 JDK 링크를 변경해도 자동으로 신규 버전으로 변경되지 않습니다."
    log_warn "관련 서비스를 별도로 재시작해야 합니다."
    while read -r pid cmd; do
        local user
        user=$(ps -o user= -p "$pid" 2>/dev/null || echo "?")
        log_warn "  PID=${pid} USER=${user} CMD=${cmd}"
    done <<< "$procs"
}

print_dry_run_summary() {
    echo
    log_info "=== DRY-RUN 요약 (실제 변경 없음) ==="
    log_info "현재 버전: ${CUR_JDK_VERSION} (${CUR_SYMLINK_TARGET})"
    log_info "신규 버전: ${NEW_JDK_VERSION}"
    log_info "설치 예정 경로: ${JVM_DIR}/${NEW_JDK_NAME}"
    log_info "변경 예정 심볼릭 링크: ${SYMLINK_PATH} -> ${JVM_DIR}/${NEW_JDK_NAME}"
    log_ok "DRY-RUN 완료. 실제 변경 사항 없음."
}

# ==================== 실제 설치 ====================
install_new_jdk() {
    local dest="${JVM_DIR}/${NEW_JDK_NAME}"
    [[ -e "$dest" ]] && error_exit "설치 대상이 이미 존재합니다. 덮어쓰지 않습니다: ${dest}"

    STAGING_DIR="${dest}.installing.$$"
    log_info "신규 JDK 설치 중..."
    cp -a "$NEW_JDK_SRC" "$STAGING_DIR"
    mv -T "$STAGING_DIR" "$dest"
    STAGING_DIR=""
    chown -R root:root "$dest" || error_exit "소유권 변경에 실패했습니다: ${dest}"
    NEW_JDK_PATH="$dest"

    "${dest}/bin/java" -version &>/dev/null || error_exit "신규 JDK 실행에 실패했습니다: ${dest}/bin/java -version"
    "${dest}/bin/javac" -version &>/dev/null || error_exit "신규 JDK 실행에 실패했습니다: ${dest}/bin/javac -version"
    log_ok "New JDK validation successful."
}

switch_symlink() {
    PREV_SYMLINK_TARGET="$CUR_SYMLINK_TARGET"
    log_info "Switching symbolic link..."
    local tmp_link="${SYMLINK_PATH}.new.$$"
    ln -s "$NEW_JDK_PATH" "$tmp_link"
    mv -T "$tmp_link" "$SYMLINK_PATH"
    log_ok "${SYMLINK_PATH} -> ${NEW_JDK_PATH}"
}

verify_after_switch() {
    "${SYMLINK_PATH}/bin/java" -version &>/dev/null || return 1
    "${SYMLINK_PATH}/bin/javac" -version &>/dev/null || return 1
    [[ "$(readlink -f "$SYMLINK_PATH")" == "$NEW_JDK_PATH" ]] || return 1
    return 0
}

rollback_symlink() {
    log_warn "이전 링크로 롤백합니다: ${PREV_SYMLINK_TARGET}"
    local tmp_link="${SYMLINK_PATH}.rollback.$$"
    ln -s "$PREV_SYMLINK_TARGET" "$tmp_link"
    mv -T "$tmp_link" "$SYMLINK_PATH"

    if "${SYMLINK_PATH}/bin/java" -version &>/dev/null; then
        log_ok "롤백 성공: ${SYMLINK_PATH} -> ${PREV_SYMLINK_TARGET}"
        exit 1
    else
        log_error "롤백 실패. 수동 조치가 필요합니다. 기대 대상: ${PREV_SYMLINK_TARGET}"
        exit 2
    fi
}

final_report() {
    echo
    log_ok "Java update completed successfully."
    echo
    echo "Previous JDK:"
    echo "  ${PREV_SYMLINK_TARGET}"
    echo
    echo "Current JDK:"
    echo "  ${NEW_JDK_PATH}"
    echo
    log_warn "현재 로그인된 다른 쉘은 command hash 캐시로 인해 변경 사항이 즉시 반영되지 않을 수 있습니다."
    log_warn "필요 시 해당 쉘에서 'hash -r' 실행 또는 재접속하세요."
    log_info "java -version: $(java -version 2>&1 | head -1)"
    log_info "command -v java: $(command -v java)"
    log_info "readlink -f: $(readlink -f "$(command -v java)")"
    echo
    echo "기존 JDK는 자동 삭제되지 않습니다. 충분히 검증 후 필요 시 수동으로 삭제하세요:"
    echo "  rm -rf \"${PREV_SYMLINK_TARGET}\""
}

# ==================== 메인 ====================
main() {
    parse_args "$@"

    case "$MODE" in
        help) print_help; exit 0 ;;
        check)
            [[ -z "$TARBALL" ]] || error_exit "--check 옵션은 tar.gz 인자와 함께 사용할 수 없습니다."
            inspect_current_env
            exit 0 ;;
    esac

    [[ -n "$TARBALL" ]] || { print_help; error_exit "tar.gz 파일 경로를 지정하세요."; }

    require_root
    inspect_current_env

    validate_archive "$TARBALL"
    if [[ -n "$SHA256_EXPECTED" ]]; then
        verify_sha256 "$TARBALL" "$SHA256_EXPECTED"
    else
        log_warn "SHA-256 체크섬이 제공되지 않았습니다. 무결성 검증 없이 진행합니다."
    fi

    extract_archive "$TARBALL"
    identify_new_jdk
    check_architecture
    compare_and_gate_version
    check_running_java_processes

    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_summary
        exit 0
    fi

    install_new_jdk
    switch_symlink

    if verify_after_switch; then
        final_report
    else
        log_error "심볼릭 링크 전환 후 검증에 실패했습니다."
        rollback_symlink
    fi
}

main "$@"
