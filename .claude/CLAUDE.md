# Linux-EZ-Kit 프로젝트 가이드

## 프로젝트 개요

Linux Ez Kit은 리눅스 서버 관리자와 운영자를 위한 편리한 Bash 스크립트 도구 모음입니다. 시스템 모니터링, 네트워크 구성, 보안 패치, 취약점 검사 등 일상적인 운영 작업을 자동화하고 간소화하는 스크립트를 제공합니다.

### 프로젝트 목표

- **자동화**: 반복적인 운영 작업을 자동화하여 운영 효율성 향상
- **안정성**: 백업 및 복구 기능을 통한 안전한 시스템 변경
- **이식성**: 외부 의존성을 최소화한 순수 Bash 기반 스크립트
- **사용 편의성**: 직관적인 인터페이스와 상세한 문서 제공

### 기술 스택

- **언어**: Bash 4.0+
- **대상 OS**: Rocky Linux 8/9, RHEL 계열, Ubuntu (일부 스크립트)
- **핵심 유틸리티**: bc, awk, grep, sed, nmcli, rpm

## 프로젝트 구조

```
linux-ez-kit/
├── .claude/                          # Claude Code 설정 (이 파일)
├── README.md                         # 프로젝트 메인 문서
└── scripts/                          # 모든 스크립트 모음
    ├── system-monitoring/            # 시스템 상태 모니터링
    ├── network-bonding/              # NIC 본딩 자동 구성
    ├── vulnerabilty-check/           # React/Next.js CVE 점검
    ├── ssl_ssh_patch/                # OpenSSL/OpenSSH 보안 패치
    └── keepalive-guardian/           # 서비스 가동 유지 감시 (진행 중)
```

---

## 스크립트별 상세 정보

### 1. System Status Monitoring (`system-monitoring/`)

**목적**: SSH 접속 시 서버의 상태(CPU, 메모리, 디스크 등)를 한눈에 확인

#### 파일 구조
```
system-monitoring/
├── sys_status.sh          # 메인 스크립트
└── README.md              # 사용 가이드
```

#### 주요 기능
- CPU 사용률 및 코어 정보 표시
- 메모리/스왑 사용률 모니터링
- 디스크(/, /boot) 사용률 확인
- 서버 가동 시간 및 마지막 재부팅 시간 표시
- 컬러 기반 상태 표시 (GOOD/WARN/ALERT)

#### 기술적 특징
- 순수 Bash 스크립트
- lscpu, df, free, top, bc 등 표준 유틸리티 활용
- ANSI 컬러 코드를 활용한 가독성 높은 출력

#### 사용 방법
```bash
# 수동 실행
/usr/local/bin/sys_status.sh

# SSH 로그인 시 자동 실행 (.bash_profile)
echo '/usr/local/bin/sys_status.sh' >> ~/.bash_profile
```

#### 지원 환경
- Rocky Linux 8, 9
- RHEL 계열

---

### 2. NIC Bonding Configuration (`network-bonding/`)

**목적**: 네트워크 인터페이스 본딩을 자동으로 구성하여 네트워크 가용성 및 안정성 향상

#### 파일 구조
```
network-bonding/
├── set_bonding.sh         # 본딩 구성 메인 스크립트
├── bonding.conf           # 본딩 설정 파일
└── README.md              # 사용 가이드
```

#### 주요 기능
- Active-Backup 모드 본딩 자동 생성 (bond0, bond1)
- 설정 적용 전 자동 백업 및 복구 스크립트 생성
- NetworkManager 기반 구성
- 설정 유효성 검증 (인터페이스 존재, IP 형식 등)
- 백업 목록 조회 및 복구 기능

#### 기술적 특징
- nmcli를 활용한 NetworkManager 제어
- Active-Backup 모드: mode=active-backup, miimon=100, fail_over_mac=active
- 타임스탬프 기반 백업 시스템 (`/backup/nic_info_backup/YYYYMMDD_HHMMSS/`)
- 자동 생성되는 restore.sh 복구 스크립트

#### 구성 유형
- **BOND0**: 일반 네트워크 연결 (고정 IP, 게이트웨이, DNS 설정)
- **BOND1**: 브리지 슬레이브 (IP 없이 브리지에 연결)

