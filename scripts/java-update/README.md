# Amazon Corretto 21 마이그레이션 / 업데이트 자동화

Rocky Linux 9 환경에서 tar.gz로 수동 설치한 JDK(OpenJDK, Eclipse Temurin 등)를 **Amazon Corretto 21**로 마이그레이션하고, 이후 Corretto 21 마이너 업데이트까지 같은 스크립트로 처리합니다. RPM/DNF로 설치한 Java에는 사용하지 않습니다.

## 동작 모드 (자동 판별)

| 모드 | 판별 조건 | 동작 |
|------|-----------|------|
| `migrate` | `/etc/profile.d/java.sh` 의 `JAVA_HOME` 이 `/usr/lib/jvm/java-21` 이 **아님** | Corretto 설치 → `/usr/lib/jvm/java-21` 링크 생성 → `java.sh` 백업 후 재작성 |
| `update` | `JAVA_HOME=/usr/lib/jvm/java-21` 이고 대상이 Corretto 21 | 신규 Corretto 설치 → `java-21` 링크만 원자적 교체 |

마이그레이션 후 구조:

```
/usr/lib/jvm/
├── jdk-21.0.10+7/                                  # 기존 JDK (삭제하지 않음)
├── temurin-21 -> jdk-21.0.10+7                     # 기존 링크 (건드리지 않음)
├── amazon-corretto-21.0.10.7.1-linux-x64/
└── java-21 -> amazon-corretto-21.0.10.7.1-linux-x64

/etc/profile.d/java.sh
  export JAVA_HOME=/usr/lib/jvm/java-21
  export PATH=$JAVA_HOME/bin:$PATH
```

### 현재 JDK 탐색 순서 (migrate)
1. `/etc/profile.d/java.sh` 의 `JAVA_HOME`
2. 환경변수 `JAVA_HOME` (예: `sudo JAVA_HOME=/opt/jdk-17 ./update-java.sh ...`)
3. `PATH` 의 `java` 실제 경로

## 주요 기능

- **사전 환경 점검**: 현재 java 경로, JAVA_HOME, RPM 소유 여부, `release` 파일의 벤더/버전 확인
- **아카이브 안전 검증**: gzip/tar 무결성, path traversal(`../`, 절대경로) 차단, `bin/java`·`bin/javac` 존재 확인
- **버전 게이트**: 신규 아카이브가 Corretto 21인지 확인
  - `migrate`: 벤더 공통 필드 `JAVA_VERSION`의 앞 세 자리 기준 비교. 기존보다 낮으면 거부 (예: Temurin 21.0.10 → Corretto 21.0.9 거부, JDK 25 → 21 거부), 메이저 업그레이드(8/11/17 → 21)는 경고. 재빌드판(예: Temurin `21.0.12.1`)은 같은 업데이트(`21.0.12`)로 간주해 Corretto 21.0.12로 전환 가능
  - `update`: Corretto 버전 비교, 다운그레이드 거부 (`--force`로 동일 버전 재설치만 허용)
- **링크 충돌 방지**: `/usr/lib/jvm/java-21` 이 이미 있으면(예: `java-21-openjdk` RPM의 alternatives 링크) 덮어쓰지 않고 중단
- **선택적 SHA-256 검증**: `--sha256` 제공 시 불일치하면 즉시 중단, 미제공 시 경고만
- **백업/복구 (migrate)**: `/backup/java-update/backup_YYYYMMDD_HHMMSS/` 에 기존 `java.sh` 와 `restore.sh` 생성
- **자동 롤백**: 전환 후 검증 실패 시 이전 상태로 즉시 복구 (`migrate`는 `restore.sh` 실행, `update`는 이전 링크로 복원)
- **alternatives 자동 전환 (migrate)**: `/usr/bin/java`·`/usr/bin/javac` (alternatives)가 기존 JDK 실제 경로를 가리키면 `/usr/lib/jvm/java-21/bin/*` 로 등록·전환하고, `restore.sh` 에 원복 명령을 기록. RPM Java 8 등 다른 JDK를 가리키거나 alternatives가 없으면 건드리지 않음. `java-21` 링크로 등록하므로 이후 update 모드에서는 alternatives 변경이 필요 없음
- **기존 경로 참조 경고 (migrate)**: systemd unit, `/etc/sysconfig`, `/etc/profile*`, 사용자 `.bashrc` 등에서 기존 JDK 경로를 직접 참조하는 줄을 `파일:줄번호:내용` 으로 경고 (수정하지 않음, 주석 처리된 줄은 제외)
- **삭제 없음**: 기존 JDK 디렉터리와 링크는 절대 자동 삭제하지 않음 (경로만 안내)
- **실행 중 프로세스 경고**: `pgrep -ax java`로 조회만 하고 kill/재시작은 하지 않음

