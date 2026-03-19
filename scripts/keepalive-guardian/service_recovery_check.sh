#!/bin/bash

################################################################################
# Keepalive Guardian - MASTER 승격 알림 스크립트
#
# 위치: /usr/local/bin/service_recovery_check.sh
# 목적: keepalived notify_master 훅 — VRRP MASTER 전환 시 자동 실행
# 호출: keepalived notify_master (이 서버가 MASTER로 승격될 때)
#
# 동작:
#   1. MASTER 승격 이벤트 로그 기록
#   2. Failback 완료 시 안정화 타이머 파일 정리
#   3. 승격 직후 서비스 상태 즉시 검증 및 로그
################################################################################

CONFIG_FILE="/etc/keepalived/service_check.conf"
TIMER_FILE="/tmp/keepalive_recovery_timer"
STATE_FILE="/tmp/keepalive_health_state"

# ------------------------------------------------------------------------------
# 설정 파일 로드
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [FAIL] - 설정 파일 없음: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# ------------------------------------------------------------------------------
# 로그 함수
# ------------------------------------------------------------------------------
log_msg() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [${level}] - ${message}" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# 포트 체크 (즉시 검증용 - 결과 반환만)
# ------------------------------------------------------------------------------
verify_ports() {
    [ "${#PORT_LIST[@]}" -eq 0 ] && return 0

    local failed=()
    for port in "${PORT_LIST[@]}"; do
        if ! timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            failed+=("$port")
        fi
    done

    if [ "${#failed[@]}" -gt 0 ]; then
        log_msg "WARN" "MASTER 승격 후 포트 미응답: ${failed[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 프로세스 체크 (즉시 검증용 - 결과 반환만)
# ------------------------------------------------------------------------------
verify_processes() {
    [ "${#PROCESS_LIST[@]}" -eq 0 ] && return 0

    local failed=()
    for proc in "${PROCESS_LIST[@]}"; do
        if ! pgrep -f "$proc" >/dev/null 2>&1; then
            failed+=("$proc")
        fi
    done

    if [ "${#failed[@]}" -gt 0 ]; then
        log_msg "WARN" "MASTER 승격 후 프로세스 미실행: ${failed[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 메인
# ------------------------------------------------------------------------------
main() {
    local hostname host_ip
    hostname=$(hostname 2>/dev/null)
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # MASTER 승격 이벤트 로그
    log_msg "INFO" "══════════════════════════════════════════════════════════"
    log_msg "INFO" "VRRP MASTER 승격: ${hostname} (${host_ip})"
    log_msg "INFO" "══════════════════════════════════════════════════════════"

    # Failback 완료 처리 — 안정화 타이머 파일 정리
    if [ -f "$TIMER_FILE" ]; then
        local start_time elapsed
        start_time=$(cat "$TIMER_FILE" 2>/dev/null)
        if [ -n "$start_time" ]; then
            elapsed=$(( $(date +%s) - start_time ))
            log_msg "RECOVERY" "Failback 안정화 완료 — 총 ${elapsed}초 경과 후 MASTER 복귀"
        fi
        rm -f "$TIMER_FILE"
    fi

    # 상태 파일 정상화 (헬스체크 스크립트와 상태 동기화)
    echo "ok" > "$STATE_FILE"

    # 승격 직후 서비스 상태 즉시 검증
    log_msg "INFO" "MASTER 승격 후 서비스 상태 즉시 점검"

    local all_ok=true
    verify_ports     || all_ok=false
    verify_processes || all_ok=false

    if $all_ok; then
        log_msg "SUCCESS" "MASTER 승격 후 서비스 상태 정상 — HA 전환 완료"
    else
        log_msg "WARN" "MASTER 승격 후 일부 서비스 비정상 감지"
        log_msg "WARN" "keepalived track_script 가 자동으로 재판정합니다"
        log_msg "WARN" "즉시 조치 필요: tail -f ${LOG_FILE}"
    fi
}

main
exit 0
