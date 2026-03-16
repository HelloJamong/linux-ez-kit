# Keepalive Guardian - Active-Standby HA System

L4 장비 없이 Keepalived를 이용하여 Active-Standby 방식의 서비스 이중화 환경을 구축하는 자동화 스크립트입니다.

## 주요 기능

- **VIP 기반 Failover**: Keepalived VRRP를 이용한 가상 IP 자동 이동
- **다층 헬스 체크**: 서비스 포트, 프로세스, DB 복제 상태를 종합 점검
- **DB 복제 모니터링**: MySQL/MariaDB replication 상태 및 지연 시간 확인
- **안정화 기반 Failback**: 복구 후 지정 시간 동안 연속 정상 확인 후 자동 원복
- **자동 백업 및 복구**: 설정 적용 전 자동 백업 및 복구 스크립트 생성
- **환경별 설정 분리**: 서비스 포트, 프로세스, DB 정보를 외부 파일로 관리

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

## 시스템 요구사항

- Rocky Linux 8, 9 또는 RHEL 계열
- Keepalived 패키지
- Root 권한
- 동일 L2 네트워크의 서버 2대
- (선택) MySQL/MariaDB replication 구성

## 파일 구성

```
keepalive-guardian/
├── README.md                         # 사용 가이드 (이 문서)
├── IMPLEMENTATION_SPEC.md            # 구현 정의서 (참고 문서)
├── install.sh                        # 설치 자동화 스크립트
├── keepalived.conf.template          # Keepalived 설정 템플릿
├── service_check.conf                # 환경 변수 설정 파일
├── service_health_check.sh           # 장애 판정 스크립트
└── service_recovery_check.sh         # Failback 안정화 체크 스크립트
```

## 장애 판정 기준

다음 조건 중 **하나라도 실패하면 장애로 판정**하여 Failover가 발생합니다:

| 항목 | 체크 방법 | 정상 조건 |
|------|-----------|-----------|
| 포트 체크 | TCP 연결 시도 | 설정된 모든 포트 접근 가능 |
| 프로세스 체크 | `pgrep -f <process>` | 설정된 모든 프로세스 실행 중 |
| DB 복제 상태 | `SHOW REPLICA STATUS` | IO/SQL thread 정상, lag < 임계값 |
| 서버 네트워크 | VRRP advertisement | Keepalived 정상 송신 |

## 설치 및 구성

### 1. 설정 파일 편집

`service_check.conf` 파일을 환경에 맞게 수정합니다:

```bash
# 체크할 프로세스 목록
PROCESS_LIST=(nginx mysqld)

# 체크할 포트 목록
PORT_LIST=(80 443 3306)

# 데이터베이스 접속 정보
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=healthcheck
DB_PASSWORD=your_password_here

# Failback 안정화 시간 (초)
FAILBACK_DELAY=300

# Replication lag 임계값 (초)
REPLICATION_LAG_LIMIT=30
```

### 2. Keepalived 설정 템플릿 편집

`keepalived.conf.template` 파일에서 VIP 및 우선순위를 설정합니다:

```bash
# Active 서버 (우선순위 높음)
VRRP_STATE=MASTER
VRRP_PRIORITY=100
VRRP_VIRTUAL_IP=192.168.10.100

# Standby 서버 (우선순위 낮음)
VRRP_STATE=BACKUP
VRRP_PRIORITY=90
VRRP_VIRTUAL_IP=192.168.10.100
```

### 3. 설치 스크립트 실행

**Active 서버에서 실행:**

```bash
sudo ./install.sh --role active
```

**Standby 서버에서 실행:**

```bash
sudo ./install.sh --role standby
```

설치 스크립트는 다음 작업을 자동으로 수행합니다:

1. Keepalived 패키지 설치 확인
2. 설정 파일 백업
3. 헬스 체크 스크립트 배치 (`/usr/local/bin/`)
4. Keepalived 설정 파일 생성 (`/etc/keepalived/`)
5. 환경 설정 파일 복사 (`/etc/keepalived/service_check.conf`)
6. Keepalived 서비스 시작 및 자동 시작 설정

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
# 장애 판정 스크립트
sudo /usr/local/bin/service_health_check.sh
echo $?  # 0: 정상, 1: 장애

