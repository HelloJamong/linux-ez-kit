#!/bin/bash

################################################################################
# Linux-EZ-Kit - 프로젝트 내보내기 스크립트
#
# 사용법: ./export.sh
# 목적:  특정 스크립트를 선택하여 tar.gz로 압축 후 export/ 폴더에 저장
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR="${SCRIPT_DIR}/export"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# 사용 가능한 프로젝트 목록 수집
# ------------------------------------------------------------------------------
mapfile -t PROJECTS < <(ls -1 "${SCRIPT_DIR}/scripts/")

# ------------------------------------------------------------------------------
# 배너
# ------------------------------------------------------------------------------
print_banner() {
    echo ""
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "${BOLD}       Linux-EZ-Kit - 프로젝트 내보내기${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# 프로젝트 선택 메뉴
# ------------------------------------------------------------------------------
select_project() {
    echo -e "${BOLD}  내보낼 프로젝트를 선택하세요:${NC}"
    echo ""

    local i=1
    for project in "${PROJECTS[@]}"; do
        printf "    ${CYAN}[%d]${NC} %s\n" "$i" "$project"
        (( i++ ))
    done
    printf "    ${CYAN}[%d]${NC} 전체 (모든 프로젝트)\n" "$i"
    echo ""

    local max=$i
    while true; do
        read -r -p "  번호 입력 [1-${max}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max" ]; then
            SELECTED_INDEX=$(( choice - 1 ))
            break
        fi
        echo -e "  ${RED}1~${max} 사이의 숫자를 입력하세요.${NC}"
    done
}

# ------------------------------------------------------------------------------
# 단일 프로젝트 압축
# ------------------------------------------------------------------------------
export_project() {
    local project="$1"
    local output_file="${EXPORT_DIR}/${project}_${TIMESTAMP}.tar.gz"

    echo -e "  압축 중: ${CYAN}${project}${NC} → ${output_file}"

    tar -czf "$output_file" \
        --exclude=".omc" \
        --exclude=".claude" \
        --exclude=".git" \
        --exclude="*.log" \
        --exclude="*.tmp" \
        --exclude="*.swp" \
        --exclude="*.md" \
        --exclude="*.txt" \
        --exclude="*.sample" \
        --exclude="environment_check_report_*" \
        --exclude="install_log_*" \
        --exclude="install_report_*" \
        -C "${SCRIPT_DIR}/scripts" \
        "$project" 2>/dev/null

    if [ $? -eq 0 ]; then
        local size
        size=$(du -sh "$output_file" | cut -f1)
        echo -e "  ${GREEN}완료${NC}: ${output_file} (${size})"
    else
        echo -e "  ${RED}실패${NC}: ${project} 압축 중 오류 발생"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 메인
# ------------------------------------------------------------------------------
main() {
    print_banner

    # export 폴더 생성
    mkdir -p "$EXPORT_DIR"

    # 프로젝트 선택
    select_project

    echo ""
    echo -e "${BOLD}----------------------------------------------------------------------${NC}"

    local total=${#PROJECTS[@]}
    local all_index=$total  # 전체 선택 인덱스 (0-based)

    if [ "$SELECTED_INDEX" -eq "$all_index" ]; then
        # 전체 내보내기
        echo -e "  대상: ${CYAN}전체 프로젝트 (${total}개)${NC}"
        echo ""
        local success=0
        for project in "${PROJECTS[@]}"; do
            export_project "$project" && (( success++ ))
        done
        echo ""
        echo -e "${BOLD}----------------------------------------------------------------------${NC}"
        echo -e "  ${GREEN}완료: ${success}/${total}개 프로젝트 내보내기 완료${NC}"
    else
        # 단일 프로젝트 내보내기
        local project="${PROJECTS[$SELECTED_INDEX]}"
        echo -e "  대상: ${CYAN}${project}${NC}"
        echo ""
        export_project "$project"
        echo ""
        echo -e "${BOLD}----------------------------------------------------------------------${NC}"
        echo -e "  ${GREEN}완료${NC}"
    fi

    echo ""
    echo -e "  저장 위치: ${CYAN}${EXPORT_DIR}/${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo ""
}

main
