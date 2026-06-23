#!/bin/bash
# file_filter.sh - 설정 파일 기반 텍스트 파일 필터링 스크립트

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/filter.conf"
LOG_FILE="${SCRIPT_DIR}/filter_$(date +%Y%m%d_%H%M%S).log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()      { echo    "[$(date '+%Y-%m-%d %H:%M:%S')] $*"              | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}OK${NC}   $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC} $*" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERR${NC}  $*"   | tee -a "$LOG_FILE"; }

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$1"; }

[[ ! -f "$CONF_FILE" ]] && { log_err "설정 파일 없음: $CONF_FILE"; exit 1; }

# 단일 awk 조건 문자열 생성
# 사용법: build_cond <컬럼> <연산자> <값>
#   컬럼: 1,2,3... 또는 last
#   연산자: eq, neq, contains, not_contains, gte, lte
build_cond() {
    local col="$1" op="$2" val="$3"
    local ref
    [[ "$col" == "last" ]] && ref='$NF' || ref="\$$col"
    case "$op" in
        eq)           echo "${ref} == \"${val}\"" ;;
        neq)          echo "${ref} != \"${val}\"" ;;
        contains)     echo "${ref} ~ \"${val}\"" ;;
        not_contains) echo "${ref} !~ \"${val}\"" ;;
        gte)          echo "${ref}+0 >= ${val}" ;;
        lte)          echo "${ref}+0 <= ${val}" ;;
        *) log_err "알 수 없는 연산자: $op (eq/neq/contains/not_contains/gte/lte)"; return 1 ;;
    esac
}

# 파일 처리 메인 함수
process_file() {
    local path="$1" delimiter="$2" logic="$3" has_header="$4"
    shift 4
    local -a filters=("$@")

    [[ ! -f "$path" ]] && { log_err "파일 없음: $path"; return 1; }

    # _origin 경로 결정: data.dat → data_origin.dat
    local dir filename base ext origin
    dir="${path%/*}"; [[ "$dir" == "$path" ]] && dir="."
    filename="${path##*/}"
    if [[ "$filename" == *.* ]]; then
        base="${filename%.*}"; ext=".${filename##*.}"
    else
        base="$filename"; ext=""
    fi
    origin="${dir}/${base}_origin${ext}"

    # 최초 실행 시 원본 백업 생성 (이후 덮어쓰지 않음)
    if [[ ! -f "$origin" ]]; then
        cp "$path" "$origin"
        log_ok "원본 백업 생성: $origin"
    fi

    # 구분자 이스케이프 처리 (\t → 실제 탭)
    [[ "$delimiter" == '\t' || "$delimiter" == "tab" ]] && delimiter=$'\t'

    # 각 FILTER_N 조건 → awk 조건 문자열 변환
    local -a conds=()
    for f in "${filters[@]}"; do
        IFS=':' read -r col op val <<< "$f"
        local c
        c=$(build_cond "$col" "$op" "$val") || return 1
        conds+=("$c")
    done

    # AND / OR 결합
    local glue; [[ "$logic" == "OR" ]] && glue=" || " || glue=" && "
    local awk_expr="${conds[0]}"
    for ((i=1; i<${#conds[@]}; i++)); do
        awk_expr="${awk_expr}${glue}${conds[$i]}"
    done

    # 헤더 포함 여부에 따라 awk 실행
    # ponytail: whitespace 분기로 -F 옵션 분리 — awk -F' ' 는 기본 동작과 미묘하게 다름
    local tmp="${path}.tmp.$$"
    local before after
    before=$(wc -l < "$origin")

    if [[ "$delimiter" == "whitespace" ]]; then
        if [[ "$has_header" == "yes" ]]; then
            awk "NR==1 || (${awk_expr})" "$origin" > "$tmp"
        else
            awk "${awk_expr}" "$origin" > "$tmp"
        fi
    else
        if [[ "$has_header" == "yes" ]]; then
            awk -F"${delimiter}" "NR==1 || (${awk_expr})" "$origin" > "$tmp"
        else
            awk -F"${delimiter}" "${awk_expr}" "$origin" > "$tmp"
        fi
    fi

    after=$(wc -l < "$tmp")
    mv "$tmp" "$path"
    log_ok "$(basename "$path"): ${before}줄 → ${after}줄 [${logic}: ${filters[*]}]"
}

# ── conf 파싱 ─────────────────────────────────────────────────────────────────
# 섹션이 끝날 때 수집된 설정으로 process_file 호출
cur_path="" cur_delim="whitespace" cur_logic="AND" cur_header="no"
declare -a cur_filters=()

flush() {
    [[ -z "$cur_path" ]] && return
    if [[ ${#cur_filters[@]} -eq 0 ]]; then
        log_warn "FILTER 조건 없음, 건너뜀: $cur_path"
    else
        process_file "$cur_path" "$cur_delim" "$cur_logic" "$cur_header" "${cur_filters[@]}"
    fi
    cur_path="" cur_delim="whitespace" cur_logic="AND" cur_header="no"
    cur_filters=()
}

while IFS= read -r raw || [[ -n "$raw" ]]; do
    line=$(trim "${raw%%#*}")   # 인라인 주석 제거 후 양쪽 공백 제거
    [[ -z "$line" ]] && continue

    # 섹션 헤더 [fileN]
    if [[ "$line" =~ ^\[.+\]$ ]]; then
        flush; continue
    fi

    key=$(trim "${line%%=*}")
    val=$(trim "${line#*=}")

    case "$key" in
        PATH)         cur_path="$val"   ;;
        DELIMITER)    cur_delim="$val"  ;;
        FILTER_LOGIC) cur_logic="$val"  ;;
        HAS_HEADER)   cur_header="$val" ;;
        FILTER_*)     cur_filters+=("$val") ;;
    esac
done < "$CONF_FILE"

flush   # 마지막 섹션 처리
log "전체 처리 완료"