#### 사용 방법
```bash
# 설정 파일 편집
vi bonding.conf

# 본딩 구성 실행
sudo ./set_bonding.sh

# 백업 목록 확인
sudo ./set_bonding.sh --list-backups

# 백업에서 복구
sudo ./set_bonding.sh --restore <타임스탬프>
```

#### 지원 환경
- Rocky Linux (RHEL 계열)
- NetworkManager 사용 시스템

---

### 3. React/Next.js Vulnerability Check (`vulnerabilty-check/`)

**목적**: React Server Components 및 Next.js의 심각한 보안 취약점(CVE-2025-55182, CVE-2025-66478) 자동 점검

#### 파일 구조
```
vulnerabilty-check/
├── check_react_nextjs_vulnerability.sh    # 메인 점검 스크립트
└── README.md                              # 사용 가이드
```

#### 주요 기능
- package.json 파일 자동 검색 (/home, /var/www, /opt, /usr/local)
- 취약한 React Server Components 패키지 버전 탐지
- 취약한 Next.js 버전 탐지
- 상세 보고서 파일 자동 생성 (`vulnerability_check_report_YYYYMMDD_HHMMSS.txt`)

#### 기술적 특징
- **순수 Bash 스크립트**: Node.js, jq 등 외부 의존성 없음
- 표준 유틸리티만 사용 (grep, sed, awk, find)
- JSON 파싱을 Bash 정규표현식으로 처리
- 버전 비교 로직 내장

#### 검사 대상
- react-server-dom-webpack
- react-server-dom-parcel
- react-server-dom-turbopack
- Next.js (15.0.x ~ 16.0.x)

#### 사용 방법
```bash
# Root 권한으로 실행 (모든 디렉토리 검색)
sudo ./check_react_nextjs_vulnerability.sh

# 일반 사용자 권한으로 실행 (접근 가능 디렉토리만)
./check_react_nextjs_vulnerability.sh
```

#### 지원 환경
- 모든 Linux 배포판

---

### 4. OpenSSL/OpenSSH Security Patch (`ssl_ssh_patch/`)

**목적**: OpenSSL과 OpenSSH의 보안 취약점(CVE)을 패치하는 자동화 스크립트

#### 파일 구조
```
ssl_ssh_patch/
├── patch_script.sh               # 패치 메인 스크립트
├── openssh/                      # OpenSSH RPM 패키지 디렉토리
│   ├── openssh-*.rpm
│   ├── openssh-server-*.rpm
│   └── openssh-clients-*.rpm
├── openssl/                      # OpenSSL RPM 패키지 디렉토리
│   ├── openssl-*.rpm
│   ├── openssl-libs-*.rpm
│   ├── openssl-devel-*.rpm
│   └── openssl-fips-provider-*.rpm
└── README.md                     # 사용 가이드
```

#### 주요 기능
- CVE 기반 패치 사전/사후 검증 (changelog 분석)
- 패치 적용 전 자동 백업 (패키지 정보, 설정 파일, 라이브러리)
- FIPS Provider 환경 자동 감지 (fips-provider-next vs openssl-fips-provider)
- 설치 실패 시 자동 롤백
- 결과 보고서 파일 자동 생성

#### 기술적 특징
- RPM 패키지 기반 설치
- Rocky 9.5+ 환경에서 fips-provider-next 자동 감지
- OpenSSH → OpenSSL 순서로 패치 진행
- sshd 서비스 재시작 및 상태 검증
- 타임스탬프 기반 백업 시스템 (`/tmp/ssl_ssh_patch/backup/backup_YYYYMMDD_HHMMSS/`)

#### 패치 프로세스
1. OS 버전 및 Root 권한 확인
2. RPM 파일 존재 확인
3. CVE 사전 검증 (changelog)
4. /usr/local 수동 설치 SSH 제거 (선택)
5. OpenSSH 백업 → 설치 → 검증
6. OpenSSL 백업 → 설치 → ldconfig → sshd 재시작 → CVE 검증
7. 최종 검증 및 보고서 생성

#### FIPS Provider별 동작
| 환경 | FIPS 타입 | 설치 패키지 |
|------|-----------|------------|
| Rocky 9.5+ | fips-provider-next | openssl, openssl-libs, openssl-devel |
| Rocky 9.0~9.4 | openssl-fips-provider | 모든 openssl 패키지 |
| FIPS 미사용 | none | 모든 openssl 패키지 |

