# Linux-EZ-Kit

Linux 운영 환경에서 유용하게 사용할 수 있는 다양한 스크립트 모음입니다.

## 프로젝트 소개

Linux Ez Kit은 리눅스 서버 관리자와 운영자를 위한 편리한 스크립트 도구 모음입니다. 시스템 모니터링, 백업, 로그 관리, 네트워크 도구 등 일상적인 운영 작업을 자동화하고 간소화하는 스크립트를 제공합니다.

## 스크립트 카탈로그

### 시스템 모니터링

#### [System Status Monitoring](scripts/system-monitoring/)
서버의 CPU, 메모리, 디스크, 가동시간 등을 한눈에 확인할 수 있는 모니터링 스크립트입니다.

- **주요 기능**: CPU/메모리/디스크 사용률 모니터링, 컬러 기반 상태 표시
- **사용 사례**: SSH 로그인 시 자동 실행, 서버 상태 빠른 확인
- **지원 환경**: Rocky Linux 8, 9

### 네트워크 구성

#### [NIC Bonding Configuration](scripts/network-bonding/)
네트워크 인터페이스 본딩을 자동으로 구성하여 네트워크 가용성과 안정성을 향상시키는 스크립트입니다.

- **주요 기능**: Active-Backup 모드 본딩 자동 구성, 설정 백업/복구, 설정 검증
- **사용 사례**: 서버 네트워크 이중화, 장애 대응, 고가용성 네트워크 구성
- **지원 환경**: Rocky Linux (RHEL 계열), NetworkManager 사용 시스템

### 보안 및 취약점 검사

#### [React/Next.js Vulnerability Check](scripts/vulnerabilty-check/)
React Server Components 및 Next.js의 심각한 보안 취약점(CVE-2025-55182, CVE-2025-66478)을 자동으로 점검하는 스크립트입니다.

- **주요 기능**: package.json 자동 검색, 취약한 버전 탐지, 상세 보고서 생성
- **사용 사례**: 웹 애플리케이션 보안 점검, 취약점 모니터링, 컴플라이언스 검증
- **지원 환경**: 모든 Linux 배포판 (순수 bash, 외부 의존성 없음)
- **특징**: Node.js, jq 등 추가 패키지 설치 불필요

#### [OpenSSL / OpenSSH Security Patch](scripts/ssl_ssh_patch/)
OpenSSL과 OpenSSH의 보안 취약점(CVE)을 패치하는 자동화 스크립트입니다. 백업, RPM 설치, 버전 검증, CVE 반영 확인까지 전체 프로세스를 자동으로 수행합니다.

- **주요 기능**: CVE 기반 사전/사후 검증, 자동 백업, FIPS Provider 환경 감지, 롤백 및 결과 보고서 생성
- **사용 사례**: OpenSSL/OpenSSH 보안 패치 적용, CVE 취약점 조치, 패치 컴플라이언스 확인
- **지원 환경**: Rocky Linux 9.x, RHEL 9.x

#### [Kernel Security Patch](scripts/kernel_patch/)
Linux 커널 보안 취약점(CVE)을 오프라인 RPM으로 패치하는 자동화 스크립트입니다. 기존 커널을 유지한 채 새 커널을 추가 설치하며, 재부팅은 수동으로 진행할 수 있도록 안내합니다.

- **주요 기능**: CVE 기반 사전/사후 검증, 자동 백업(커널 버전·GRUB 설정), 비파괴 설치(기존 커널 보존), GRUB 자동 설정, 롤백 안내, 결과 보고서 생성
- **사용 사례**: 커널 CVE 취약점 조치, 오프라인 환경 보안 패치, 재부팅 시점 직접 제어가 필요한 운영 환경
- **지원 환경**: Rocky Linux 9.x, RHEL 9.x (9.0 ~ 9.x 전 버전 단일 RPM 세트 지원)

### 런타임 관리

