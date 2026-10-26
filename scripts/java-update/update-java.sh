#!/bin/bash
#
# update-java.sh
# tar.gz로 수동 설치된 JDK(OpenJDK, Temurin 등)를 Amazon Corretto 21로 마이그레이션하거나,
# 이미 마이그레이션된 Corretto 21을 안전하게 업데이트합니다.
# 대상: Rocky Linux 9 (RHEL 계열)
#
# 동작 모드 (현재 환경에서 자동 판별):
#   update  : /etc/profile.d/java.sh 의 JAVA_HOME 이 /usr/lib/jvm/java-21 (Corretto) -> 링크만 교체
#   migrate : 그 외 tar.gz JDK -> Corretto 설치 + java-21 링크 생성 + java.sh 백업 후 재작성
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
SYMLINK_PATH="${JVM_DIR}/java-21"
PROFILE_SCRIPT="/etc/profile.d/java.sh"
ALT_JAVA_LINK="/etc/alternatives/java"
BACKUP_ROOT="/backup/java-update"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ==================== 전역 상태 ====================
MODE="update"
DRY_RUN=0
FORCE=0
SHA256_EXPECTED=""
TARBALL=""

TMP_DIR=""
STAGING_DIR=""
PREV_SYMLINK_TARGET=""
BACKUP_DIR=""

INSTALL_TYPE=""          # update | migrate
CUR_JAVA_HOME=""
CUR_SYMLINK_TARGET=""
CUR_JDK_VENDOR=""
CUR_JDK_VERSION=""
CUR_JDK_MAJOR=""
NEW_JDK_NAME=""
NEW_JDK_SRC=""
NEW_JDK_PATH=""
NEW_JDK_VERSION=""
NEW_JAVA_VERSION=""
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
  --check           변경 없이 현재 Java 환경만 점검 (update/migrate 모드 판별)
  --dry-run         실제 변경 없이 검증(아카이브/버전/아키텍처)까지만 수행
  --force           신규 버전이 현재와 동일할 때도 재설치 허용 (update 모드, 다운그레이드는 허용하지 않음)
  --sha256 <hash>   설치 전 tar.gz 파일의 SHA-256 값을 검증
  --help            이 도움말 출력

현재 JDK 위치는 /etc/profile.d/java.sh -> 환경변수 JAVA_HOME -> PATH의 java 순서로 찾습니다.
찾지 못하면 JAVA_HOME을 직접 지정하세요: sudo JAVA_HOME=/opt/jdk-17 ./update-java.sh ...

예:
  ./update-java.sh --check
  sudo ./update-java.sh --dry-run amazon-corretto-21.0.9.10.1-linux-x64.tar.gz
  sudo ./update-java.sh --sha256 <hash> amazon-corretto-21.0.9.10.1-linux-x64.tar.gz
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
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

# JAVA_VERSION 값에서 메이저 버전 추출 (1.8.0_392 -> 8, 17.0.9 -> 17)
major_of() {
    local v="$1"
    [[ "$v" == 1.* ]] && v="${v#1.}"
    echo "${v%%[._+-]*}"
}

