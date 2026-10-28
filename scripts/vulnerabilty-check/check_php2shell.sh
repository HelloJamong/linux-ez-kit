#!/bin/bash

# PHP2Shell 취약점 점검 스크립트
# CVE-2026-109618 (OOM 처리 메모리 손상), CVE-2026-109619 (upload progress Use-After-Free)
# 순수 bash로 작동 (설치된 php / php-fpm 바이너리 버전만 조회)

CVES="CVE-2026-109618 CVE-2026-109619"
# 지원 라인별 수정 버전 (그 외는 EOL → 배포판 백포트 여부로만 판단)
declare -A FIXED_PHP=( [8.5]="8.5.12" [8.4]="8.4.27" [8.3]="8.3.36" [8.2]="8.2.35" )
SEARCH_PATHS="/usr /opt"

echo "=================================================="
echo "PHP2Shell 취약점 점검 스크립트"
echo "$CVES"
echo "점검 시작 시간: $(date)"
echo "=================================================="
echo ""

# 결과 저장 파일
REPORT_FILE="php2shell_check_report_$(date +%Y%m%d_%H%M%S).txt"

# 로그 함수
log_result() {
    echo "$1" | tee -a "$REPORT_FILE"
}

# 버전 비교: $1 >= $2 이면 0
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# 패키지 changelog 에 모든 CVE 가 있는지 확인 (RHEL/Ubuntu 백포트 패치 대응)
# $1: 파일 경로, 결과 패키지명은 PKG_NAME 에 저장
pkg_has_cves() {
    local file="$1" changelog="" cve
    PKG_NAME=""
    if command -v rpm >/dev/null 2>&1 && PKG_NAME=$(rpm -qf "$file" 2>/dev/null); then
        changelog=$(rpm -q --changelog "$PKG_NAME" 2>/dev/null)
    else
        PKG_NAME=""
        command -v dpkg >/dev/null 2>&1 && PKG_NAME=$(dpkg -S "$file" 2>/dev/null | head -1 | cut -d: -f1)
        [ -n "$PKG_NAME" ] && changelog=$(zcat "/usr/share/doc/$PKG_NAME/changelog.Debian.gz" 2>/dev/null)
    fi
    [ -z "$changelog" ] && return 1
    for cve in $CVES; do
        grep -q "$cve" <<< "$changelog" || return 1
    done
}

log_result "=================================================="
log_result "PHP2Shell 취약점 점검 보고서"
log_result "점검 시간: $(date)"
log_result "호스트명: $(hostname)"
log_result "=================================================="
log_result ""

VULNERABLE_COUNT=0
SAFE_COUNT=0

# 1. php / php-fpm 바이너리 검색
log_result "[1] PHP 바이너리 검색 (php, php-fpm, php8.x, remi /opt/remi 포함)"
log_result "검색 경로: PATH, $SEARCH_PATHS"
log_result ""

PHP_BINS=$( {
    command -v php 2>/dev/null
    command -v php-fpm 2>/dev/null
    find $SEARCH_PATHS -type f -perm -u+x \
        -regextype posix-extended -regex '.*/(php|php-fpm)[0-9.]*' 2>/dev/null
} | while read -r f; do readlink -f "$f"; done | sort -u)

if [ -z "$PHP_BINS" ]; then
    log_result "✓ PHP 바이너리를 찾을 수 없습니다."
