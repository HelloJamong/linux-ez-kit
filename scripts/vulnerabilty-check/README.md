# 취약점 점검 스크립트 사용 가이드

## 개요
모든 Linux 환경에서 최근 이슈가 된 RCE 취약점을 점검하는 스크립트 모음입니다. 순수 bash로 작성되어 jq 등의 추가 패키지 없이 실행 가능합니다.

| 스크립트 | 대상 | CVE | 점검 방식 |
|---------|------|-----|----------|
| `check_react_nextjs_vulnerability.sh` | React Server Components / Next.js | CVE-2025-55182, CVE-2025-66478 | package.json 파싱 |
| `check_node2shell.sh` | Node.js 내장 Brotli, 시스템 libbrotli | CVE-2026-111497 | 설치된 node 바이너리 / 라이브러리 버전 |
| `check_php2shell.sh` | PHP (php, php-fpm) | CVE-2026-109618, CVE-2026-109619 | 설치된 php 바이너리 버전 + 완화 설정 |
| `run_all.sh` | 위 전체 | - | `check_*.sh` 순차 실행 후 요약 |

```bash
# 전체 점검
sudo ./run_all.sh

# 개별 점검
sudo ./check_node2shell.sh
sudo ./check_php2shell.sh
```

각 스크립트는 취약점이 발견되면 종료 코드 `1`, 없으면 `0`을 반환합니다 (cron/모니터링 연동 가능).

---

## Node2Shell (CVE-2026-111497)

Node.js가 내장한 Google Brotli 디코더의 Out-of-bounds Write 취약점입니다. 조작된 압축 데이터로 프로세스 크래시, 메모리 노출, 원격 코드 실행이 가능합니다 (CVSS 4.0: 9.2).

| Node.js 라인 | 안전 버전 |
|-------------|----------|
| 22.x | 22.23.4 이상 |
| 24.x | 24.22.1 이상 |
| 26.x | 26.12.1 이상 |
| 20.x, 23.x, 25.x 등 EOL | 패치 없음 → 지원 버전으로 업그레이드 |

시스템 Brotli 라이브러리: 1.0.3 ~ 1.2.0 영향, 1.0.10 / 1.1.1 / 1.2.1 에서 수정.

**점검 내용**
- PATH 및 `/usr /opt /home /root /srv /var/www` 에서 `node`/`nodejs` 실행 파일 검색 (nvm, tar.gz 설치본 포함, `node_modules` 제외)
- 각 바이너리의 Node.js 버전과 내장 Brotli 버전 확인
  - 판정은 **Node.js 버전 기준**입니다. 패치된 Node.js 도 `process.versions.brotli` 값은 바뀌지 않을 수 있습니다 (예: 24.22.1 → `1.2.0` 표시).
- 시스템 `libbrotlidec` 버전 확인

## PHP2Shell (CVE-2026-109618, CVE-2026-109619)

인증 없이 PHP 워커 권한으로 원격 코드 실행이 가능한 취약점 2건입니다 (CVSS 4.0: 9.2). **실제 공격이 확인**되었습니다.
- CVE-2026-109618: Out-of-memory 처리 중 메모리 손상
- CVE-2026-109619: upload progress 기능의 Use-After-Free

| PHP 라인 | 안전 버전 |
|---------|----------|
| 8.5.x | 8.5.12 이상 |
| 8.4.x | 8.4.27 이상 |
| 8.3.x | 8.3.36 이상 |
| 8.2.x | 8.2.35 이상 |
| 8.1 이하 | 공식 릴리스 없음 → 업그레이드 또는 배포판 백포트 |

**점검 내용**
- PATH 및 `/usr /opt` 에서 `php`, `php-fpm`, `php8.x`, `php-fpm8.x` 실행 파일 검색 (remi `/opt/remi` 포함)
- 각 바이너리의 버전 확인 및 임시 완화 설정 표시: `session.upload_progress.enabled`, `memory_limit`, `post_max_size`
  - FPM pool 설정(`php_admin_value`)으로 재정의된 값은 반영되지 않습니다.

**임시 완화 (패치 전)**
```ini
; php.ini
session.upload_progress.enabled = Off   ; CVE-2026-109619
```

## 배포판 패키지 (RHEL/Rocky AppStream, Ubuntu) 판정

배포판 패키지는 보안 패치를 백포트하면서 버전 번호를 유지하는 경우가 많습니다. 바이너리가 패키지 소유이면 `rpm -q --changelog` (Ubuntu: `changelog.Debian.gz`)에서 CVE 번호를 먼저 확인하고, 있으면 안전으로 판정합니다. changelog 에 CVE 가 없고 버전이 수정 버전 미만이면 취약으로 표시합니다.

## 한계
- 컨테이너 내부의 node/php 는 점검하지 않습니다.
- Python `brotli` 패키지, .NET 등 Brotli 를 자체 포함한 다른 런타임은 점검 범위 밖입니다.

---

# React/Next.js 취약점 점검

이 스크립트는 React Server Components 및 Next.js 취약점(CVE-2025-55182, CVE-2025-66478)을 점검합니다.

