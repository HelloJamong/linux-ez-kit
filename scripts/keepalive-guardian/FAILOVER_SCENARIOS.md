# Keepalive Guardian - 장애 전환 시나리오

## 목차

1. [Failover 전환 방식](#1-failover-전환-방식)
2. [장애 유형별 전환 시나리오](#2-장애-유형별-전환-시나리오)
3. [Split-Brain 주의사항](#3-split-brain-주의사항)

---

## 1. Failover 전환 방식

keepalived는 두 가지 방법으로 장애를 감지하고 전환합니다.

### 1.1 헬스체크 기반 전환 (서비스/프로세스 장애)

`service_health_check.sh`가 keepalived의 `track_script`에 의해 주기적으로 실행됩니다.

```
헬스체크 실패
  → Active 서버 priority 하락 (100 - 20 = 80)
  → Standby priority(90) > Active priority(80)
  → Standby가 MASTER로 승격
  → VIP 이동
```

전환 감지 시간 = `HEALTH_CHECK_INTERVAL` × `HEALTH_CHECK_FALL`

예) interval=2, fall=5 → 약 10초 후 전환

---

### 1.2 VRRP Advertisement 기반 전환 (네트워크/서버 장애)

두 서버는 `advert_int(1초)` 간격으로 서로 **"나 살아있어"** 신호를 주고받습니다.

```
Active(123) ──── VRRP Advertisement (1초마다) ────▶ Standby(124)
Active(123) ◀─── VRRP Advertisement (1초마다) ──── Standby(124)
```

Active 서버로부터 신호가 끊기면 Standby가 자동으로 MASTER를 인계합니다.

전환 감지 시간 = `advert_int(1초)` × 3 = **약 3초**

> 헬스체크 기반 전환보다 훨씬 빠르게 동작합니다.

---

## 2. 장애 유형별 전환 시나리오

### 2.1 프로세스 / 포트 장애

```
[Active 서버]
  서비스 프로세스 종료 또는 포트 응답 불가
       ↓
  service_health_check.sh → exit 1
       ↓
  keepalived priority 하락 (100 → 80)
       ↓
  Standby priority(90) > Active priority(80)
       ↓
[Standby 서버]
  VRRP 우선순위 비교 → MASTER 승격
       ↓
  VIP 인계 + Gratuitous ARP 브로드캐스트
       ↓
  클라이언트 트래픽 자동 전환
```

**감지 시간**: 설치 시 설정한 장애 감지 시간(기본 10초)

---

### 2.2 네트워크 단절

```
[Active 서버]
  NIC 장애 또는 케이블 단선
       ↓
  VRRP Advertisement 송신 불가
       ↓
[Standby 서버]
  3초간 Advertisement 미수신
       ↓
  "Active 서버 없음" 판단 → MASTER 승격
       ↓
  VIP 인계 + Gratuitous ARP 브로드캐스트
```

**감지 시간**: 약 3초 (`advert_int=1` 기준)

---

### 2.3 서버 전원 다운 / OS Hang

```
[Active 서버]
  전원 차단 또는 OS 응답 불가
       ↓
  VRRP Advertisement 송신 중단
       ↓
[Standby 서버]
  3초간 Advertisement 미수신
       ↓
  MASTER 승격 → VIP 인계
```

**감지 시간**: 약 3초 (`advert_int=1` 기준)

> 서버/네트워크 장애는 헬스체크를 거치지 않고 VRRP 신호 중단만으로 즉시 감지됩니다.

---

### 2.4 장애 유형별 전환 시간 요약

| 장애 유형 | 감지 방법 | 전환 감지 시간 |
|-----------|-----------|---------------|
| 프로세스 / 포트 장애 | 헬스체크 실패 | 설정값 (기본 10초) |
| 네트워크 단절 | VRRP Advertisement 중단 | 약 3초 |
| 서버 전원 다운 | VRRP Advertisement 중단 | 약 3초 |
| OS Hang | VRRP Advertisement 중단 | 약 3초 |

---

## 3. Split-Brain 주의사항

### 3.1 Split-Brain이란

두 서버가 **서로 간의 통신은 단절**되었지만 **외부 네트워크는 각각 정상인 경우**,
두 서버가 모두 MASTER로 동작하며 VIP가 충돌하는 상황입니다.

```
정상 상태:
  Active(123) ◀────VRRP────▶ Standby(124)
       ↓                          ↓
    VIP 보유                  BACKUP 대기

Split-Brain 발생:
  Active(123) ✕────단절────✕ Standby(124)
       ↓                          ↓
  신호 없음 → 양쪽 모두 MASTER 판단
       ↓                          ↓
  VIP 보유 (충돌)            VIP 보유 (충돌)
```

---

### 3.2 Split-Brain 발생 조건

현재 keepalive-guardian은 **유니캐스트 VRRP** 방식으로 동작합니다.
다음 상황에서 Split-Brain이 발생할 수 있습니다.

| 상황 | 설명 |
|------|------|
| 두 서버 간 스위치 포트 장애 | 서버는 살아있지만 VRRP 신호 차단 |
| 두 서버 간 VLAN 설정 오류 | 서버 간 통신만 단절 |
| 방화벽에서 VRRP(112) 차단 | VRRP Advertisement 미전달 |

---

### 3.3 Split-Brain 증상 확인

두 서버에서 동시에 아래 명령어를 실행합니다.

```bash
# 두 서버 모두 MASTER이면 Split-Brain 상태
ip addr show | grep <VIP>

# keepalived 상태 확인
systemctl status keepalived | grep -i master
```

두 서버 모두 VIP를 보유하고 있으면 Split-Brain 상태입니다.

---

### 3.4 Split-Brain 복구 방법

```bash
# 1. 두 서버 간 네트워크 연결 복구 (스위치/케이블 점검)

# 2. 네트워크 복구 후 우선순위가 낮은 서버(Standby)에서 keepalived 재시작
#    → Active 서버가 priority 높으므로 자동으로 MASTER 재선출
sudo systemctl restart keepalived

# 3. VIP 정상화 확인
ip addr show | grep <VIP>   # Active 서버에서만 VIP 보유 확인
```

---

### 3.5 Split-Brain 예방 권장 사항

keepalived만으로는 Split-Brain을 완벽히 방지하기 어렵습니다.
운영 환경에 따라 아래 방법을 추가로 고려하세요.

| 방법 | 설명 | 복잡도 |
|------|------|--------|
| 전용 Heartbeat 링크 | 두 서버 간 별도 네트워크 인터페이스로 VRRP 통신 | 낮음 |
| Fence 장치 (STONITH) | 장애 서버를 강제로 차단하는 하드웨어 장치 | 높음 |
| 외부 중재자 (Quorum) | 제3의 서버가 MASTER 선출에 참여 | 중간 |

> 가장 현실적인 예방책은 **두 서버 간 전용 Heartbeat 링크(별도 NIC)**를 구성하는 것입니다.
> 서비스 트래픽 인터페이스와 VRRP 통신 인터페이스를 분리하면 Split-Brain 가능성을 크게 낮출 수 있습니다.

---

### 3.6 전용 Heartbeat 링크 구성 방법

keepalive-guardian은 `install.sh` 설치 시 Heartbeat 전용 링크를 구성할 수 있습니다.

#### 구성 전 준비사항

1. 두 서버에 NIC가 2개 이상 존재해야 합니다.
2. 두 서버를 직결 케이블로 연결합니다. (Auto-MDI/X 지원 NIC은 다이렉트 케이블 사용 가능)
3. Heartbeat 인터페이스에 IP를 할당합니다.

```bash
# 예: ens19에 임시 IP 할당 (재부팅 시 초기화됨)
ip addr add 10.0.0.1/30 dev ens19
ip link set ens19 up

# 영구 설정 (nmcli)
nmcli con add type ethernet ifname ens19 con-name hb-link ip4 10.0.0.1/30
nmcli con up hb-link
```

4. 상대 서버에도 동일하게 IP를 할당합니다. (예: 10.0.0.2/30)
5. 두 서버 간 통신을 확인합니다.

```bash
ping 10.0.0.2
```

#### install.sh 실행 (인터랙티브 모드)

```
[Dedicated Heartbeat Link (Split-Brain Prevention)]
  Heartbeat 전용 인터페이스를 구성하시겠습니까? [y/N]: y

  사용 가능한 인터페이스 (서비스 인터페이스 ens18 제외):
    ens19    UP    10.0.0.1

  Heartbeat 인터페이스 입력: ens19
  상대 서버 Heartbeat IP 입력: 10.0.0.2
```

#### install.conf 파일 사용 (non-interactive 모드)

```bash
VRRP_INTERFACE=ens18
PEER_IP=192.168.10.124
HEARTBEAT_INTERFACE=ens19
PEER_HB_IP=10.0.0.2
```

#### 구성 결과

```
[Active 서버 ens18]──── 서비스 트래픽 ────[Standby 서버 ens18]
        ↓                                          ↓
      VIP 보유                               BACKUP 대기

[Active 서버 ens19]──── VRRP 신호 (직결) ──[Standby 서버 ens19]
```

서비스 스위치 장애가 발생해도 VRRP 신호는 직결 케이블로 유지되어 Split-Brain을 방지합니다.