else
    NUM=0
    while IFS= read -r BIN; do
        NUM=$((NUM + 1))
        log_result "------------------------------------------------"
        log_result "PHP #$NUM: $BIN"
        log_result "------------------------------------------------"

        PHP_VER=$(timeout 10 "$BIN" -v 2>/dev/null | head -1 | sed -n 's/^PHP \([0-9][0-9.]*\).*/\1/p')

        if [ -z "$PHP_VER" ]; then
            log_result "✗ 버전을 확인할 수 없습니다. (실행 실패)"
            log_result ""
            continue
        fi

        log_result "PHP 버전: $PHP_VER"

        MINOR=$(echo "$PHP_VER" | cut -d. -f1,2)
        FIXED=${FIXED_PHP[$MINOR]}

        if pkg_has_cves "$BIN"; then
            log_result "✓ 패키지($PKG_NAME) changelog 에 패치가 확인됩니다. (백포트)"
            SAFE_COUNT=$((SAFE_COUNT + 1))
        elif [ -n "$FIXED" ] && version_ge "$PHP_VER" "$FIXED"; then
            log_result "✓ 안전한 버전입니다. (기준: $FIXED 이상)"
            SAFE_COUNT=$((SAFE_COUNT + 1))
        elif [ -n "$FIXED" ]; then
            log_result "🔴 취약한 버전입니다!"
            log_result "  권장 조치: $FIXED 이상으로 업데이트"
            VULNERABLE_COUNT=$((VULNERABLE_COUNT + 1))
        else
            log_result "🔴 취약한 버전입니다! (PHP $MINOR 는 공식 패치 릴리스가 없습니다)"
            log_result "  권장 조치: 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 이상으로 업그레이드"
            log_result "            또는 배포판 보안 업데이트(백포트) 적용"
            VULNERABLE_COUNT=$((VULNERABLE_COUNT + 1))
        fi
        [ -n "$PKG_NAME" ] && log_result "  설치 패키지: $PKG_NAME"

        # 임시 완화 설정 확인 (패치 전 적용 여부 참고용)
        # ponytail: CLI/FPM 기본 php.ini 기준, FPM pool 별 php_admin_value 재정의는 미반영
        INI=$(timeout 10 "$BIN" -i 2>/dev/null)
        UPLOAD_PROGRESS=$(grep -m1 '^session.upload_progress.enabled' <<< "$INI" | awk -F'=> ' '{print $NF}')
        MEMORY_LIMIT=$(grep -m1 '^memory_limit' <<< "$INI" | awk -F'=> ' '{print $NF}')
        POST_MAX=$(grep -m1 '^post_max_size' <<< "$INI" | awk -F'=> ' '{print $NF}')
        log_result "  완화 설정 현황:"
        log_result "    session.upload_progress.enabled = ${UPLOAD_PROGRESS:-확인 불가} (권장: Off, CVE-2026-109619)"
        log_result "    memory_limit = ${MEMORY_LIMIT:-확인 불가} (CVE-2026-109618 완화 시 -1)"
        log_result "    post_max_size = ${POST_MAX:-확인 불가} (CVE-2026-109618 완화 시 축소)"
        log_result ""
    done <<< "$PHP_BINS"
fi
log_result ""

# 2. 최종 요약
log_result "=================================================="
log_result "점검 결과 요약"
log_result "=================================================="
log_result "취약 항목: $VULNERABLE_COUNT"
log_result "안전 항목: $SAFE_COUNT"
log_result ""

if [ $VULNERABLE_COUNT -gt 0 ]; then
    log_result "⚠️  경고: 취약점이 발견되었습니다! (실제 공격이 확인된 취약점입니다)"
    log_result ""
    log_result "조치 방법:"
    log_result "1. PHP 를 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 이상으로 업데이트"
    log_result "2. 즉시 패치가 어려우면 php.ini 에서 session.upload_progress.enabled = Off"
    log_result "3. php-fpm / httpd 서비스 재시작"
    log_result ""
    log_result "참고:"
    log_result "- https://nvd.nist.gov/vuln/detail/CVE-2026-109618"
    log_result "- https://nvd.nist.gov/vuln/detail/CVE-2026-109619"
    log_result "- https://unit42.paloaltonetworks.com/cve-2026-109618-cve-2026-109619/"
else
    log_result "✓ $CVES 취약점의 영향이 없습니다."
fi

log_result ""
log_result "보고서가 저장되었습니다: $REPORT_FILE"
log_result "점검 종료 시간: $(date)"
log_result "=================================================="

echo ""
echo "보고서 파일: $REPORT_FILE"

[ $VULNERABLE_COUNT -eq 0 ]
