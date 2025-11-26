# NIC Bonding Configuration

Rocky Linux 환경에서 네트워크 본딩(Network Bonding)을 자동으로 구성하는 스크립트입니다. Active-Backup 모드를 사용하여 네트워크 가용성과 안정성을 향상시킵니다.

## 주요 기능

- **자동 본딩 구성**: bond0 및 bond1 인터페이스를 자동으로 생성 및 구성
- **백업 및 복구**: 구성 적용 전 자동 백업, 필요시 원상복구 가능
- **유효성 검증**: 인터페이스 존재 여부, IP 주소 형식 등을 사전 검증
- **안전한 복구 스크립트**: 각 백업마다 자동으로 복구 스크립트 생성

## 시스템 요구사항

- Rocky Linux (RHEL 계열)
- NetworkManager 실행 중
- Root 권한
- 본딩에 사용할 물리 네트워크 인터페이스

## 파일 구성

```
network-bonding/
├── set_bonding.sh       # 본딩 구성 메인 스크립트
├── bonding.conf         # 본딩 설정 파일
└── README.md            # 이 문서
```

## 본딩 모드

이 스크립트는 **Active-Backup 모드**를 사용합니다:

- **모드**: `mode=active-backup`
- **특징**: 한 번에 하나의 인터페이스만 활성화, 장애 발생 시 자동 전환
- **링크 모니터링**: `miimon=100` (100ms 간격으로 링크 상태 확인)
- **MAC 주소 정책**: `fail_over_mac=active` (활성 슬레이브의 MAC 주소 사용)

## 설정 방법

### 1. 설정 파일 편집

`bonding.conf` 파일을 환경에 맞게 수정합니다:

```bash
# BOND0 구성 (일반 네트워크 연결용)
BOND0_ENABLED=yes                    # yes 또는 no
BOND0_PRIMARY_NIC=eth0              # 주 인터페이스
BOND0_SECONDARY_NIC=eth1            # 보조 인터페이스
BOND0_IP=192.168.10.131             # IP 주소
BOND0_PREFIX=24                     # 서브넷 마스크 (CIDR)
BOND0_GATEWAY=192.168.10.1          # 게이트웨이
BOND0_DNS=8.8.8.8                   # DNS 서버 (선택사항)

# BOND1 구성 (브리지 슬레이브용)
BOND1_ENABLED=yes                    # yes 또는 no
BOND1_PRIMARY_NIC=eth2              # 주 인터페이스
BOND1_SECONDARY_NIC=eth3            # 보조 인터페이스
BOND1_BRIDGE_MASTER=br0             # 연결할 브리지 인터페이스
```

### 2. 인터페이스 확인

본딩에 사용할 인터페이스 이름을 확인합니다:

```bash
ip link show
# 또는
nmcli device status
```

### 3. 스크립트 실행

```bash
sudo ./set_bonding.sh
```

## 사용 방법

### 기본 실행 (본딩 구성)

```bash
sudo ./set_bonding.sh
```

실행 시:
1. 현재 네트워크 설정을 자동으로 백업합니다
2. 설정 파일의 내용을 요약하여 표시합니다
3. 계속 진행 여부를 확인합니다 (yes 입력 필요)
4. 설정을 검증하고 본딩을 구성합니다

### 백업 목록 확인

```bash
sudo ./set_bonding.sh --list-backups
```

사용 가능한 모든 백업 목록과 생성 시간을 표시합니다.

### 백업에서 복구

```bash
sudo ./set_bonding.sh --restore <타임스탬프>
```

예시:
```bash
sudo ./set_bonding.sh --restore 20250126_143022
```

또는 백업 디렉토리에서 직접 실행:
```bash
cd /backup/nic_info_backup/20250126_143022
sudo ./restore.sh
```

### 도움말 표시

```bash
sudo ./set_bonding.sh --help
```

## 백업 시스템

### 백업 위치

백업은 다음 위치에 타임스탬프 폴더로 저장됩니다:
```
/backup/nic_info_backup/YYYYMMDD_HHMMSS/
```

### 백업 내용

각 백업에는 다음 정보가 포함됩니다:

