# Keepalive Guardian - Active-Standby HA System

L4 장비 없이 Keepalived를 이용하여 Active-Standby 방식의 서비스 이중화 환경을 구축하는 자동화 스크립트입니다.

## 주요 기능

- **VIP 기반 Failover**: Keepalived VRRP를 이용한 가상 IP 자동 이동
- **헬스 체크**: 서비스 포트 및 프로세스 실행 여부 종합 점검
- **안정화 기반 Failback**: 복구 후 지정 시간 동안 연속 정상 확인 후 자동 원복
- **자동 백업 및 복구**: 설정 적용 전 자동 백업 및 복구 스크립트 생성
- **환경별 설정 분리**: 서비스 포트, 프로세스 정보를 외부 파일로 관리

---

## 시스템 구성

```
                 Client / Admin User
                         |
                         |
                   Virtual IP (VIP)
                         |
            +---------------------------+
            |                           |
         Active Server              Standby Server
         Rocky Linux                Rocky Linux
         keepalived                 keepalived
         (VIP 보유)                (BACKUP 상태)
            |                           |
       +---------+                 +---------+
       | Service |                 | Service |
       | Process |                 | Process |
       +---------+                 +---------+
            |                           |
       +----------+  <-- Replication --> +----------+
       | Database |                      | Database |
       +----------+                      +----------+
```

- 사용자 접근은 **Virtual IP(VIP)** 를 통해 이루어집니다
- Active 서버 장애 시 **Standby 서버가 VIP를 자동 인계**합니다
- 데이터베이스는 **양방향 Replication** 구조로 동기화됩니다
- 두 서버 간 VRRP 통신은 **유니캐스트** 방식으로 동작합니다

---

## 시스템 요구사항

- Rocky Linux 8, 9 또는 RHEL 계열
- Root 권한
- 동일 L2 네트워크의 서버 2대
---

## 파일 구성

```
keepalive-guardian/
├── README.md                         # 사용 가이드 (이 문서)
├── IMPLEMENTATION_SPEC.md            # 구현 정의서 (참고 문서)
├── install.sh                        # 설치 자동화 스크립트 (메인)
├── conf/                             # 설정 파일
│   ├── install.conf                  # 비대화형 설치 설정 파일
│   ├── keepalived.conf.template      # Keepalived 설정 템플릿
│   └── service_check.conf            # 헬스체크 환경 변수 설정 파일
├── scripts/                          # 동작 스크립트
│   ├── check_environment.sh          # 환경 점검 및 RPM 설치 스크립트 (선택)
│   ├── download_keepalived_rpms.sh   # RPM 패키지 다운로드 스크립트 (온라인 환경용)
│   ├── service_health_check.sh       # 장애 판정 스크립트
│   └── service_recovery_check.sh     # MASTER 승격 알림 스크립트
└── install_package/                  # 오프라인 설치용 RPM 패키지
    ├── keepalived-*.rpm
    └── (의존성 패키지)
```

---

## 장애 판정 기준

다음 조건 중 **하나라도 실패하면 장애로 판정**하여 Failover가 발생합니다:

| 항목 | 체크 방법 | 정상 조건 |
|------|-----------|-----------|
| 포트 체크 | TCP 연결 시도 | 설정된 모든 포트 접근 가능 |
| 프로세스 체크 | `pgrep -f <process>` | 설정된 모든 프로세스 실행 중 |
| 서버 네트워크 | VRRP advertisement | Keepalived 정상 송신 |

---

## 설치 및 구성

### 사전 준비 — 방화벽 VRRP 허용

Keepalived는 TCP/UDP 포트가 아닌 **IP Protocol 112 (VRRP)** 를 사용합니다.
두 서버 모두 VRRP 프로토콜을 방화벽에서 허용해야 합니다.

```bash
# VRRP 프로토콜 허용 (양쪽 서버 모두 실행)
sudo firewall-cmd --add-rich-rule='rule protocol value="vrrp" accept' --permanent
sudo firewall-cmd --reload

# 적용 확인
firewall-cmd --list-rich-rules | grep vrrp
```

