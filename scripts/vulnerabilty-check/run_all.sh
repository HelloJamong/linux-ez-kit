#!/bin/bash

# 취약점 종합 점검: 디렉토리 내 check_*.sh 를 순서대로 실행하고 결과를 요약

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS=()

for script in "$SCRIPT_DIR"/check_*.sh; do
    bash "$script"
    if [ $? -eq 0 ]; then
        RESULTS+=("✓ $(basename "$script")")
    else
        RESULTS+=("🔴 $(basename "$script") - 취약점 발견, 보고서 확인 필요")
    fi
    echo ""
done

echo "=================================================="
echo "종합 점검 결과"
echo "=================================================="
printf '%s\n' "${RESULTS[@]}"
echo "=================================================="
