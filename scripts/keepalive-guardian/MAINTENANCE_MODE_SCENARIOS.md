# Keepalive Guardian - 점검 모드 작업 시나리오

이 문서는 Keepalive Guardian 환경에서 서비스 소스 패치, 설정 변경, 애플리케이션 재기동 등
계획 작업을 수행할 때 사용하는 **점검 모드 운영 절차**를 설명합니다.

특정 서비스명, 프로세스명, 포트, 애플리케이션 종류는 환경마다 다르므로 이 문서에서는 모두
일반화된 표현을 사용합니다.

---

## 1. 목적

Keepalived 기반 Active-Standby HA 구성에서는 서비스 포트 또는 프로세스가 내려가면
헬스체크가 실패하고 priority가 낮아집니다.

계획 작업 중 양쪽 서버의 서비스가 동시에 비정상 상태가 되면 다음 문제가 발생할 수 있습니다.

- VIP가 정상 서비스 가능 서버로 이동하지 못함
- VIP는 존재하지만 실제 서비스가 응답하지 않음
- 양쪽 서버 모두 헬스체크 실패 상태가 됨
- Failover/Failback 로그가 불필요하게 반복됨
- 작업 중 실제 서비스 단절이 발생할 수 있음

점검 모드는 이런 상황을 줄이기 위해 계획 작업 시 헬스체크 결과를 명시적으로 제어하는 기능입니다.

---

## 2. 점검 모드 개념

점검 모드는 다음 스크립트로 제어합니다.

```bash
sudo /usr/local/bin/service_maintenance_mode.sh <command> [options]
```

점검 모드 상태는 기본적으로 아래 파일로 관리됩니다.

```text
/run/keepalive-guardian/maintenance.conf
```

`/run` 경로를 사용하므로 서버가 재부팅되면 점검 모드는 자동 해제됩니다.

---

## 3. 점검 모드 종류

| 모드 | 헬스체크 결과 | 사용 목적 | 주의사항 |
|------|--------------|----------|----------|
| `bypass` | 강제 정상 처리 (`exit 0`) | VIP가 없는 서버의 계획 작업, 불필요한 실패 로그 방지 | VIP 보유 서버에서 서비스를 중지한 상태로 사용하면 장애를 숨길 수 있음 |
| `demote` | 강제 실패 처리 (`exit 1`) | VIP 보유 서버에서 VIP를 상대 서버로 넘긴 뒤 작업 | 상대 서버가 반드시 정상 상태여야 함 |

---

## 4. 주요 명령어

### 4.1 상태 확인

```bash
sudo /usr/local/bin/service_maintenance_mode.sh status
```

### 4.2 점검 모드 활성화 - bypass

```bash
sudo /usr/local/bin/service_maintenance_mode.sh on --mode bypass --reason "planned maintenance"
```

### 4.3 점검 모드 활성화 - demote

```bash
sudo /usr/local/bin/service_maintenance_mode.sh on --mode demote --reason "move VIP before maintenance"
```

### 4.4 점검 모드 비활성화 및 즉시 헬스체크

```bash
sudo /usr/local/bin/service_maintenance_mode.sh off
```

### 4.5 점검 모드만 비활성화하고 헬스체크 생략

```bash
sudo /usr/local/bin/service_maintenance_mode.sh off --no-check
```

### 4.6 수동 헬스체크

```bash
sudo /usr/local/bin/service_maintenance_mode.sh check
```

---

## 5. 작업 전 공통 확인

계획 작업을 시작하기 전에 양쪽 서버에서 다음 항목을 확인합니다.

### 5.1 VIP 보유 서버 확인

```bash
ip addr show | grep <VIP>
```

정상 조건:

- VIP는 한쪽 서버에만 존재해야 합니다.
- 양쪽 서버 모두 VIP를 보유하면 Split-Brain 가능성이 있습니다.
- 양쪽 서버 모두 VIP를 보유하지 않으면 VIP 미할당 상태입니다.

### 5.2 헬스체크 확인

```bash
sudo /usr/local/bin/service_health_check.sh
echo $?
```

정상 조건:

```text
0
```

### 5.3 서비스 상태 확인

환경에 맞는 명령으로 서비스 프로세스와 포트 상태를 확인합니다.

예시:

```bash
systemctl status <service-name>
ss -lntp | grep <service-port>
```

### 5.4 데이터 동기화 상태 확인