## 취약점 정보
- **CVE-2025-55182**: React Server Components(RSC)의 사전 인증 원격 코드 실행(RCE) 취약점
- 영향: react-server-dom-webpack, react-server-dom-parcel, react-server-dom-turbopack, Next.js

## 취약한 버전

### React Server Components
| 패키지명 | 취약 버전 | 안전 버전 |
|---------|----------|----------|
| react-server-dom-webpack | 19.0, 19.1.0~19.1.1, 19.2.0 | 19.0.1, 19.1.2, 19.2.1 이상 |
| react-server-dom-parcel | 19.0, 19.1.0~19.1.1, 19.2.0 | 19.0.1, 19.1.2, 19.2.1 이상 |
| react-server-dom-turbopack | 19.0, 19.1.0~19.1.1, 19.2.0 | 19.0.1, 19.1.2, 19.2.1 이상 |

### Next.js
| 버전 | 안전 버전 |
|------|----------|
| 15.0.x | 15.0.5 이상 |
| 15.1.x | 15.1.9 이상 |
| 15.2.x | 15.2.6 이상 |
| 15.3.x | 15.3.6 이상 |
| 15.4.x | 15.4.8 이상 |
| 15.5.x | 15.5.7 이상 |
| 16.0.x | 16.0.7 이상 |
| 14.3.0-canary.77 이상 | 14.x 안정 버전으로 다운그레이드 권고 |

## 설치 및 사용 방법

### 1. 스크립트 다운로드 또는 복사
```bash
# 파일 다운로드 후 실행 권한 부여
chmod +x check_react_nextjs_vulnerability.sh
```

### 2. root 권한으로 실행 (권장)
```bash
# 모든 디렉토리 검색을 위해 root 권한 사용
sudo ./check_react_nextjs_vulnerability.sh
```

### 3. 일반 사용자 권한으로 실행
```bash
# 접근 가능한 디렉토리만 점검
./check_react_nextjs_vulnerability.sh
```

## 검색 경로
스크립트는 다음 경로에서 package.json 파일을 검색합니다:
- /home
- /var/www
- /opt
- /usr/local

## 출력 내용
1. 발견된 Node.js 프로젝트 목록
2. 각 프로젝트의 취약점 분석
3. 취약한 패키지 및 버전 정보
4. 최종 요약 및 조치 권고사항

## 보고서 파일
- 실행 시 자동으로 `vulnerability_check_report_YYYYMMDD_HHMMSS.txt` 파일 생성
- 점검 결과가 저장되어 추후 참고 가능

## 의존성
- **없음**: 순수 bash로 작성되어 추가 패키지 설치 불필요
- 표준 Linux 도구만 사용 (grep, sed, awk, find)
- Node.js, npm, jq 등의 외부 도구 불필요

## 점검 결과 해석

### ✓ 안전한 경우
```
✓ 이 프로젝트는 안전한 버전을 사용하고 있습니다.
```

### 🔴 취약한 경우
```
🔴 이 프로젝트는 취약점에 노출되어 있습니다!
```

## 취약점 발견 시 조치 방법

### 방법 1: package.json 수정 후 업데이트
```bash
cd /path/to/project

# package.json 파일 수정
# 예: "next": "15.0.3" → "next": "15.0.5"

# 의존성 업데이트
npm install

# 또는 특정 패키지만 업데이트
npm install next@15.0.5

# 애플리케이션 재시작
```

### 방법 2: npm update 사용
```bash
cd /path/to/project

# 특정 패키지 업데이트
npm update next

# 또는 모든 패키지 업데이트
npm update
```

### 방법 3: 특정 버전으로 설치
```bash
# Next.js 예시
npm install next@15.0.5

# React Server Components 예시
npm install react-server-dom-webpack@19.0.1
```

## 주의사항
1. **백업 권장**: 업데이트 전 프로젝트 백업
2. **테스트 필수**: 업데이트 후 애플리케이션 정상 동작 확인
3. **의존성 충돌**: 다른 패키지와의 호환성 확인
4. **Production 환경**: 개발/테스트 환경에서 먼저 검증 후 적용

## 추가 검색 경로 설정
스크립트 내에서 검색 경로를 수정할 수 있습니다:
```bash
# 스크립트 파일 편집
vi check_react_nextjs_vulnerability.sh

# 다음 라인을 찾아 경로 추가
PACKAGE_JSON_FILES=$(find /home /var/www /opt /usr/local /추가경로 -path "*/node_modules" -prune -o -name "package.json" -print 2>/dev/null)
```

## 참고 자료
- Node2Shell: https://www.akamai.com/blog/security-research/inside-node2shell-closer-look-cve-2026-111497
- PHP2Shell: https://unit42.paloaltonetworks.com/cve-2026-109618-cve-2026-109619/
- React 공식 보안 공지: https://react.dev/blog/2025/12/03/critical-security-vulnerability-in-react-server-components
- NIST CVE 데이터베이스: https://nvd.nist.gov/vuln/detail/CVE-2025-55182
- KISA 보안공지: https://www.boho.or.kr/kr/bbs/view.do?bbsId=B0000133&nttId=71912

## 문의
- 한국인터넷진흥원 사이버민원센터: 국번없이 118