> **참고**: `install.sh` 실행 시 firewalld가 동작 중이면 위 규칙이 자동으로 추가됩니다.
> firewalld를 사용하지 않는 환경이거나 사전에 방화벽 정책을 일괄 적용하는 경우에는 위 명령어를 수동으로 실행하세요.

---

### 1. 헬스체크 설정 파일 편집

`conf/service_check.conf` 파일을 환경에 맞게 수정합니다 (양쪽 서버 동일하게 적용):

```bash
# 체크할 프로세스 목록
PROCESS_LIST=(nginx mysqld)

# 체크할 포트 목록
PORT_LIST=(80 443 3306)

# Failback 안정화 시간 (초, 권장 60초 이상)
FAILBACK_DELAY=300
```

---

### 2. 설치 스크립트 실행

#### 대화형 설치 (기본)

실행 중 VIP, 서버 역할, 인터페이스 등을 직접 입력합니다.
`service_check.conf` 현재 설정을 확인하고 편집할 수 있는 검토 단계가 포함됩니다.

```bash
sudo ./install.sh
```

#### 비대화형 설치 (설정 파일 사용)

`conf/install.conf` 파일을 미리 편집한 후 실행합니다.

```bash
# install.conf 편집 (Active 서버)
vi conf/install.conf
# ROLE=active
# VIP=192.168.0.100
# PEER_IP=192.168.0.20   ← Standby 서버 IP
# AUTH_PASSWORD=KAGrd251  ← 양쪽 동일하게 설정

# Active 서버에서 실행
sudo ./install.sh --config conf/install.conf

# install.conf 편집 (Standby 서버)
# ROLE=standby
# VIP=192.168.0.100
# PEER_IP=192.168.0.10   ← Active 서버 IP
# AUTH_PASSWORD=KAGrd251  ← 양쪽 동일하게 설정

# Standby 서버에서 실행
sudo ./install.sh --config conf/install.conf

# 확인 프롬프트 없이 자동 진행
sudo ./install.sh --config conf/install.conf --yes
```

`conf/install.conf` 주요 설정 항목:

| 항목 | 설명 | Active | Standby |
|------|------|--------|---------|
| `ROLE` | 서버 역할 | `active` | `standby` |
| `VIP` | 가상 IP | 동일 | 동일 |
| `PEER_IP` | 상대 서버 IP | Standby IP | Active IP |
| `AUTH_PASSWORD` | VRRP 인증 패스워드 (최대 8자) | 동일 | 동일 |
| `VRRP_INTERFACE` | 네트워크 인터페이스 | 미설정 시 자동 감지 | 미설정 시 자동 감지 |

---

설치 스크립트는 다음 작업을 자동으로 수행합니다:

1. keepalived 패키지 설치 확인 및 설치 (`install_package/` RPM 사용)
2. 사전 조건 확인 (Root 권한, OS, keepalived 설치 여부)
3. `service_check.conf` 설정 검토 (대화형 모드)
4. 설치 정보 입력 (대화형) 또는 설정 파일 로드 (비대화형)
5. 기존 설정 파일 백업 (`/backup/keepalive-guardian/backup_YYYYMMDD_HHMMSS/`)
6. `keepalived.conf` 생성 (`/etc/keepalived/keepalived.conf`)
7. `service_check.conf` 배포 (`/etc/keepalived/service_check.conf`)
8. 헬스체크 스크립트 배포 (`/usr/local/bin/`)
9. 방화벽 VRRP 허용 (firewalld 사용 시 자동)
10. 로그 로테이션 설정 (`/etc/logrotate.d/service-ha-check`)
11. keepalived 서비스 시작 및 자동 시작 등록
12. 설치 결과 검증

---

## RPM 패키지 갱신 (download_keepalived_rpms.sh)

`install_package/` 폴더에는 Rocky Linux 9 기준 RPM이 사전 포함되어 있어 별도 다운로드 없이 설치 가능합니다.
아래 상황에서는 `scripts/download_keepalived_rpms.sh` 를 사용하여 RPM을 새로 수집합니다.

| 상황 | 설명 |
|------|------|
| keepalived 버전 업데이트 | 최신 버전 RPM 재수집 |
| Rocky Linux 8 환경 적용 | 현재 포함된 RPM은 Rocky 9 기준 |

