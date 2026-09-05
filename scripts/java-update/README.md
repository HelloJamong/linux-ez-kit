# Eclipse Temurin JDK tar.gz 업데이트 자동화

Rocky Linux 9 환경에서 tar.gz로 수동 설치한 Eclipse Temurin JDK 21을 안전하게 업데이트하는 스크립트입니다. RPM/DNF로 설치한 Java에는 사용하지 않습니다.

## 전제 환경

```
/usr/lib/jvm/
├── jdk-21.0.10+7/
└── temurin-21 -> jdk-21.0.10+7
```

- `/etc/profile.d/java.sh` 가 `JAVA_HOME=/usr/lib/jvm/temurin-21` 을 선언
- 위 구조와 다르면(예: RPM 설치, 심볼릭 링크 없음, Temurin이 아님) 스크립트는 임의로 수정하지 않고 즉시 오류로 중단합니다.

## 주요 기능

- **사전 환경 점검**: 현재 java 경로, JAVA_HOME, 심볼릭 링크, RPM 소유 여부, Temurin/JDK21 여부를 검증
- **아카이브 안전 검증**: gzip/tar 무결성, path traversal(`../`, 절대경로) 차단, `bin/java`·`bin/javac` 존재 확인
- **버전 게이트**: `release` 파일 기준으로 Temurin/JDK21/아키텍처/버전을 확인, 다운그레이드는 기본 거부 (`--force`로 동일 버전 재설치만 허용)
- **선택적 SHA-256 검증**: `--sha256` 제공 시 불일치하면 즉시 중단, 미제공 시 경고만
- **원자적 설치/전환**: 임시 디렉터리에서 검증 후 `/usr/lib/jvm/jdk-<ver>`로 배치, 심볼릭 링크는 `ln -s` + `mv -T`로 원자적 교체
- **자동 롤백**: 링크 전환 후 검증 실패 시 이전 링크로 즉시 복구
- **삭제 없음**: 기존 JDK 디렉터리는 절대 자동 삭제하지 않음 (경로만 안내)
- **실행 중 프로세스 경고**: `pgrep -a java`로 조회만 하고 kill/재시작은 하지 않음

## 사용법

```bash
./update-java.sh --check                                   # 현재 환경만 점검 (읽기 전용, root 불필요)
./update-java.sh --help                                     # 도움말
sudo ./update-java.sh --dry-run <tar.gz>                     # 검증까지만 수행, 변경 없음
sudo ./update-java.sh <tar.gz>                               # 실제 업데이트
sudo ./update-java.sh --sha256 <SHA256> <tar.gz>              # 체크섬 검증 포함 업데이트
sudo ./update-java.sh --force <tar.gz>                        # 동일 버전 재설치 허용
```

## 실행 예시

### `--check`
```
[INFO] === 현재 Java 환경 점검 ===
[INFO] command -v java: /usr/lib/jvm/temurin-21/bin/java
[INFO] readlink -f: /usr/lib/jvm/jdk-21.0.10+7/bin/java
[INFO] JAVA_HOME (/etc/profile.d/java.sh): /usr/lib/jvm/temurin-21
[OK] RPM 비관리 설치 확인됨 (tar.gz 수동 설치)
[INFO] Current Java version: 21.0.10+7
[OK] 현재 Java 환경 검증 완료
```

### `--dry-run`
```
[INFO] New Java version: 21.0.11+9 (x86_64)
[INFO] 신규 버전(21.0.11+9)이 현재 버전(21.0.10+7)보다 최신입니다.
[INFO] === DRY-RUN 요약 (실제 변경 없음) ===
[INFO] 설치 예정 경로: /usr/lib/jvm/jdk-21.0.11+9
[INFO] 변경 예정 심볼릭 링크: /usr/lib/jvm/temurin-21 -> /usr/lib/jvm/jdk-21.0.11+9
[OK] DRY-RUN 완료. 실제 변경 사항 없음.
```

### 실제 업데이트
```
[OK] New JDK validation successful.
[INFO] Switching symbolic link...
[OK] /usr/lib/jvm/temurin-21 -> /usr/lib/jvm/jdk-21.0.11+9

[OK] Java update completed successfully.

Previous JDK:
  /usr/lib/jvm/jdk-21.0.10+7
Current JDK:
  /usr/lib/jvm/jdk-21.0.11+9

기존 JDK는 자동 삭제되지 않습니다. 충분히 검증 후 필요 시 수동으로 삭제하세요:
  rm -rf "/usr/lib/jvm/jdk-21.0.10+7"
```

### 업데이트 실패 시 자동 롤백
링크 전환 직후 `$SYMLINK/bin/java -version` · `javac -version` 재검증에 실패하면 즉시 이전 링크로 되돌리고 재검증합니다.
```
[ERROR] 심볼릭 링크 전환 후 검증에 실패했습니다.
[WARN] 이전 링크로 롤백합니다: /usr/lib/jvm/jdk-21.0.10+7
[OK] 롤백 성공: /usr/lib/jvm/temurin-21 -> /usr/lib/jvm/jdk-21.0.10+7
```
롤백 자체가 실패하면 `[ERROR] 롤백 실패. 수동 조치가 필요합니다.`를 출력하고 exit code 2로 종료합니다 (수동 개입 필요).

## 주의사항

- `command -v java` 결과는 현재 쉘의 command hash 캐시에 의해 즉시 반영되지 않을 수 있습니다. 업데이트 후 다른 세션에서는 `hash -r` 또는 재접속을 권장합니다.
- 실행 중인 Java 프로세스(예: Minecraft 서버)는 링크를 바꿔도 자동으로 새 버전을 쓰지 않습니다. 스크립트는 kill/재시작 없이 경고만 출력하므로, 필요한 서비스는 직접 재시작하세요.
- `--sha256` 없이 실행하면 무결성 검증 없이 진행됩니다(경고만 출력). 신뢰할 수 있는 출처의 tar.gz만 사용하세요.
- 스크립트는 URL을 다운로드하지 않습니다. tar.gz 파일은 사용자가 직접 준비해야 합니다.

## 지원 환경

- Rocky Linux 9.x (RHEL 계열)
- Eclipse Temurin JDK 21, tar.gz 수동 설치
