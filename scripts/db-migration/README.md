# DB Migration (Migris)

운영 중인 MariaDB의 스키마 및 데이터를 안전하게 마이그레이션하는 스크립트입니다. SQL 쿼리 파일을 순차 실행하며, 실행 전 자동 백업과 중복 방지 로직으로 반복 실행해도 안전합니다.

## 주요 기능

- **실행 전 자동 백업**: 마이그레이션 전 전체 DB를 타임스탬프 파일로 백업
- **중복 실행 방지**: 테이블·컬럼·인덱스·레코드 존재 여부를 사전 확인하여 이미 적용된 쿼리는 자동 스킵
- **멀티라인 SQL 지원**: 여러 줄로 작성된 `CREATE TABLE` 등 복잡한 쿼리 정상 처리
- **비밀번호 보안**: DB 비밀번호는 스크립트에 저장하지 않고 실행 시 프롬프트로 입력받음
- **실행 결과 로그**: 성공·스킵·실패 쿼리를 타임스탬프 로그 파일로 자동 기록
- **오류 격리**: 일부 쿼리 실패 시에도 나머지 쿼리는 계속 실행하여 결과를 최종 요약으로 표시

## 시스템 요구사항

### 운영 환경
- **OS**: Rocky Linux 8, 9 (RHEL 계열)
- **Database**: MariaDB 10.11.7 이상

### 필수 패키지
- bash 4.0 이상
- MariaDB Client (`mysql`, `mysqldump`)

## 파일 구성

```
db-migration/
├── migris.sh              # 마이그레이션 메인 스크립트
├── all_query.txt.sample   # 마이그레이션 쿼리 샘플 파일
├── all_query.txt          # 마이그레이션 쿼리 파일 (git 추적 제외)
└── README.md              # 이 문서
```

> `all_query.txt`와 `migration_result_*.log`는 `.gitignore`에 의해 git 추적에서 제외됩니다.

## 설정 방법

### 1. 쿼리 파일 생성

```bash
cp all_query.txt.sample all_query.txt
```

`all_query.txt`에 실제 마이그레이션 쿼리를 작성합니다.

### 2. DB 연결 정보 설정

`migris.sh` 상단 변수에 연결 정보를 입력합니다. `DB_PASSWORD`는 반드시 공란으로 유지해야 합니다.

```bash
DB_HOST="localhost"
DB_PORT="3306"
DB_USER="root"
DB_PASSWORD=""        # 공란 유지 — 실행 시 프롬프트로 입력받음
DB_NAME="database_name"
```

### 3. 실행 권한 부여

```bash
chmod +x migris.sh
```

## 사용 방법

### 기본 실행

```bash
./migris.sh
```

실행 시 비밀번호 프롬프트가 표시되며, 입력 문자는 화면에 표시되지 않습니다.

### 실행 순서

1. **연결 정보 검증** — `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_NAME` 공란 여부 확인
2. **비밀번호 입력** — 프롬프트로 안전하게 입력
3. **디렉토리 확인** — 백업 디렉토리(`/backup/db-backup`) 및 쿼리 파일 존재 확인
4. **DB 연결 테스트** — 설정 정보로 연결 확인
5. **자동 백업** — 전체 DB를 `/backup/db-backup/before_migration_YYYYMMDD_HHMMSS.sql`로 백업
6. **쿼리 실행** — `all_query.txt` 쿼리를 순차 실행 (중복 항목 자동 스킵)
7. **결과 요약** — 성공·스킵·실패 수 출력 및 로그 파일 생성

### 출력 예시

```
========================================
  Migris - Database Migration Tool
========================================

데이터베이스 비밀번호: ██████
[INFO] 마이그레이션 시작: 2026-01-29 15:00:00
[INFO] 데이터베이스: database_name@localhost:3306
[SUCCESS] 데이터베이스 연결 성공
[SUCCESS] 데이터베이스 백업 완료 (크기: 125M)
[INFO] 총 예상 쿼리 수: 10

[INFO] [1/10] 쿼리 실행: CREATE TABLE `users` ...
[SUCCESS] 쿼리 실행 성공 [CREATE_TABLE]

[INFO] [2/10] 쿼리 실행: ALTER TABLE users ADD COLUMN status ...
[SKIP] 컬럼이 이미 존재함: users.status

========================================
마이그레이션 결과 요약
========================================
총 쿼리 수: 10
성공: 8
스킵: 2 (이미 존재)
실패: 0
========================================
백업 파일: /backup/db-backup/before_migration_20260129_150000.sql
로그 파일: /home/user/scripts/db-migration/migration_result_20260129_150000.log
========================================

모든 마이그레이션이 성공적으로 완료되었습니다!
```

