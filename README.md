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

## 설치 방법

### 전체 스크립트 설치

```bash
# 저장소 클론
git clone https://github.com/HelloJamong/linux-ez-kit.git
cd linux-ez-kit

# 원하는 스크립트를 /usr/local/bin에 복사
sudo cp scripts/system-monitoring/sys_status.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/sys_status.sh
```

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
│   └── network-bonding/                # 네트워크 본딩 구성 스크립트
│       ├── set_bonding.sh
│       ├── bonding.conf
│       └── README.md
```