#### [Java (Temurin) Update](scripts/java-update/)
tar.gz로 수동 설치한 Eclipse Temurin JDK 21을 안전하게 업데이트하는 스크립트입니다. 기존 심볼릭 링크 구조(`/usr/lib/jvm/temurin-21`)를 유지한 채 신규 버전을 별도 디렉터리에 설치하고, 검증 후에만 링크를 원자적으로 전환합니다.

- **주요 기능**: 사전 환경/아카이브 검증(path traversal 차단, SHA-256 선택 검증), 버전 다운그레이드 방지, 원자적 심볼릭 링크 전환, 전환 후 검증 실패 시 자동 롤백, 기존 JDK 자동 삭제 없음
- **사용 사례**: Temurin JDK 21 마이너 버전 업데이트, Minecraft 등 tar.gz 기반 Java 애플리케이션 서버 유지보수
- **지원 환경**: Rocky Linux 9.x (RHEL 계열), tar.gz로 수동 설치한 Eclipse Temurin JDK 21 (RPM/DNF 설치 환경은 미지원)

### 데이터베이스

#### [DB Migration (Migris)](scripts/db-migration/)
운영 중인 MariaDB의 스키마 및 데이터를 안전하게 마이그레이션하는 스크립트입니다. 실행 전 자동 백업, 중복 실행 방지, 트랜잭션 기반 안전한 변경 적용을 지원합니다.

- **주요 기능**: 실행 전 전체 DB 자동 백업, 중복 쿼리 스킵(테이블/컬럼/인덱스/레코드), 멀티라인 SQL 지원, 실행 결과 로그 자동 생성
- **사용 사례**: 운영 DB 스키마 변경, 참조 데이터 삽입, 무중단 데이터 마이그레이션
- **지원 환경**: Rocky Linux 8, 9 (RHEL 계열), MariaDB 10.11.7 이상

### 데이터 처리

#### [File Filter](scripts/file-filter/)
설정 파일(conf) 기반으로 CSV / TXT / DAT 파일을 조건 필터링하는 스크립트입니다. 원본을 `_origin`으로 보존하고 필터링 결과로 원본 파일을 교체하며, crontab 자동화에 적합합니다.

- **주요 기능**: 다중 파일·다중 조건 필터링, 구분자 conf 설정(쉼표/파이프/탭/공백), AND/OR 조건 조합, 원본 자동 백업
- **사용 사례**: 정기적인 데이터 정제, 특정 코드 행만 추출, crontab 기반 자동 필터링
- **지원 환경**: 모든 Linux 배포판 (순수 bash, 외부 의존성 없음)

### 고가용성 (HA)

#### [Keepalive Guardian](scripts/keepalive-guardian/)
L4 스위치 없이 Keepalived VRRP 기반으로 Active-Standby HA 환경을 자동 구성하는 스크립트입니다. 두 서버에서 각각 `install.sh`를 실행하면 VIP Failover 구성이 완료됩니다.

- **주요 기능**: VRRP 기반 VIP 자동 Failover, 포트/프로세스 헬스체크, 안정화 시간 기반 Failback, Heartbeat 전용 링크 지원 (Split-Brain 방지), 오프라인 RPM 설치 지원
- **사용 사례**: L4 없이 서버 이중화, Active-Standby HA 구성, 서비스 장애 자동 전환
- **지원 환경**: Rocky Linux 8, 9 (RHEL 계열)

## 다운로드

### 스크립트별 개별 다운로드

Git 없이 원하는 스크립트만 ZIP 파일로 바로 다운로드할 수 있습니다.

