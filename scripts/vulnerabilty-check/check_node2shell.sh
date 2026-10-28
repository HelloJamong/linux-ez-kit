#!/bin/bash

# Node2Shell 취약점 점검 스크립트
# CVE-2026-111497 (Node.js 내장 Brotli 디코더 Out-of-bounds Write → RCE)
# 순수 bash로 작동 (설치된 node 바이너리 버전만 조회)

CVE="CVE-2026-111497"
# 지원 라인별 수정 버전 (그 외 major 는 EOL → 패치 없음)
declare -A FIXED_NODE=( [22]="22.23.4" [24]="24.22.1" [26]="26.12.1" )
# 시스템 brotli 라이브러리 수정 버전 (major.minor 별)
declare -A FIXED_BROTLI=( [1.0]="1.0.10" [1.1]="1.1.1" [1.2]="1.2.1" )
SEARCH_PATHS="/usr /opt /home /root /srv /var/www"

echo "=================================================="
echo "Node2Shell 취약점 점검 스크립트"
echo "$CVE"
echo "점검 시작 시간: $(date)"
echo "=================================================="
echo ""

# 결과 저장 파일
REPORT_FILE="node2shell_check_report_$(date +%Y%m%d_%H%M%S).txt"

# 로그 함수
log_result() {
    echo "$1" | tee -a "$REPORT_FILE"
}