서비스가 데이터 저장소를 사용하고 양쪽 서버 간 복제 구성이 있는 경우,
작업 전 복제 상태와 지연 여부를 반드시 확인합니다.

확인 기준 예시:

- 복제 프로세스 정상
- 복제 지연이 허용 범위 이내
- 전환 대상 서버에서 서비스가 사용할 데이터가 최신 상태
- 양쪽 서버에서 동시에 쓰기 작업이 발생하지 않도록 운영 경로 확인

---

## 6. 권장 작업 시나리오

아래 예시는 다음 상태를 가정합니다.

```text
Server A: 현재 MASTER, VIP 보유
Server B: 현재 BACKUP, VIP 미보유
```

---

### 6.1 1단계 - 양쪽 서버 정상 상태 확인

Server A와 Server B에서 각각 확인합니다.

```bash
ip addr show | grep <VIP>
sudo /usr/local/bin/service_health_check.sh
echo $?
sudo /usr/local/bin/service_maintenance_mode.sh status
```

작업 시작 조건:

```text
Server A: VIP 보유, health check 0
Server B: VIP 미보유, health check 0
양쪽 서버: maintenance mode inactive
```

---

### 6.2 2단계 - BACKUP 서버 작업

먼저 VIP를 보유하지 않은 BACKUP 서버에서 작업합니다.

Server B에서 점검 모드를 `bypass`로 활성화합니다.

```bash
sudo /usr/local/bin/service_maintenance_mode.sh on --mode bypass --reason "patch backup server"
```

서비스를 중지합니다.

```bash
sudo systemctl stop <service-name>
```

필요한 작업을 수행합니다.

```bash
# source patch
# config update
# package replace
# other planned work
```

서비스를 다시 기동합니다.

```bash
sudo systemctl start <service-name>
```

서비스 상태를 확인합니다.

```bash
systemctl status <service-name>
ss -lntp | grep <service-port>
```

점검 모드를 해제하고 헬스체크를 수행합니다.

```bash
sudo /usr/local/bin/service_maintenance_mode.sh off
```

정상 조건:

```text
[OK] Service health check passed
```

또는 직접 확인합니다.

```bash
sudo /usr/local/bin/service_health_check.sh
echo $?
```

정상 조건:

```text
0
```

> BACKUP 서버의 헬스체크가 정상으로 돌아오기 전에는 MASTER 서버 작업을 시작하지 않습니다.

---

### 6.3 3단계 - MASTER 서버에서 VIP 이동

BACKUP 서버가 정상 상태임을 확인한 뒤, 현재 MASTER 서버에서 VIP를 이동시킵니다.

Server A에서 `demote` 점검 모드를 활성화합니다.

```bash
sudo /usr/local/bin/service_maintenance_mode.sh on --mode demote --reason "move VIP to peer before maintenance"
```

이 모드는 Server A의 헬스체크를 강제로 실패 처리하여 priority를 낮춥니다.
Server B가 정상 상태라면 VIP는 Server B로 이동합니다.

Server B에서 VIP 이동을 확인합니다.

```bash
ip addr show | grep <VIP>
```

정상 조건:

```text
Server A: VIP 없음
Server B: VIP 보유
```

VIP 기반 서비스 접근도 확인합니다.

```bash
curl -k https://<VIP>:<service-port>
```

서비스가 HTTP 계열이 아닌 경우 해당 서비스에 맞는 접속 확인 방법을 사용합니다.

---

### 6.4 4단계 - 기존 MASTER 서버 작업

VIP가 Server B로 이동한 것을 확인한 뒤 Server A에서 작업합니다.

Server A에서 서비스를 중지합니다.

```bash
sudo systemctl stop <service-name>
```

필요한 작업을 수행합니다.

```bash
# source patch
# config update
# package replace
# other planned work
```

서비스를 다시 기동합니다.

```bash
sudo systemctl start <service-name>
```

서비스 상태를 확인합니다.

```bash
systemctl status <service-name>
ss -lntp | grep <service-port>
```

점검 모드를 해제하고 헬스체크를 수행합니다.

```bash
sudo /usr/local/bin/service_maintenance_mode.sh off
```

정상 조건:

```text
[OK] Service health check passed
```

---

### 6.5 5단계 - 작업 후 상태 확인

양쪽 서버에서 확인합니다.