> **주의**: 반드시 **온라인 환경**의 Rocky Linux 서버에서 실행해야 합니다.

### 사용법

```bash
# Keepalived RPM 다운로드
sudo ./scripts/download_keepalived_rpms.sh
```

### 실행 후 처리

```bash
# 1. 다운로드된 RPM을 install_package/ 로 복사
cp keepalived-rpms-rocky9/*.rpm install_package/

# 2. 오프라인 서버로 프로젝트 전체 전송
scp -r keepalive-guardian/ user@offline-server:/tmp/

# 3. 오프라인 서버에서 설치
sudo ./install.sh
```

---

## 설치 후 파일 배치 위치

```
/etc/keepalived/
├── keepalived.conf          # VRRP 설정 (install.sh 자동 생성)
└── service_check.conf       # 헬스체크 설정 (권한 600)

/usr/local/bin/
├── service_health_check.sh      # 장애 판정 스크립트
└── service_recovery_check.sh    # MASTER 승격 알림 스크립트

/var/log/
└── service_ha_check.log         # HA 이벤트 로그

/etc/logrotate.d/
└── service-ha-check             # 로그 로테이션 설정 (30일 보관)

/backup/keepalive-guardian/
└── backup_YYYYMMDD_HHMMSS/      # 설치 전 자동 백업
    ├── keepalived.conf
    ├── service_check.conf
    ├── service_health_check.sh
    ├── service_recovery_check.sh
    └── restore.sh               # 자동 생성된 복구 스크립트
```

---

## 설치 후 설정 변경

| 변경 항목 | 수정 파일 | 적용 방법 |
|----------|----------|---------|
| 감시 포트 / 프로세스 | `/etc/keepalived/service_check.conf` | `systemctl restart keepalived` |
| Failback 대기 시간 | `/etc/keepalived/service_check.conf` | `systemctl restart keepalived` |
| VIP / 서버 IP | `/etc/keepalived/keepalived.conf` | 양쪽 서버 중지 후 수정 → 재시작 |
| VRRP 패스워드 | `/etc/keepalived/keepalived.conf` | 양쪽 서버 동시에 수정 → 재시작 |
| 장애 판정 로직 | `/usr/local/bin/service_health_check.sh` | `systemctl restart keepalived` |

> **VIP / VRRP 패스워드 변경 시 주의**: 양쪽 서버를 동시에 중지한 후 수정하고 재시작해야 합니다.
> 한쪽만 변경하면 VRRP 통신이 단절되어 VIP 동작이 불안정해집니다.

설정 변경이 많거나 재설치가 필요한 경우 `install.sh` 재실행을 권장합니다.
기존 설정이 자동 백업된 후 새 설정이 적용됩니다.

```bash
sudo ./install.sh --config conf/install.conf
```

---

## 동작 확인

### Keepalived 상태 확인

```bash
# Keepalived 서비스 상태
sudo systemctl status keepalived

# VIP 할당 확인
ip addr show | grep <VIP>

# Keepalived 로그 확인
sudo journalctl -u keepalived -f
```

### 헬스 체크 스크립트 수동 실행

```bash
# 장애 판정 스크립트 (0: 정상, 1: 장애)
sudo /usr/local/bin/service_health_check.sh
echo $?
```

### HA 로그 확인

```bash
# 실시간 로그 모니터링
tail -f /var/log/service_ha_check.log

# Failover/Failback 이벤트만 확인
grep -E "MASTER|RECOVERY|FAIL" /var/log/service_ha_check.log
```

---

## Failover/Failback 동작

### Failover (장애 발생 시)

```
1. Active 서버에서 헬스 체크 실패
2. Keepalived priority 하락 (weight 감소)
3. Standby 서버가 MASTER로 승격
4. VIP가 Standby 서버로 이동
5. 사용자 트래픽 자동 전환
```

### Failback (복구 시)

```
1. Active 서버 복구 (서비스/프로세스 정상)
2. 헬스 체크 연속 성공
3. 안정화 시간 동안 연속 정상 유지 (기본 300초)
4. Keepalived priority 원복
5. VIP가 Active 서버로 복귀
```