# 버전 비교: $1 >= $2 이면 0
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# 패키지 changelog 에 CVE 가 있는지 확인 (RHEL/Ubuntu 백포트 패치 대응)
# $1: 파일 경로, 결과 패키지명은 PKG_NAME 에 저장
pkg_has_cve() {
    local file="$1"
    PKG_NAME=""
    if command -v rpm >/dev/null 2>&1 && PKG_NAME=$(rpm -qf "$file" 2>/dev/null); then
        rpm -q --changelog "$PKG_NAME" 2>/dev/null | grep -q "$CVE"
        return
    fi
    PKG_NAME=""
    command -v dpkg >/dev/null 2>&1 && PKG_NAME=$(dpkg -S "$file" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$PKG_NAME" ]; then
        zcat "/usr/share/doc/$PKG_NAME/changelog.Debian.gz" 2>/dev/null | grep -q "$CVE"
        return
    fi
    return 1
}

log_result "=================================================="
log_result "Node2Shell 취약점 점검 보고서"
log_result "점검 시간: $(date)"
log_result "호스트명: $(hostname)"
log_result "=================================================="
log_result ""

VULNERABLE_COUNT=0
SAFE_COUNT=0

# 1. node 바이너리 검색
log_result "[1] Node.js 바이너리 검색"
log_result "검색 경로: PATH, $SEARCH_PATHS"
log_result ""

NODE_BINS=$( {
    command -v node 2>/dev/null
    command -v nodejs 2>/dev/null
    # ponytail: node_modules 하위는 제외 (프로젝트 의존성은 실행 바이너리가 아님)
    find $SEARCH_PATHS -path '*/node_modules' -prune -o \
        -type f \( -name node -o -name nodejs \) -perm -u+x -print 2>/dev/null
} | while read -r f; do readlink -f "$f"; done | sort -u)

if [ -z "$NODE_BINS" ]; then
    log_result "✓ Node.js 바이너리를 찾을 수 없습니다."
else
    NUM=0
    while IFS= read -r BIN; do
        NUM=$((NUM + 1))
        log_result "------------------------------------------------"
        log_result "Node.js #$NUM: $BIN"
        log_result "------------------------------------------------"

        INFO=$(timeout 10 "$BIN" -p 'process.version.slice(1)+" "+(process.versions.brotli||"")' 2>/dev/null)
        NODE_VER=${INFO%% *}
        BROTLI_VER=${INFO#* }

        if [ -z "$NODE_VER" ]; then
            log_result "✗ 버전을 확인할 수 없습니다. (실행 실패)"
            log_result ""
            continue
        fi

        log_result "Node.js 버전: $NODE_VER"
        log_result "내장 Brotli 버전: ${BROTLI_VER:-없음}"

        MAJOR=${NODE_VER%%.*}
        FIXED=${FIXED_NODE[$MAJOR]}

        if [ -z "$BROTLI_VER" ]; then
            log_result "✓ Brotli 미포함 버전으로 영향이 없습니다."
            SAFE_COUNT=$((SAFE_COUNT + 1))
        elif pkg_has_cve "$BIN"; then
            log_result "✓ 패키지($PKG_NAME) changelog 에 $CVE 패치가 확인됩니다. (백포트)"
            SAFE_COUNT=$((SAFE_COUNT + 1))
        elif [ -n "$FIXED" ] && version_ge "$NODE_VER" "$FIXED"; then
            log_result "✓ 안전한 버전입니다. (기준: $FIXED 이상)"
            SAFE_COUNT=$((SAFE_COUNT + 1))
        elif [ -n "$FIXED" ]; then
            log_result "🔴 취약한 버전입니다!"
            log_result "  권장 조치: $FIXED 이상으로 업데이트"
            VULNERABLE_COUNT=$((VULNERABLE_COUNT + 1))
        else
            log_result "🔴 취약한 버전입니다! (Node.js $MAJOR.x 는 EOL 로 패치가 제공되지 않습니다)"
            log_result "  권장 조치: 22.23.4 / 24.22.1 / 26.12.1 이상 지원 버전으로 업그레이드"
            VULNERABLE_COUNT=$((VULNERABLE_COUNT + 1))
        fi
        [ -n "$PKG_NAME" ] && log_result "  설치 패키지: $PKG_NAME"
        log_result ""
    done <<< "$NODE_BINS"
fi
log_result ""

# 2. 시스템 brotli 라이브러리 (Python brotli, 기타 애플리케이션이 공유)
log_result "[2] 시스템 Brotli 라이브러리 점검"
log_result ""

BROTLI_LIB=$(ls /usr/lib64/libbrotlidec.so.* /usr/lib/libbrotlidec.so.* \
    /usr/lib/*-linux-gnu/libbrotlidec.so.* 2>/dev/null | head -1)

if [ -z "$BROTLI_LIB" ]; then
    log_result "✓ 시스템 Brotli 라이브러리가 설치되어 있지 않습니다."
else
    BROTLI_LIB=$(readlink -f "$BROTLI_LIB")
    LIB_VER=$(basename "$BROTLI_LIB" | sed 's/.*\.so\.//')
    log_result "라이브러리: $BROTLI_LIB"
    log_result "버전: $LIB_VER"

    LIB_FIXED=${FIXED_BROTLI[${LIB_VER%.*}]}
    if pkg_has_cve "$BROTLI_LIB"; then
        log_result "✓ 패키지($PKG_NAME) changelog 에 $CVE 패치가 확인됩니다. (백포트)"
        SAFE_COUNT=$((SAFE_COUNT + 1))
    elif ! version_ge "$LIB_VER" "1.0.3"; then
        log_result "✓ 영향 범위(1.0.3 ~ 1.2.0) 이전 버전입니다."
        SAFE_COUNT=$((SAFE_COUNT + 1))
    elif [ -n "$LIB_FIXED" ] && version_ge "$LIB_VER" "$LIB_FIXED"; then
        log_result "✓ 안전한 버전입니다. (기준: $LIB_FIXED 이상)"
        SAFE_COUNT=$((SAFE_COUNT + 1))
    elif [ -z "$LIB_FIXED" ] && version_ge "$LIB_VER" "1.2.1"; then
        log_result "✓ 안전한 버전입니다."
        SAFE_COUNT=$((SAFE_COUNT + 1))
    else
        log_result "🔴 취약한 버전일 수 있습니다! (changelog 에서 $CVE 패치 미확인)"
        log_result "  권장 조치: OS 패키지 업데이트 (dnf update brotli / apt upgrade libbrotli1)"
        VULNERABLE_COUNT=$((VULNERABLE_COUNT + 1))
    fi
    [ -n "$PKG_NAME" ] && log_result "  설치 패키지: $PKG_NAME"
fi
log_result ""

# 3. 최종 요약
log_result "=================================================="
log_result "점검 결과 요약"
log_result "=================================================="
log_result "취약 항목: $VULNERABLE_COUNT"
log_result "안전 항목: $SAFE_COUNT"
log_result ""

if [ $VULNERABLE_COUNT -gt 0 ]; then
    log_result "⚠️  경고: 취약점이 발견되었습니다!"
    log_result ""
    log_result "조치 방법:"
    log_result "1. Node.js 를 22.23.4 / 24.22.1 / 26.12.1 이상으로 업데이트"
    log_result "2. EOL 버전(20.x, 23.x 등)은 지원 버전으로 업그레이드"
    log_result "3. 시스템 brotli 패키지 업데이트"
    log_result "4. Node.js 기반 서비스 재시작"
    log_result ""
    log_result "참고:"
    log_result "- https://nvd.nist.gov/vuln/detail/$CVE"
    log_result "- https://www.akamai.com/blog/security-research/inside-node2shell-closer-look-cve-2026-111497"
else
    log_result "✓ $CVE 취약점의 영향이 없습니다."
fi

log_result ""
log_result "보고서가 저장되었습니다: $REPORT_FILE"
log_result "점검 종료 시간: $(date)"
log_result "=================================================="

echo ""
echo "보고서 파일: $REPORT_FILE"

[ $VULNERABLE_COUNT -eq 0 ]