## 사용법

```bash
./update-java.sh --check                                    # 현재 환경 점검 + 모드 판별 (읽기 전용, root 불필요)
./update-java.sh --help                                      # 도움말
sudo ./update-java.sh --dry-run <corretto.tar.gz>             # 검증까지만 수행, 변경 없음
sudo ./update-java.sh --sha256 <SHA256> <corretto.tar.gz>     # 실제 실행 (migrate 시 y/N 확인 프롬프트)
sudo JAVA_HOME=/opt/jdk-17 ./update-java.sh <corretto.tar.gz> # java.sh 없는 환경에서 현재 JDK 지정
sudo ./update-java.sh --force <corretto.tar.gz>               # (update) 동일 버전 재설치 허용
```

tar.gz와 SHA-256 값은 [Corretto 21 다운로드 페이지](https://docs.aws.amazon.com/corretto/latest/corretto-21-ug/downloads-list.html)에서 받습니다 (예: `amazon-corretto-21.0.10.7.1-linux-x64.tar.gz`).

## 마이그레이션 절차 (권장)

1. 테스트 서버에서 애플리케이션 호환성 확인 (특히 8/11/17 → 21 메이저 업그레이드)
2. `./update-java.sh --check` 로 현재 JDK, 기존 경로 참조 줄, alternatives 전환 대상 확인
3. 경고된 설정 줄 정리 (아래 [기존 경로 참조 정리](#기존-경로-참조-정리) 참고)
4. `sudo ./update-java.sh --dry-run <tar.gz>` 로 검증 (경로 참조 경고가 사라졌는지 확인)
5. `sudo ./update-java.sh --sha256 <hash> <tar.gz>` 실행 → `y` 입력 (alternatives는 자동 전환)
6. 서비스 재시작 후 확인: `for p in $(pgrep -x java); do echo "$p $(readlink -f /proc/$p/exe)"; done`
7. 재접속 후 `java -version`, `echo $JAVA_HOME`, `readlink -f /usr/bin/java` 확인

> 원복: `sudo /backup/java-update/backup_<타임스탬프>/restore.sh` 실행 후 서비스 재시작. `java.sh`, `java-21` 링크, alternatives를 모두 되돌립니다. 3번에서 직접 수정한 파일은 직접 되돌려야 합니다.

### 기존 경로 참조 정리

스크립트는 `/etc/profile` 같은 시스템 공통 파일을 수정하지 않고, 기존 JDK 경로를 참조하는 줄을 `파일:줄번호:내용` 으로 알려줍니다.

```
[WARN]   /etc/profile:82:export JAVA_HOME=/usr/lib/jvm/jdk-21.0.4
[WARN]   /etc/profile:83:export PATH=/usr/lib/jvm/jdk-21.0.4/bin:$PATH
```

줄 번호는 서버마다 다르므로, 경고에 나온 번호를 그대로 쓰거나 아래처럼 패턴으로 일괄 주석 처리합니다.

```bash
OLD=/usr/lib/jvm/jdk-21.0.4                        # 경고 메시지의 기존 JDK 경로
cp -a /etc/profile /root/profile.bak_$(date +%Y%m%d_%H%M%S)
# 해당 경로가 있는 활성 줄만 주석 처리 (이미 주석인 줄, jdk-21.0.40 같은 다른 버전은 제외)
sed -i -E "\#^[[:space:]]*[^#[:space:]].*${OLD}(/|[[:space:]\"':]|\$)#s|^|#|" /etc/profile
grep -n "${OLD}\|JAVA_HOME" /etc/profile           # 결과 확인
```

- `JAVA_HOME` 줄과 함께 `export PATH=$JAVA_HOME/bin:$PATH` 처럼 **경로 없이 변수만 쓰는 줄**은 경고에 나오지 않습니다. 남겨도 동작에는 문제없지만(`java.sh` 의 `JAVA_HOME` 을 사용), 정리하려면 직접 확인하세요.
- `/etc/profile` 의 설정은 `/etc/profile.d/*.sh` 를 읽은 **뒤**에 실행되면 `java.sh` 를 덮어씁니다. 위치와 관계없이 기존 JDK 줄은 주석 처리하는 것을 권장합니다.
- systemd unit 파일이 경고되면 경로를 `/usr/lib/jvm/java-21` 로 바꾸고 `systemctl daemon-reload` 후 재시작합니다.
- 스크립트를 다시 실행(`--check` 또는 `--dry-run`)하면 주석 처리된 줄은 경고에서 빠지므로 정리 여부를 확인할 수 있습니다.

## 실행 예시

### migrate (`--dry-run`)
```
[INFO] 동작 모드: migrate
[INFO] Current Java: Eclipse Adoptium 21.0.10 (major 21)
[INFO] New Java version: Corretto 21.0.10.7.1 (x86_64)
[INFO] 동일 메이저 버전의 벤더 전환입니다 (Eclipse Adoptium 21.0.10 -> Corretto 21.0.10.7.1).
[WARN] 아래 설정이 기존 JDK 경로(/usr/lib/jvm/temurin-21)를 직접 참조합니다. 마이그레이션 후에도 기존 JDK를 사용하므로 직접 주석 처리 또는 수정하세요:
[WARN]   /etc/systemd/system/app.service:7:Environment=JAVA_HOME=/usr/lib/jvm/temurin-21
[INFO] alternatives java: /usr/lib/jvm/jdk-21.0.10+7/bin/java -> /usr/lib/jvm/java-21/bin/java (전환 시 자동 변경)
[INFO] === DRY-RUN 요약 (실제 변경 없음) ===
[INFO] 설치 예정 경로: /usr/lib/jvm/amazon-corretto-21.0.10.7.1-linux-x64
[INFO] 변경 예정 심볼릭 링크: /usr/lib/jvm/java-21 -> /usr/lib/jvm/amazon-corretto-21.0.10.7.1-linux-x64
[INFO] 재작성 예정: /etc/profile.d/java.sh (JAVA_HOME=/usr/lib/jvm/java-21, 기존 파일은 /backup/java-update/backup_<타임스탬프>/ 에 백업)
[INFO] alternatives 전환 예정: java -> /usr/lib/jvm/java-21/bin/
[OK] DRY-RUN 완료. 실제 변경 사항 없음.
```

### migrate 실패 시 자동 롤백
```
[OK] 백업 완료: /backup/java-update/backup_20261026_122811 (복구: /backup/java-update/backup_20261026_122811/restore.sh)
[ERROR] Corretto 전환 또는 전환 후 검증에 실패했습니다.
[WARN] 마이그레이션을 롤백합니다: /backup/java-update/backup_20261026_122811/restore.sh
[OK] 롤백 성공: /etc/profile.d/java.sh, alternatives(java javac) 복원, /usr/lib/jvm/java-21 제거 (신규 JDK ... 는 남아 있음)
```
롤백 자체가 실패하면 `[ERROR] 롤백 실패. 수동 조치가 필요합니다.`를 출력하고 exit code 2로 종료합니다. 마이그레이션 성공 후 원복이 필요하면 `sudo /backup/java-update/backup_<타임스탬프>/restore.sh` 를 실행하세요.

### update (이미 Corretto 21로 마이그레이션된 서버)
```
[INFO] 동작 모드: update
[INFO] 신규 버전(21.0.11.9.1)이 현재 버전(21.0.10.7.1)보다 최신입니다.
[OK] /usr/lib/jvm/java-21 -> /usr/lib/jvm/amazon-corretto-21.0.11.9.1-linux-x64
[OK] Java update completed successfully.
```

## 주의사항

- **systemd 서비스는 `/etc/profile.d` 를 읽지 않습니다.** 경로 없이 `java` 로 실행하면 `/usr/bin/java` (alternatives)를 사용하며, 이는 스크립트가 자동 전환합니다. unit 파일에 기존 JDK 경로가 하드코딩되어 있으면 마이그레이션 후에도 기존 JDK로 실행되니 경고된 줄을 직접 수정하세요.
- `/etc/profile.d/java.sh` 는 JAVA_HOME/PATH 두 줄로 **재작성**됩니다. 기존 파일에 다른 설정(CLASSPATH 등)이 있었다면 백업본에서 옮겨 넣으세요.
- `java-21-openjdk` 등 RPM Java가 함께 설치되어 `/usr/bin/java` (alternatives)가 존재해도 로그인 쉘에서는 `$JAVA_HOME/bin` 이 PATH 앞에 오므로 Corretto가 우선합니다. 절대경로 `/usr/bin/java` 를 쓰는 스크립트는 영향을 받지 않습니다.
- `command -v java` 결과는 현재 쉘의 command hash 캐시에 의해 즉시 반영되지 않을 수 있습니다. 변경 후 `hash -r` 또는 재접속을 권장합니다.
- 실행 중인 Java 프로세스는 링크를 바꿔도 자동으로 새 버전을 쓰지 않습니다. 스크립트는 kill/재시작 없이 경고만 출력하므로, 필요한 서비스는 직접 재시작하세요.
- 스크립트는 URL을 다운로드하지 않습니다. tar.gz 파일은 사용자가 직접 준비해야 합니다.

## 지원 환경

- Rocky Linux 9.x (RHEL 계열)
- 기존: tar.gz로 수동 설치한 JDK (OpenJDK, Temurin 등, `release` 파일 필요) — JDK 21 이하
- 신규: Amazon Corretto 21 tar.gz (`linux-x64` / `linux-aarch64`)