> **참고**: 즉시 Failback하지 않고 안정화 시간을 두어 서비스 안정성을 확보합니다.

---

## 테스트 시나리오

### 1. 서비스 장애 시뮬레이션

Active 서버에서 서비스 중지:

```bash
# 웹 서버 중지
sudo systemctl stop nginx

# 헬스체크 확인
sudo /usr/local/bin/service_health_check.sh; echo "exit: $?"

# VIP 이동 확인 (Standby 서버로 이동 대기)
watch -n 2 "ip addr show | grep <VIP>"
```

### 2. 프로세스 장애 시뮬레이션

```bash
# 프로세스 강제 종료
sudo killall -9 mysqld

# Failover 발생 확인
tail -f /var/log/service_ha_check.log
```

### 3. Failback 테스트

```bash
# Active 서버에서 서비스 재시작
sudo systemctl start nginx
sudo systemctl start mysqld

# 안정화 타이머 진행 상황 확인
tail -f /var/log/service_ha_check.log

# 안정화 완료 후 VIP 복귀 확인
ip addr show | grep <VIP>
```

---

## 문제 해결

### VIP가 이동하지 않는 경우

**원인 1: Keepalived 서비스 미실행**

```bash
sudo systemctl status keepalived
sudo systemctl start keepalived
```

**원인 2: 방화벽에서 VRRP 차단**

```bash
sudo firewall-cmd --add-rich-rule='rule protocol value="vrrp" accept' --permanent
sudo firewall-cmd --reload
```

**원인 3: 헬스 체크 스크립트 오류**

```bash
# 스크립트 수동 실행 및 디버깅
sudo bash -x /usr/local/bin/service_health_check.sh

# 로그 확인
tail -50 /var/log/service_ha_check.log
```

**원인 4: 양쪽 서버 VRRP 패스워드 불일치**

```bash
sudo grep auth_pass /etc/keepalived/keepalived.conf
```

---

### Failback이 발생하지 않는 경우

**원인: 안정화 시간 미달**

```bash
# 안정화 타이머 상태 확인
cat /tmp/keepalive_recovery_timer

# FAILBACK_DELAY 조정 (너무 길면 Failback이 지연됨)
sudo vi /etc/keepalived/service_check.conf
sudo systemctl restart keepalived
```

---

## 주의사항

### 1. 네트워크 환경

- Active와 Standby 서버는 **동일 L2 네트워크**에 위치해야 합니다
- VRRP 통신은 유니캐스트 방식으로 동작합니다 (멀티캐스트 불필요)

### 2. Split-Brain 방지

- 네트워크 단절 시 두 서버가 모두 MASTER가 될 수 있습니다
- 이를 방지하려면 추가적인 fence 장치나 quorum 설정이 필요합니다

### 3. 원격 작업 주의

- Keepalived 설정 변경 시 VIP가 이동할 수 있습니다
- **반드시 콘솔 접근이 가능한 상태에서 작업**하세요

### 4. 백업 및 복구

- 설치/재설치 시 기존 설정이 `/backup/keepalive-guardian/backup_YYYYMMDD_HHMMSS/`에 자동 백업됩니다
- 복구가 필요하면 백업 디렉토리의 `restore.sh`를 실행하세요

```bash
sudo /backup/keepalive-guardian/backup_YYYYMMDD_HHMMSS/restore.sh
```

---

## 로그 위치

| 로그 파일 | 설명 |
|-----------|------|
| `/var/log/service_ha_check.log` | 헬스 체크 및 HA 이벤트 로그 (30일 로테이션) |
| `journalctl -u keepalived` | Keepalived 서비스 로그 |

---

## 참고 자료

- [Keepalived 공식 문서](https://www.keepalived.org/documentation.html)
- [VRRP Protocol RFC 5798](https://tools.ietf.org/html/rfc5798)
- [IMPLEMENTATION_SPEC.md](./IMPLEMENTATION_SPEC.md) - 구현 정의서

---

## 라이선스

MIT License

## 작성자

HelloJamong
