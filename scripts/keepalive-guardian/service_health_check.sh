#!/bin/bash

################################################################################
# Keepalive Guardian - 서비스 헬스체크 스크립트
#
# 위치: /usr/local/bin/service_health_check.sh
# 목적: 포트 / 프로세스 / DB 복제 상태 종합 점검
# 반환: exit 0 (정상), exit 1 (장애 또는 Failback 안정화 대기 중)
# 호출: Keepalived track_script (HEALTH_CHECK_INTERVAL 주기)
#
# Failback 안정화 동작:
#   장애 복구 시 즉시 MASTER로 복귀하지 않고,
#   FAILBACK_DELAY 동안 연속 정상 상태 확인 후 우선순위 복구 허용
################################################################################

CONFIG_FILE="/etc/keepalived/service_check.conf"
TIMER_FILE="/tmp/keepalive_recovery_timer"  # Failback 안정화 타이머 시작 시각 저장
STATE_FILE="/tmp/keepalive_health_state"    # 이전 상태 추적 (ok / fail / recovering)

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
# 포트 체크
# TCP 연결 가능 여부 확인 (타임아웃 2초)
# ------------------------------------------------------------------------------
check_ports() {
    [ "${#PORT_LIST[@]}" -eq 0 ] && return 0

    local failed_ports=()
    for port in "${PORT_LIST[@]}"; do
        if ! timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            failed_ports+=("$port")
        fi
    done

    if [ "${#failed_ports[@]}" -gt 0 ]; then
        log_msg "FAIL" "포트 접근 불가: ${failed_ports[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 프로세스 체크
# pgrep -f <name> 으로 실행 여부 확인
# ------------------------------------------------------------------------------
check_processes() {
    [ "${#PROCESS_LIST[@]}" -eq 0 ] && return 0

    local failed_procs=()
    for proc in "${PROCESS_LIST[@]}"; do
        if ! pgrep -f "$proc" >/dev/null 2>&1; then
            failed_procs+=("$proc")
        fi
    done

    if [ "${#failed_procs[@]}" -gt 0 ]; then
        log_msg "FAIL" "프로세스 미실행: ${failed_procs[*]}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# DB 복제 상태 체크
# SHOW REPLICA STATUS\G 기반 IO/SQL 스레드 및 복제 지연 확인
# DB_ENABLED=no 이면 체크 건너뜀
# ------------------------------------------------------------------------------
check_db() {
    [ "$DB_ENABLED" != "yes" ] && return 0

    local result
    result=$(timeout 5 mysql \
        -h"$DB_HOST" \
        -P"$DB_PORT" \
        -u"$DB_USER" \
        -p"$DB_PASSWORD" \
        --connect-timeout=3 \
        -e "SHOW REPLICA STATUS\G" 2>/dev/null)

    if [ -z "$result" ]; then
        log_msg "FAIL" "DB 연결 실패 (${DB_HOST}:${DB_PORT})"
        return 1
    fi

    # IO Thread 확인
    if ! echo "$result" | grep -q "Replica_IO_Running: Yes"; then
        log_msg "FAIL" "DB 복제 IO 스레드 비정상"
        return 1
    fi

    # SQL Thread 확인
    if ! echo "$result" | grep -q "Replica_SQL_Running: Yes"; then
        log_msg "FAIL" "DB 복제 SQL 스레드 비정상"
        return 1
    fi

    # 복제 지연 확인
    local lag
    lag=$(echo "$result" | grep "Seconds_Behind_Source:" | awk '{print $2}')
    if [ -n "$lag" ] && [ "$lag" != "NULL" ]; then
        if [ "$lag" -gt "$REPLICATION_LAG_LIMIT" ] 2>/dev/null; then
            log_msg "FAIL" "DB 복제 지연 임계값 초과: ${lag}초 (허용: ${REPLICATION_LAG_LIMIT}초)"
            return 1
        fi
    fi

    return 0
}

# ------------------------------------------------------------------------------
# 메인
# ------------------------------------------------------------------------------
main() {
    local prev_state="ok"
    [ -f "$STATE_FILE" ] && prev_state=$(cat "$STATE_FILE" 2>/dev/null)

    # 모든 체크 수행 — 실패 항목 전체 로그 수집 후 판정
    local all_ok=true
    check_ports     || all_ok=false
    check_processes || all_ok=false
    check_db        || all_ok=false

    # ── 장애 상태 ──────────────────────────────────────────────────────────────
    if ! $all_ok; then
        if [ "$prev_state" == "recovering" ]; then
            log_msg "FAIL" "복구 대기 중 재장애 발생 — Failback 타이머 초기화"
        fi
        rm -f "$TIMER_FILE"
        echo "fail" > "$STATE_FILE"
        exit 1
    fi

    # ── 정상 상태 — Failback 안정화 처리 ──────────────────────────────────────

    # 장애 직후 첫 번째 정상 감지: 안정화 타이머 시작
    if [ "$prev_state" == "fail" ]; then
        date +%s > "$TIMER_FILE"
        echo "recovering" > "$STATE_FILE"
        log_msg "INFO" "서비스 복구 감지 — Failback 안정화 타이머 시작 (${FAILBACK_DELAY}초 필요)"
        exit 1  # 안정화 미완료 — 우선순위 복구 지연
    fi

    # 안정화 타이머 진행 중
    if [ -f "$TIMER_FILE" ]; then
        local start_time elapsed remaining
        start_time=$(cat "$TIMER_FILE" 2>/dev/null)
        elapsed=$(( $(date +%s) - start_time ))
        remaining=$(( FAILBACK_DELAY - elapsed ))

        if [ "$elapsed" -lt "$FAILBACK_DELAY" ]; then
            # 60초 간격으로만 로그 출력 (2초 주기 노이즈 방지)
            if [ $(( elapsed % 60 )) -lt 3 ]; then
                log_msg "INFO" "Failback 안정화 진행 중: ${elapsed}/${FAILBACK_DELAY}초 (${remaining}초 남음)"
            fi
            exit 1  # 안정화 미완료 — MASTER 복귀 지연
        fi

        # 안정화 완료 → MASTER 우선순위 복구 허용
        log_msg "RECOVERY" "Failback 안정화 완료 (${elapsed}초 경과) — MASTER 우선순위 복구 허용"
        rm -f "$TIMER_FILE"
        echo "ok" > "$STATE_FILE"
        exit 0
    fi

    # 완전 정상 상태
    if [ "$prev_state" != "ok" ]; then
        log_msg "SUCCESS" "모든 헬스체크 정상"
        echo "ok" > "$STATE_FILE"
    fi

    exit 0
}

main