# ==================== 현재 환경 점검 ====================
inspect_current_env() {
    log_info "=== 현재 Java 환경 점검 ==="

    if command -v java &>/dev/null; then
        log_info "command -v java: $(command -v java)"
        log_info "readlink -f: $(readlink -f "$(command -v java)")"
    else
        log_warn "PATH에서 java 명령어를 찾을 수 없습니다 (sudo 환경에서는 정상일 수 있음)."
    fi

    local profile_java_home=""
    if [[ -f "$PROFILE_SCRIPT" ]]; then
        profile_java_home=$(grep -E '^export[[:space:]]+JAVA_HOME=' "$PROFILE_SCRIPT" | head -1 | sed -E 's/^export[[:space:]]+JAVA_HOME=//' | tr -d '"'"'"'' || true)
        log_info "JAVA_HOME (${PROFILE_SCRIPT}): ${profile_java_home:-(없음)}"
    else
        log_info "${PROFILE_SCRIPT} 파일이 없습니다 (migrate 시 새로 생성)."
    fi

    if [[ "$profile_java_home" == "$SYMLINK_PATH" ]]; then
        INSTALL_TYPE="update"
        [[ -L "$SYMLINK_PATH" ]] || error_exit "${SYMLINK_PATH} 가 심볼릭 링크가 아닙니다. 예상하지 못한 구조입니다."
        CUR_JAVA_HOME="$SYMLINK_PATH"
    else
        INSTALL_TYPE="migrate"
        CUR_JAVA_HOME="${profile_java_home:-${JAVA_HOME:-}}"
        if [[ -z "$CUR_JAVA_HOME" ]] && command -v java &>/dev/null; then
            CUR_JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
        fi
        [[ -n "$CUR_JAVA_HOME" ]] || \
            error_exit "현재 JDK 위치를 찾을 수 없습니다. JAVA_HOME을 지정해 실행하세요: sudo JAVA_HOME=/path/to/jdk $0 ..."
        # RHEL의 java-21-openjdk RPM도 /usr/lib/jvm/java-21 을 alternatives 링크로 사용하므로 덮어쓰지 않는다
        [[ ! -e "$SYMLINK_PATH" && ! -L "$SYMLINK_PATH" ]] || \
            error_exit "${SYMLINK_PATH} 가 이미 존재합니다 (RPM alternatives 등). 덮어쓰지 않습니다: $(ls -ld "$SYMLINK_PATH")"
    fi
    log_info "동작 모드: ${INSTALL_TYPE}"

    CUR_SYMLINK_TARGET=$(readlink -f "$CUR_JAVA_HOME")
    log_info "${CUR_JAVA_HOME} -> ${CUR_SYMLINK_TARGET}"
    [[ -d "$CUR_SYMLINK_TARGET" && -x "${CUR_SYMLINK_TARGET}/bin/java" ]] || \
        error_exit "현재 JDK 디렉터리에 bin/java가 없습니다: ${CUR_SYMLINK_TARGET}"

    if rpm -qf "$CUR_SYMLINK_TARGET" &>/dev/null; then
        error_exit "현재 JDK가 RPM 패키지로 관리되고 있습니다. 이 스크립트는 tar.gz 수동 설치 환경만 지원합니다."
    fi
    log_ok "RPM 비관리 설치 확인됨 (tar.gz 수동 설치)"

    local release_file="${CUR_SYMLINK_TARGET}/release"
    [[ -f "$release_file" ]] || error_exit "release 파일을 찾을 수 없습니다: ${release_file}"
    local implementor implementor_version java_version
    implementor=$(get_release_field "$release_file" IMPLEMENTOR)
    implementor_version=$(get_release_field "$release_file" IMPLEMENTOR_VERSION)
    java_version=$(get_release_field "$release_file" JAVA_VERSION)
    [[ -n "$java_version" ]] || error_exit "release 파일에 JAVA_VERSION 이 없습니다: ${release_file}"
    CUR_JDK_VENDOR="${implementor:-unknown}"
    CUR_JDK_MAJOR=$(major_of "$java_version")

    if [[ "$INSTALL_TYPE" == "update" ]]; then
        [[ "$implementor" == *"Amazon"* && "$implementor_version" == Corretto-21.* ]] || \
            error_exit "${SYMLINK_PATH} 의 JDK가 Corretto 21이 아닙니다 (IMPLEMENTOR=${implementor}, IMPLEMENTOR_VERSION=${implementor_version})."
        CUR_JDK_VERSION="${implementor_version#Corretto-}"
    else
        CUR_JDK_VERSION="$java_version"
    fi

    log_info "Current JDK: ${CUR_SYMLINK_TARGET}"
    log_info "Current Java: ${CUR_JDK_VENDOR} ${CUR_JDK_VERSION} (major ${CUR_JDK_MAJOR})"
    log_ok "현재 Java 환경 검증 완료"
}