#### 사용 방법
```bash
# CVE 코드 설정 (스크립트 내 CVE_LIST 변수)
CVE_LIST="CVE-2025-15467 CVE-2025-11187"

# RPM 파일 배치
# openssh/, openssl/ 폴더에 RPM 파일 위치

# 스크립트 실행
sudo ./patch_script.sh
```

#### 지원 환경
- Rocky Linux 9.x
- RHEL 9.x

---

### 5. Keepalive Guardian (`keepalive-guardian/`)

**상태**: 설계 완료, 구현 예정

**목적**: L4 장비 없이 Active-Standby 방식의 서비스 이중화 환경 구축 (Keepalived 기반 VIP Failover)

#### 파일 구조 (예정)
```
keepalive-guardian/
├── README.md                         # 구현 정의서
├── install.sh                        # 설치 자동화 스크립트
├── keepalived.conf                   # Keepalived VRRP 설정
├── service_health_check.sh           # 장애 판정 스크립트
├── service_recovery_check.sh         # Failback 안정화 체크 스크립트
└── service_check.conf                # 환경 변수 설정 파일
```

#### 주요 기능
- **VIP 기반 Failover**: Keepalived VRRP를 이용한 가상 IP 자동 이동
- **다층 헬스 체크**: 포트 체크, 프로세스 체크, DB 복제 상태 체크
- **DB 복제 모니터링**: MySQL/MariaDB replication 상태 및 지연 시간 확인
- **안정화 기반 Failback**: 지정된 안정화 시간 동안 연속 정상 상태 확인 후 자동 원복
- **환경별 설정 분리**: 서비스 포트, 프로세스, DB 접속 정보 외부 파일 관리
- **상세 로깅**: 장애 판정, Failover/Failback 이벤트 로그 기록

#### 기술적 특징
- **Keepalived + VRRP**: 표준 프로토콜 기반 HA 구성
- **Active-Standby 구조**: 평상시 Active 서버가 VIP 보유, 장애 시 Standby로 이동
- **ANY FAILURE → FAILOVER**: 포트/프로세스/DB 중 하나라도 실패 시 즉시 Failover
- **안정화 시간 기반 Failback**: Active 복구 후 지정 시간 동안 연속 정상 상태 유지 확인
- **DB Replication 체크**: `SHOW REPLICA STATUS` 기반 IO/SQL thread 및 lag 검증
- **재사용 가능한 구조**: 설정 파일만 변경하여 다양한 환경에 적용 가능

#### 장애 판정 기준
| 항목 | 체크 방법 | 정상 조건 |
|------|-----------|-----------|
| 포트 체크 | TCP 연결 가능 여부 | 모든 설정된 포트 접근 가능 |
| 프로세스 체크 | pgrep -f <process_name> | 모든 설정된 프로세스 실행 중 |
| DB 복제 상태 | SHOW REPLICA STATUS | IO/SQL thread 정상, lag < 임계값 |
| 서버 네트워크 | VRRP advertisement | advertisement 정상 송신 |

#### Failover/Failback 정책
- **Failover**: 헬스 체크 실패 → Keepalived priority 하락 → Standby MASTER 승격 → VIP 이동
- **Failback**: Active 복구 + 안정화 시간 동안 연속 정상 → VIP 원복 허용

#### 시스템 구성 (예정)
```
                 Client / Admin User
                         |
                         |
                      Virtual IP
                         |
            +---------------------------+
            |                           |
         Active Server              Standby Server
         Rocky Linux                Rocky Linux
         keepalived                 keepalived
         (VIP 보유)                (BACKUP 상태)
```

#### 구현 예정 파일
| 파일 | 설명 |
|------|------|
| /etc/keepalived/keepalived.conf | VRRP 설정 (VIP, priority, track_script) |
| /etc/keepalived/service_check.conf | 환경 변수 (포트, 프로세스, DB 정보) |
| /usr/local/bin/service_health_check.sh | 포트/프로세스/DB 체크 (exit 0/1) |
| /usr/local/bin/service_recovery_check.sh | 안정화 시간 기반 복구 판단 |
| /var/log/service_ha_check.log | HA 이벤트 로그 |