| 스크립트 | 다운로드 |
|---------|---------|
| System Status Monitoring | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/system-monitoring) |
| NIC Bonding Configuration | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/network-bonding) |
| React/Next.js Vulnerability Check | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/vulnerabilty-check) |
| OpenSSL/OpenSSH Security Patch | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/ssl_ssh_patch) |
| Kernel Security Patch | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/kernel_patch) |
| Java (Temurin) Update | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/java-update) |
| Keepalive Guardian | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/keepalive-guardian) |
| DB Migration (Migris) | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/db-migration) |
| File Filter | [ZIP 다운로드](https://download-directory.github.io/?url=https://github.com/HelloJamong/linux-ez-kit/tree/main/scripts/file-filter) |

> **참고**: 다운로드 링크는 [download-directory.github.io](https://download-directory.github.io) 서비스를 이용합니다.
> 브라우저에서 링크를 클릭하면 ZIP 파일이 자동으로 다운로드됩니다.

### 전체 스크립트 다운로드 (Git 사용)

```bash
git clone https://github.com/HelloJamong/linux-ez-kit.git
```

## 설치 방법

### 개별 스크립트 설치

각 스크립트 디렉토리의 README.md를 참조하세요.

## 시스템 요구사항

- Linux OS (RHEL, CentOS, Rocky Linux, Ubuntu 등)
- Bash 4.0 이상
- 기본 유틸리티: `bc`, `awk`, `grep`, `sed`

## 프로젝트 구조

```
linux-ez-kit/
├── README.md                           # 이 파일
├── scripts/                            # 모든 스크립트
│   ├── system-monitoring/              # 시스템 모니터링 스크립트
│   │   ├── sys_status.sh
│   │   └── README.md
│   ├── network-bonding/                # 네트워크 본딩 구성 스크립트
│   │   ├── set_bonding.sh
│   │   ├── bonding.conf
│   │   └── README.md
│   ├── vulnerabilty-check/             # 취약점 검사 스크립트
│   │   ├── check_react_nextjs_vulnerability.sh
│   │   └── README.md
│   ├── ssl_ssh_patch/                  # OpenSSL/OpenSSH 보안 패치 스크립트
│   │   ├── patch_script.sh
│   │   ├── openssh/                    # OpenSSH 패키지 RPM
│   │   ├── openssl/                    # OpenSSL 패키지 RPM
│   │   └── README.md
│   ├── kernel_patch/                   # 커널 보안 패치 스크립트
│   │   ├── patch_script.sh
│   │   ├── kernel/                     # 커널 패키지 RPM
│   │   └── README.md
│   ├── java-update/                    # tar.gz 설치 Temurin JDK 업데이트 스크립트
│   │   ├── update-java.sh
│   │   └── README.md
│   └── keepalive-guardian/             # Keepalived 기반 Active-Standby HA 구성
│       ├── install.sh                  # 설치 자동화 스크립트 (대화형 / 비대화형)
│       ├── README.md
│       ├── FAILOVER_SCENARIOS.md       # 장애 전환 시나리오 문서
│       ├── MAINTENANCE_MODE_SCENARIOS.md # 점검 모드 작업 시나리오 문서
│       ├── conf/                       # 설정 파일
│       │   ├── install.conf            # 비대화형 설치용 설정 파일
│       │   ├── keepalived.conf.template # Keepalived VRRP 설정 템플릿
│       │   └── service_check.conf      # 헬스체크 대상 설정 (포트/프로세스/DB)
│       ├── scripts/                    # 동작 스크립트
│       │   ├── service_health_check.sh    # 헬스체크 스크립트 (Failover 판정)
│       │   ├── service_recovery_check.sh  # MASTER 승격 알림 스크립트
│       │   ├── service_maintenance_mode.sh # 계획 점검 모드 제어 스크립트
│       │   └── download_keepalived_rpms.sh # RPM 패키지 갱신 스크립트
│       └── install_package/            # 오프라인 설치용 RPM 패키지
│   ├── db-migration/                   # MariaDB 스키마/데이터 마이그레이션
│   │   ├── migris.sh                   # 마이그레이션 메인 스크립트
│   │   ├── all_query.txt.sample        # 마이그레이션 쿼리 샘플
│   │   └── README.md
│   └── file-filter/                    # conf 기반 텍스트 파일 필터링
│       ├── file_filter.sh              # 메인 스크립트
│       ├── filter.conf.sample          # 설정 파일 샘플
│       └── README.md
```