# Failback 안정화 스크립트
sudo /usr/local/bin/service_recovery_check.sh
echo $?  # 0: 안정화 완료, 1: 안정화 중
```

### HA 로그 확인

```bash
# 실시간 로그 모니터링
tail -f /var/log/service_ha_check.log

# 최근 Failover/Failback 이벤트 확인
grep -E "FAILOVER|FAILBACK|PRIORITY" /var/log/service_ha_check.log
```

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
1. Active 서버 복구 (서비스/프로세스/DB 정상)
2. 헬스 체크 연속 성공
3. 안정화 시간 동안 연속 정상 유지 (기본 300초)
4. Keepalived priority 원복
5. VIP가 Active 서버로 복귀
```

**주의**: 즉시 Failback하지 않고 안정화 시간을 두어 서비스 안정성을 확보합니다.

## 테스트 시나리오

### 1. 서비스 장애 시뮬레이션

Active 서버에서 서비스 중지:

```bash
# 웹 서버 중지
sudo systemctl stop nginx

# VIP 이동 확인 (Standby 서버로 이동)
ip addr show | grep <VIP>

# Standby 서버에서 VIP 확인
ip addr show | grep <VIP>
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

# 안정화 시간 대기 (기본 5분)
# 5분 후 VIP가 Active 서버로 복귀 확인
ip addr show | grep <VIP>
```

## 문제 해결

### VIP가 이동하지 않는 경우

**원인 1: Keepalived 서비스 미실행**

```bash
# 서비스 상태 확인
sudo systemctl status keepalived

# 서비스 시작
sudo systemctl start keepalived
```

**원인 2: 방화벽에서 VRRP 차단**

```bash
# VRRP 프로토콜 허용 (protocol 112)
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

### DB 복제 체크 실패

**원인: DB 접속 권한 부족**

```sql
-- healthcheck 사용자 생성 및 권한 부여
CREATE USER 'healthcheck'@'localhost' IDENTIFIED BY 'password';
GRANT REPLICATION CLIENT ON *.* TO 'healthcheck'@'localhost';
FLUSH PRIVILEGES;
```

### Failback이 발생하지 않는 경우

**원인: 안정화 시간 미달**

```bash
# 안정화 타이머 상태 확인
cat /tmp/service_recovery_timer

# service_check.conf에서 FAILBACK_DELAY 조정
# (너무 길면 Failback이 지연됨)
```

## 주의사항

### 1. 네트워크 분리 환경

- Active와 Standby 서버는 **동일 L2 네트워크**에 위치해야 합니다
- VRRP 멀티캐스트 통신이 가능해야 합니다

### 2. Split-Brain 방지

- 네트워크 단절 시 두 서버가 모두 MASTER가 될 수 있습니다
- 이를 방지하려면 추가적인 fence 장치나 quorum 설정이 필요합니다

### 3. 데이터베이스 동기화

- DB Replication 구성이 없으면 `service_check.conf`에서 DB 체크를 비활성화하세요
- Replication lag이 크면 Failover가 빈번하게 발생할 수 있습니다

### 4. 원격 작업 주의

- Keepalived 설정 변경 시 VIP가 이동할 수 있습니다
- **반드시 콘솔 접근이 가능한 상태에서 작업**하세요

### 5. 백업 확인

- 설치 전 백업이 `/backup/keepalive-guardian/backup_YYYYMMDD_HHMMSS/`에 생성됩니다
- 복구가 필요하면 백업 디렉토리의 `restore.sh` 스크립트를 실행하세요

## 로그 위치

| 로그 파일 | 설명 |
|-----------|------|
| `/var/log/service_ha_check.log` | 헬스 체크 및 HA 이벤트 로그 |
| `/var/log/messages` | Keepalived 시스템 로그 |
| `journalctl -u keepalived` | Keepalived 서비스 로그 |

## 참고 자료

- [Keepalived 공식 문서](https://www.keepalived.org/documentation.html)
- [VRRP Protocol RFC 5798](https://tools.ietf.org/html/rfc5798)
- [IMPLEMENTATION_SPEC.md](./IMPLEMENTATION_SPEC.md) - 구현 정의서

## 라이선스

MIT License

## 작성자

HelloJamong