## 마이그레이션 쿼리 작성

`all_query.txt`에 SQL 쿼리를 작성합니다. 모든 쿼리는 세미콜론(`;`)으로 끝나야 하며, `--`로 시작하는 줄은 주석으로 처리됩니다.

```sql
-- 테이블 생성
CREATE TABLE `users` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `username` VARCHAR(100) NOT NULL,
    `created_date` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 컬럼 추가
ALTER TABLE users ADD COLUMN status VARCHAR(20) DEFAULT 'ACTIVE' NOT NULL;

-- 인덱스 생성
CREATE INDEX idx_email ON users (email);

-- 데이터 삽입
INSERT INTO config_table (key_name, key_value) VALUES ('app_version', '1.0.0');
```

### 지원 쿼리 타입 및 중복 방지 동작

| 쿼리 타입 | 중복 확인 방법 | 중복 시 동작 |
|----------|-------------|------------|
| `CREATE TABLE` | 테이블 존재 여부 | 스킵 |
| `CREATE INDEX` | 인덱스 존재 여부 | 스킵 |
| `CREATE VIEW` | VIEW 존재 여부 (OR REPLACE는 실행) | 스킵 |
| `ALTER TABLE ADD COLUMN` | 컬럼 존재 여부 | 스킵 |
| `ALTER TABLE DROP COLUMN` | 컬럼 존재 여부 | 스킵 |
| `ALTER TABLE DROP KEY` | 인덱스 존재 여부 | 스킵 |
| `INSERT` (ref_code 테이블) | 복합키 중복 확인 | 스킵 |
| `UPDATE`, `DROP`, 기타 | 중복 확인 없음 | 항상 실행 |

## 백업 시스템

### 백업 위치

```
/backup/db-backup/
├── before_migration_20260129_150000.sql
├── before_migration_20260129_160000.sql
└── before_migration_20260129_170000.sql
```

### 백업 디렉토리 사전 생성 (sudo 권한 없을 경우)

스크립트는 `/backup/db-backup`을 자동 생성하지만, 권한이 없을 경우 미리 생성해두세요.

```bash
sudo mkdir -p /backup/db-backup
sudo chmod 755 /backup/db-backup
```

### 백업으로 수동 복구

```bash
# 백업 파일 목록 확인
ls -lh /backup/db-backup/

# 특정 시점으로 복구
mysql -h localhost -P 3306 -u root -p database_name < /backup/db-backup/before_migration_YYYYMMDD_HHMMSS.sql
```

## 로그 및 모니터링

실행 로그는 스크립트와 동일한 경로에 자동 생성됩니다.

```bash
# 전체 로그 확인
cat migration_result_YYYYMMDD_HHMMSS.log

# 실패 쿼리만 확인
grep "\[ERROR\]" migration_result_YYYYMMDD_HHMMSS.log

# 스킵된 항목 확인
grep "\[SKIP\]" migration_result_YYYYMMDD_HHMMSS.log
```

## 문제 해결

### 변수 미설정 오류

`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_NAME` 중 공란이 있으면 해당 변수명과 함께 오류 출력 후 종료됩니다. `migris.sh` 상단 변수를 확인하세요.

### 백업 디렉토리 생성 실패

```bash
sudo mkdir -p /backup/db-backup
sudo chown $USER:$USER /backup/db-backup
```

### 쿼리 파일을 찾을 수 없음

`migris.sh`와 동일한 경로에 `all_query.txt` 파일이 있어야 합니다.

```bash
cp all_query.txt.sample all_query.txt
```

### 데이터베이스 연결 실패

```bash
# 연결 테스트
mysql -h localhost -P 3306 -u root -p -e "SHOW DATABASES;"
```

### 마이그레이션 실패 후 복구

```bash
# 마이그레이션 전 백업으로 복구
mysql -h localhost -P 3306 -u root -p database_name < /backup/db-backup/before_migration_YYYYMMDD_HHMMSS.sql
```

## 주의사항

1. **프로덕션 적용 전 검증**: 반드시 테스트 환경에서 먼저 실행하세요
2. **디스크 공간 확보**: 백업 파일 크기 고려 (DB 크기의 2배 이상 권장)
3. **연결 정보 보안**: `migris.sh`의 `DB_HOST` 등 변수에 실제 서비스 정보가 포함될 수 있으므로 주의
4. **쿼리 파일 보안**: `all_query.txt`는 git에 커밋하지 않도록 주의 (`.gitignore` 처리됨)
5. **대용량 DB**: 백업 및 실행 시간이 길어질 수 있으므로 작업 시간을 충분히 확보하세요