- NetworkManager 연결 정보 (`nmcli_connections.txt`)
- 상세 연결 설정 (`connection_*.txt`)
- 연결 설정 파일 (`system-connections/`, `network-scripts/`)
- 네트워크 인터페이스 상태 (`ip_addr.txt`, `ip_link.txt`, `ip_route.txt`)
- 기존 본딩 설정 (`bonding/`)
- 백업 정보 및 복구 방법 (`backup_info.txt`)
- 자동 생성된 복구 스크립트 (`restore.sh`)

## 본딩 구성 유형

### BOND0 - 일반 네트워크 연결

- 고정 IP 주소 할당
- 게이트웨이 및 DNS 설정 포함
- 일반적인 서버 관리 네트워크로 사용

### BOND1 - 브리지 슬레이브

- IP 주소 없음 (브리지가 IP 관리)
- 기존 브리지 인터페이스에 연결
- 가상화 환경의 VM 네트워크로 주로 사용

## 동작 확인

### 본딩 상태 확인

```bash
# 본딩 상세 정보
cat /proc/net/bonding/bond0
cat /proc/net/bonding/bond1

# 연결 상태
nmcli connection show

# 인터페이스 상태
ip addr show bond0
ip addr show bond1
```

### 장애 전환 테스트

Primary 인터페이스를 다운시켜 장애 전환을 테스트:

```bash
# Primary 인터페이스 다운
sudo ip link set eth0 down

# 본딩 상태 확인 (secondary로 전환되었는지 확인)
cat /proc/net/bonding/bond0

# Primary 인터페이스 복구
sudo ip link set eth0 up
```

## 문제 해결

### 스크립트 실행 권한 오류

```bash
chmod +x set_bonding.sh
```

### 인터페이스를 찾을 수 없음

- `ip link show` 명령으로 실제 인터페이스 이름 확인
- `bonding.conf` 파일의 인터페이스 이름 수정

### 구성 적용 후 네트워크 연결 끊김

```bash
# 가장 최근 백업에서 복구
sudo ./set_bonding.sh --list-backups
sudo ./set_bonding.sh --restore <최근_타임스탬프>
```

### NetworkManager 문제

```bash
# NetworkManager 재시작
sudo systemctl restart NetworkManager

# 연결 다시 로드
sudo nmcli connection reload

# 본딩 연결 활성화
sudo nmcli connection up bond0
```

## 주의사항

1. **Root 권한 필수**: 스크립트는 반드시 root 권한으로 실행해야 합니다
2. **원격 접속 주의**: 원격으로 접속 중이라면 본딩 구성 시 연결이 끊길 수 있습니다
3. **백업 확인**: 구성 전 항상 백업이 정상적으로 생성되었는지 확인하세요
4. **설정 검증**: 실행 전 `bonding.conf` 파일의 모든 값을 신중히 검토하세요
5. **테스트 환경**: 가능하면 프로덕션 환경에 적용하기 전에 테스트 환경에서 먼저 테스트하세요

## 장애 상황 대응

### 원격 접속 끊김

1. 물리적 또는 콘솔 접속을 통해 서버 접근
2. 백업에서 복구:
   ```bash
   cd /backup/nic_info_backup/<최근_백업>
   sudo ./restore.sh
   ```

### 본딩 구성 제거

백업에서 복구하여 본딩 이전 상태로 되돌립니다:

```bash
sudo ./set_bonding.sh --restore <타임스탬프>
```

## 기술 세부사항

### 본딩 옵션 설명

- `mode=active-backup`: 액티브-백업 모드 (고가용성)
- `miimon=100`: 100ms마다 링크 상태 확인
- `fail_over_mac=active`: 활성 슬레이브의 MAC 주소 사용
- `primary=<interface>`: 우선적으로 사용할 인터페이스

### NetworkManager 설정

스크립트는 `nmcli` 명령을 사용하여 NetworkManager를 통해 본딩을 구성합니다:

- 본딩 마스터 인터페이스 생성
- 슬레이브 인터페이스를 본딩에 추가
- IP 및 네트워크 설정 적용
- 자동 연결 및 슬레이브 자동 활성화 설정

## 라이선스

이 스크립트는 MIT 라이선스 하에 제공됩니다.

## 지원

문제가 발생하거나 개선 사항이 있으면 이슈를 등록해 주세요.