```bash
ip addr show | grep <VIP>
sudo /usr/local/bin/service_health_check.sh
echo $?
sudo /usr/local/bin/service_maintenance_mode.sh status
tail -50 /var/log/service_ha_check.log
```

정상 조건:

```text
VIP는 한쪽 서버에만 존재
양쪽 health check 결과 0
양쪽 maintenance mode inactive
서비스 접근 정상
데이터 복제 상태 정상
```

---

## 7. Failback 동작 주의

기존 MASTER 서버의 작업이 끝나고 점검 모드를 해제하면,
서비스 헬스체크가 정상화된 뒤 priority가 회복됩니다.

`FAILBACK_DELAY`가 설정되어 있으면 안정화 시간이 지난 후 VIP가 기존 MASTER 서버로 돌아올 수 있습니다.

예:

```bash
FAILBACK_DELAY=300
```

이 경우 서비스 복구 후 약 300초 동안 정상 상태가 유지되어야 priority가 원복됩니다.

VIP를 기존 MASTER로 즉시 되돌리고 싶지 않다면 다음 중 하나를 선택합니다.

1. 기존 MASTER 서버의 `demote` 점검 모드를 원하는 시점까지 유지
2. 작업 완료 후 적절한 전환 시점에 점검 모드 해제
3. 운영 정책에 맞게 keepalived preempt/priority 정책 조정

---

## 8. 금지 또는 주의해야 할 작업

### 8.1 양쪽 서버 서비스를 동시에 중지하지 않기

```text
BACKUP 서비스 중지
MASTER 서비스 중지
```

위 상태가 겹치면 HA 전환 대상이 없어져 서비스 장애가 발생할 수 있습니다.

### 8.2 MASTER에서 bypass 모드로 서비스 중지하지 않기

MASTER에서 `bypass` 모드를 켠 상태로 서비스를 중지하면 keepalived는 정상으로 판단합니다.

결과:

```text
VIP는 MASTER에 남아 있음
서비스는 중지됨
사용자는 장애를 경험할 수 있음
```

MASTER 작업 전에는 `bypass`가 아니라 `demote`를 사용합니다.

### 8.3 BACKUP 정상 확인 전 MASTER 작업 금지

BACKUP 서버가 정상 상태가 아닌데 MASTER를 demote하거나 서비스를 중지하면
VIP가 정상 서비스 가능 서버로 이동하지 못할 수 있습니다.

MASTER 작업 전 필수 조건:

```text
BACKUP health check 0
BACKUP 서비스 정상
BACKUP 데이터 상태 정상
```

---

## 9. 빠른 작업 체크리스트

```text
[ ] 양쪽 서버 health check 0 확인
[ ] VIP가 한쪽 서버에만 있는지 확인
[ ] BACKUP 서버 점검 모드 bypass ON
[ ] BACKUP 서버 작업
[ ] BACKUP 서버 서비스 기동
[ ] BACKUP 서버 점검 모드 OFF
[ ] BACKUP 서버 health check 0 확인
[ ] MASTER 서버 점검 모드 demote ON
[ ] VIP가 BACKUP 서버로 이동했는지 확인
[ ] VIP 경유 서비스 접근 확인
[ ] 기존 MASTER 서버 작업
[ ] 기존 MASTER 서버 서비스 기동
[ ] 기존 MASTER 서버 점검 모드 OFF
[ ] 기존 MASTER 서버 health check 0 확인
[ ] 양쪽 서버 점검 모드 inactive 확인
[ ] VIP가 한쪽 서버에만 있는지 확인
[ ] 서비스 접근 정상 확인
[ ] 데이터 복제 상태 정상 확인
```

---

## 10. 장애 발생 시 복구 기준

작업 중 이상이 발생하면 먼저 아래 상태를 확인합니다.

```bash
ip addr show | grep <VIP>
sudo /usr/local/bin/service_maintenance_mode.sh status
sudo /usr/local/bin/service_health_check.sh
echo $?
tail -100 /var/log/service_ha_check.log
journalctl -u keepalived -n 50 --no-pager
```

우선 복구 목표:

```text
1. 한쪽 서버에서 서비스 정상화
2. 해당 서버 health check 0 확인
3. VIP가 해당 서버에만 존재하도록 정리
4. 반대편 서버의 점검 모드/서비스 상태 정리
5. 양쪽 서버 모두 최종 health check 0 확인
```