# 기존 JDK 경로를 직접 참조하는 설정 파일 탐색 (수정하지 않고 경고만)
warn_path_references() {
    local -a targets=(/etc/systemd/system /etc/sysconfig /etc/default /etc/environment
                      /etc/profile /etc/bashrc /etc/profile.d
                      /root/.bash_profile /root/.bashrc /home/*/.bash_profile /home/*/.bashrc /home/*/.profile)
    local refs
    refs=$(grep -rlsF -e "$CUR_JAVA_HOME" -e "$CUR_SYMLINK_TARGET" -- "${targets[@]}" 2>/dev/null \
           | grep -vxF "$PROFILE_SCRIPT" || true)
    [[ -n "$refs" ]] || { log_ok "기존 JDK 경로를 직접 참조하는 설정 파일 없음"; return 0; }

    log_warn "아래 파일이 기존 JDK 경로(${CUR_JAVA_HOME})를 직접 참조합니다. 마이그레이션 후에도 기존 JDK를 사용하므로 직접 수정하세요:"
    while read -r f; do log_warn "  ${f}"; done <<< "$refs"
}

# /usr/bin/java (alternatives) 가 기존 JDK를 직접 가리키는지 확인 (수정하지 않고 경고만)
# 다른 JDK(RPM Java 8 등)를 가리키거나 이미 java-21 링크를 가리키면 무관하므로 넘어간다
warn_alternatives() {
    local alt_target
    alt_target=$(readlink "$ALT_JAVA_LINK" 2>/dev/null || true)
    [[ -n "$alt_target" && "$alt_target" != "${SYMLINK_PATH}/bin/java" ]] || return 0
    [[ "$(readlink -f "$alt_target")" == "${CUR_SYMLINK_TARGET}/bin/java" ]] || return 0

    log_warn "/usr/bin/java (alternatives) 가 기존 JDK를 가리킵니다: ${alt_target}"
    log_warn "경로 없이 'java'로 실행하는 서비스(systemd 등)는 전환 후에도 기존 JDK를 사용합니다. 전환 후 아래 명령으로 변경하세요:"
    log_warn "  alternatives --install /usr/bin/java java ${SYMLINK_PATH}/bin/java 2100"
    log_warn "  alternatives --set java ${SYMLINK_PATH}/bin/java"
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
    NEW_JAVA_VERSION=$(get_release_field "$release_file" JAVA_VERSION)
    NEW_OS_ARCH=$(get_release_field "$release_file" OS_ARCH)

    [[ "$implementor" == *"Amazon"* ]] || error_exit "Amazon Corretto 빌드가 아닙니다 (IMPLEMENTOR=${implementor})."
    [[ "$implementor_version" == Corretto-21.* ]] || error_exit "Corretto JDK 21 빌드가 아닙니다 (IMPLEMENTOR_VERSION=${implementor_version})."

    NEW_JDK_VERSION="${implementor_version#Corretto-}"
    log_info "New Java version: Corretto ${NEW_JDK_VERSION} (${NEW_OS_ARCH})"
}

check_architecture() {
    local sys_arch
    sys_arch=$(uname -m)
    [[ "$NEW_OS_ARCH" == "$sys_arch" ]] || \
        error_exit "아키텍처 불일치: archive=${NEW_OS_ARCH}, system=${sys_arch}"
}

# 버전 비교: "+" 를 "." 로 바꿔 sort -V 로 비교
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
    if [[ "$INSTALL_TYPE" == "migrate" ]]; then
        # 벤더마다 빌드 번호 체계가 달라 공통 필드인 JAVA_VERSION(예: 21.0.9)으로 비교한다
        # 재빌드판(예: Temurin 21.0.12.1)은 같은 업데이트로 보도록 앞 세 자리만 비교한다
        local cur_base new_base
        cur_base=$(cut -d. -f1-3 <<< "$CUR_JDK_VERSION")
        new_base=$(cut -d. -f1-3 <<< "$NEW_JAVA_VERSION")
        [[ "$(version_relation "$cur_base" "$new_base")" != "older" ]] || \
            error_exit "신규 JDK(${NEW_JAVA_VERSION})가 현재 JDK(${CUR_JDK_VERSION})보다 낮습니다. 다운그레이드는 지원하지 않습니다. 더 최신 Corretto를 사용하세요."
        if (( CUR_JDK_MAJOR < 21 )); then
            log_warn "메이저 버전 업그레이드입니다 (${CUR_JDK_MAJOR} -> 21). 애플리케이션 호환성을 테스트 환경에서 먼저 확인하세요."
        else
            log_info "동일 메이저 버전의 벤더 전환입니다 (${CUR_JDK_VENDOR} ${CUR_JDK_VERSION} -> Corretto ${NEW_JDK_VERSION})."
        fi
        return 0
    fi

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
    # -x: 프로세스 이름이 정확히 java 인 것만 (update-java.sh 자신 제외)
    procs=$(pgrep -ax java 2>/dev/null || true)
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
    log_info "동작 모드: ${INSTALL_TYPE}"
    log_info "현재: ${CUR_JDK_VENDOR} ${CUR_JDK_VERSION} (${CUR_SYMLINK_TARGET})"
    log_info "신규: Corretto ${NEW_JDK_VERSION}"
    log_info "설치 예정 경로: ${JVM_DIR}/${NEW_JDK_NAME}"
    log_info "변경 예정 심볼릭 링크: ${SYMLINK_PATH} -> ${JVM_DIR}/${NEW_JDK_NAME}"
    if [[ "$INSTALL_TYPE" == "migrate" ]]; then
        log_info "재작성 예정: ${PROFILE_SCRIPT} (JAVA_HOME=${SYMLINK_PATH}, 기존 파일은 ${BACKUP_ROOT}/backup_<타임스탬프>/ 에 백업)"
    fi
    log_ok "DRY-RUN 완료. 실제 변경 사항 없음."
}

confirm_migration() {
    local ans=""
    echo
    log_warn "JAVA_HOME을 ${CUR_JAVA_HOME} 에서 ${SYMLINK_PATH} (Corretto ${NEW_JDK_VERSION}) 로 전환합니다."
    read -r -p "계속하시겠습니까? [y/N] " ans || true
    [[ "$ans" == [yY] ]] || error_exit "사용자가 취소했습니다. 변경 사항 없음."
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

# --- update 모드: 링크 교체 ---
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

# --- migrate 모드: 백업 -> 링크 생성 -> java.sh 재작성 ---
backup_profile() {
    BACKUP_DIR="${BACKUP_ROOT}/backup_${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    local restore_profile_cmd
    if [[ -f "$PROFILE_SCRIPT" ]]; then
        cp -a "$PROFILE_SCRIPT" "${BACKUP_DIR}/java.sh"
        restore_profile_cmd="cp -a \"${BACKUP_DIR}/java.sh\" \"${PROFILE_SCRIPT}\""
    else
        restore_profile_cmd="rm -f \"${PROFILE_SCRIPT}\""
    fi

    cat > "${BACKUP_DIR}/restore.sh" <<EOF
#!/bin/bash
# update-java.sh Corretto 마이그레이션 복구 스크립트 (생성: ${TIMESTAMP})
# 이전 JAVA_HOME : ${CUR_JAVA_HOME} -> ${CUR_SYMLINK_TARGET}
# 신규 JDK       : ${NEW_JDK_PATH} (복구 후에도 삭제되지 않음, 필요 시 수동 삭제)
set -e
${restore_profile_cmd}
rm -f "${SYMLINK_PATH}"
echo "복구 완료. 재접속 또는 'source ${PROFILE_SCRIPT}' 후 java -version 으로 확인하세요."
EOF
    chmod 700 "${BACKUP_DIR}/restore.sh"
    log_ok "백업 완료: ${BACKUP_DIR} (복구: ${BACKUP_DIR}/restore.sh)"
}

# if 문맥에서 호출되어 set -e 가 꺼지므로 각 단계에서 명시적으로 실패를 반환한다
switch_to_corretto() {
    local tmp_link="${SYMLINK_PATH}.new.$$" tmp_profile="${PROFILE_SCRIPT}.new.$$"

    ln -s "$NEW_JDK_PATH" "$tmp_link" || return 1
    mv -T "$tmp_link" "$SYMLINK_PATH" || return 1
    log_ok "${SYMLINK_PATH} -> ${NEW_JDK_PATH}"

    cat > "$tmp_profile" <<EOF || return 1
# Amazon Corretto 21 (update-java.sh 에서 생성: ${TIMESTAMP})
export JAVA_HOME=${SYMLINK_PATH}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    chmod 644 "$tmp_profile" || return 1
    mv -T "$tmp_profile" "$PROFILE_SCRIPT" || return 1
    log_ok "${PROFILE_SCRIPT} 갱신: JAVA_HOME=${SYMLINK_PATH}"
}

verify_after_migrate() {
    # shellcheck disable=SC1090
    ( source "$PROFILE_SCRIPT"
      [[ "$JAVA_HOME" == "$SYMLINK_PATH" ]] &&
      [[ "$(readlink -f "$(command -v java)")" == "${NEW_JDK_PATH}/bin/java" ]] &&
      java -version && javac -version ) &>/dev/null || return 1
    [[ "$(readlink -f "$SYMLINK_PATH")" == "$NEW_JDK_PATH" ]] || return 1
}

rollback_migration() {
    log_warn "마이그레이션을 롤백합니다: ${BACKUP_DIR}/restore.sh"
    if bash "${BACKUP_DIR}/restore.sh" && [[ ! -e "$SYMLINK_PATH" ]]; then
        log_ok "롤백 성공: ${PROFILE_SCRIPT} 복원, ${SYMLINK_PATH} 제거 (신규 JDK ${NEW_JDK_PATH} 는 남아 있음)"
        exit 1
    else
        log_error "롤백 실패. 수동 조치가 필요합니다. 백업: ${BACKUP_DIR}"
        exit 2
    fi
}

final_report() {
    echo
    log_ok "Java ${INSTALL_TYPE} completed successfully."
    echo
    echo "Previous JDK:"
    echo "  ${CUR_SYMLINK_TARGET} (${CUR_JDK_VENDOR} ${CUR_JDK_VERSION})"
    echo
    echo "Current JDK:"
    echo "  ${NEW_JDK_PATH} (Corretto ${NEW_JDK_VERSION})"
    echo
    if [[ "$INSTALL_TYPE" == "migrate" ]]; then
        echo "백업/복구:"
        echo "  ${BACKUP_DIR}/restore.sh"
        echo
        log_warn "JAVA_HOME 변경은 새 로그인 세션부터 적용됩니다. 현재 쉘은 'source ${PROFILE_SCRIPT}; hash -r' 또는 재접속하세요."
        log_warn "systemd 서비스는 /etc/profile.d 를 읽지 않습니다. 서비스 설정의 JDK 경로를 ${SYMLINK_PATH} 로 바꾸고 재시작하세요."
        warn_path_references
    else
        log_warn "현재 로그인된 다른 쉘은 command hash 캐시로 인해 변경 사항이 즉시 반영되지 않을 수 있습니다."
        log_warn "필요 시 해당 쉘에서 'hash -r' 실행 또는 재접속하세요."
    fi
    warn_alternatives
    # shellcheck disable=SC1090
    log_info "java -version: $(source "$PROFILE_SCRIPT"; java -version 2>&1 | head -1)"
    log_info "readlink -f: $(source "$PROFILE_SCRIPT"; readlink -f "$(command -v java)")"
    echo
    echo "기존 JDK는 자동 삭제되지 않습니다. 충분히 검증 후 필요 시 수동으로 삭제하세요:"
    echo "  rm -rf \"${CUR_SYMLINK_TARGET}\""
}

# ==================== 메인 ====================
main() {
    parse_args "$@"

    case "$MODE" in
        help) print_help; exit 0 ;;
        check)
            [[ -z "$TARBALL" ]] || error_exit "--check 옵션은 tar.gz 인자와 함께 사용할 수 없습니다."
            inspect_current_env
            [[ "$INSTALL_TYPE" == "migrate" ]] && warn_path_references
            warn_alternatives
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
    [[ "$INSTALL_TYPE" == "migrate" ]] && warn_path_references
    warn_alternatives

    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_summary
        exit 0
    fi

    [[ "$INSTALL_TYPE" == "migrate" ]] && confirm_migration

    install_new_jdk

    if [[ "$INSTALL_TYPE" == "migrate" ]]; then
        backup_profile
        if switch_to_corretto && verify_after_migrate; then
            final_report
        else
            log_error "Corretto 전환 또는 전환 후 검증에 실패했습니다."
            rollback_migration
        fi
    else
        switch_symlink
        if verify_after_switch; then
            final_report
        else
            log_error "심볼릭 링크 전환 후 검증에 실패했습니다."
            rollback_symlink
        fi
    fi
}

main "$@"