#### 지원 환경 (예정)
- Rocky Linux 8, 9
- RHEL 계열
- Keepalived 설치 가능 환경
- 동일 L2 네트워크의 서버 2대

#### 구현 우선순위
1. Keepalived 기본 설정 자동화
2. 포트/프로세스 헬스 체크 스크립트
3. DB 복제 상태 체크 로직
4. Failback 안정화 로직
5. 설치 자동화 스크립트

---

## 개발 가이드

### 코드 작성 원칙

1. **순수 Bash 우선**: 외부 의존성 최소화 (Node.js, Python, jq 등 불필요)
2. **백업 필수**: 시스템 변경 전 항상 자동 백업 구현
3. **에러 처리**: set -e 사용 자제, 명시적 에러 처리 및 복구 로직 구현
4. **타임스탬프**: 백업/로그 파일은 `YYYYMMDD_HHMMSS` 형식 사용
5. **사용자 확인**: 위험한 작업 전 사용자 확인 프롬프트
6. **컬러 출력**: ANSI 컬러 코드를 활용한 가독성 높은 출력
7. **상세 로깅**: 실행 과정과 결과를 파일로 저장

### 스크립트 구조 패턴

```bash
#!/bin/bash

# 변수 정의
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/path/to/logs/script_${TIMESTAMP}.log"

# 함수 정의
function error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

function backup() {
    # 백업 로직
}

function validate() {
    # 검증 로직
}

# 메인 로직
main() {
    # 1. 권한/환경 확인
    # 2. 백업
    # 3. 검증
    # 4. 실행
    # 5. 검증
    # 6. 보고서 생성
}

main "$@"
```

### 백업 시스템 패턴

모든 스크립트는 타임스탬프 기반 백업 시스템 사용:

```
/backup/<script_name>/backup_YYYYMMDD_HHMMSS/
├── backup_info.txt        # 백업 정보 및 복구 방법
├── restore.sh             # 자동 생성된 복구 스크립트
└── <백업 파일/폴더>
```

### 테스트 가이드

1. **개발 환경**: 먼저 테스트 VM에서 검증
2. **백업 검증**: 백업이 정상적으로 생성되는지 확인
3. **복구 테스트**: restore.sh 스크립트가 정상 동작하는지 확인
4. **에러 시나리오**: 실패 상황에서 롤백이 정상 동작하는지 확인
5. **프로덕션 적용**: 동일 OS 버전에서 검증 후 적용

### 문서화 규칙

각 스크립트 폴더에는 반드시 다음을 포함:

1. **README.md**: 사용 가이드 (목적, 기능, 사용법, 문제 해결)
2. **스크립트 주석**: 함수별 목적과 파라미터 설명
3. **사용 예시**: 실제 사용 예시 및 출력 예시

---

## 프로젝트 유지보수

### 새로운 스크립트 추가 시

1. `scripts/<script_name>/` 폴더 생성
2. README.md 작성 (위 스크립트들과 동일한 형식)
3. 메인 스크립트 작성 (위 패턴 참고)
4. 루트 README.md의 "스크립트 카탈로그" 섹션에 추가
5. 이 CLAUDE.md 파일에 상세 정보 추가

### 버전 관리

- Git을 활용한 버전 관리
- 커밋 메시지는 명확하게 (`feat:`, `fix:`, `docs:` 등)
- 중요한 변경은 태그 생성

### 이슈 및 개선사항

- GitHub Issues를 통한 버그 리포트 및 기능 제안
- Pull Request를 통한 기여

---

## 보안 및 주의사항

### Root 권한
대부분의 스크립트는 시스템 변경을 위해 root 권한 필요

### 원격 접속 주의
네트워크 설정 변경 시 SSH 연결이 끊길 수 있으므로 콘솔 접근 가능 상태에서 작업

### 백업 확인
시스템 변경 전 항상 백업이 정상적으로 생성되었는지 확인

### 테스트 환경 우선
프로덕션 환경에 적용하기 전 반드시 테스트 환경에서 검증

---

## 참고 자료

### 공식 문서
- Rocky Linux: https://rockylinux.org/
- NetworkManager: https://networkmanager.dev/
- RPM Packaging: https://rpm-packaging-guide.github.io/

---

## 라이선스

MIT License