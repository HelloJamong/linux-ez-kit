# File Filter

설정 파일(conf) 기반으로 CSV / TXT / DAT 파일을 조건 필터링하는 스크립트.  
원본을 `_origin`으로 보존하고 원본 파일을 필터링 결과로 교체한다. crontab 자동화 목적.

## 파일 구조

```
file-filter/
├── file_filter.sh        # 메인 스크립트
├── filter.conf           # 실행 설정 파일 (직접 생성)
├── filter.conf.sample    # 설정 파일 샘플
└── README.md
```

## 빠른 시작

```bash
cp filter.conf.sample filter.conf
vi filter.conf          # 파일 경로 및 조건 수정
chmod +x file_filter.sh
./file_filter.sh
```

## 동작 방식

```
최초 실행:  data.dat → data_origin.dat (백업 생성)
                     → data.dat (필터링 결과)

이후 실행:  data_origin.dat (항상 원본 기준)
                     → data.dat (필터링 결과로 교체)
```

`_origin` 파일은 최초 1회만 생성되며, 이후 실행에서 덮어쓰지 않는다.

## filter.conf 설정

### 기본 구조

```ini
[file1]
PATH=/path/to/data.dat
DELIMITER=whitespace
HAS_HEADER=no
FILTER_1=last:eq:009T
```

### 옵션 설명

| 키 | 기본값 | 설명 |
|----|--------|------|
| `PATH` | (필수) | 대상 파일 절대 경로 |
| `DELIMITER` | `whitespace` | 컬럼 구분자 (아래 표 참고) |
| `HAS_HEADER` | `no` | 헤더 행 보존 여부 (`yes` / `no`) |
| `FILTER_N` | (필수) | 필터 조건. `컬럼:연산자:값` 형식 |
| `FILTER_LOGIC` | `AND` | 다중 조건 결합 방식 (`AND` / `OR`) |

### DELIMITER 옵션

| 값 | 적용 대상 |
|----|----------|
| `whitespace` | 공백/탭 구분 (.dat, .txt) |
| `,` | CSV |
| `\|` | 파이프 구분 |
| `\t` 또는 `tab` | 탭 구분 |
| `;` | 세미콜론 구분 |

### FILTER 조건 형식

```
FILTER_N=컬럼:연산자:값
```

**컬럼:**
- `1`, `2`, `3` ... — 왼쪽부터 n번째
- `last` — 마지막 컬럼 (`$NF`)

**연산자:**

| 연산자 | 설명 | 예시 |
|--------|------|------|
| `eq` | 정확히 일치 | `last:eq:009T` |
| `neq` | 불일치 | `3:neq:FAILED` |
| `contains` | 포함 (정규식 가능) | `2:contains:서울` |
| `not_contains` | 미포함 | `2:not_contains:테스트` |
| `gte` | 숫자 이상 | `5:gte:25` |
| `lte` | 숫자 이하 | `5:lte:100` |

## 설정 예시

### .dat — 마지막 컬럼 필터

```ini
[file1]
PATH=/data/sensor.dat
DELIMITER=whitespace
HAS_HEADER=no
FILTER_1=last:eq:009T
```

### CSV — 헤더 보존 + AND 다중 조건

```ini
[file2]
PATH=/data/report.csv
DELIMITER=,
HAS_HEADER=yes
FILTER_1=3:eq:active
FILTER_2=5:gte:25
FILTER_LOGIC=AND
```

### TXT — OR 조건

```ini
[file3]
PATH=/data/logs.txt
DELIMITER=|
HAS_HEADER=no
FILTER_1=2:contains:seoul
FILTER_2=last:neq:FAILED
FILTER_LOGIC=OR
```

## crontab 등록

```bash
# 매일 새벽 2시 실행
0 2 * * * /path/to/file-filter/file_filter.sh >> /var/log/file_filter_cron.log 2>&1
```

## 로그

스크립트 실행마다 `filter_YYYYMMDD_HHMMSS.log` 파일이 스크립트 디렉토리에 생성된다.

```
[2026-06-23 02:00:01] OK   원본 백업 생성: /data/data_origin.dat
[2026-06-23 02:00:01] OK   data.dat: 4줄 → 3줄 [AND: last:eq:009T]
[2026-06-23 02:00:01] 전체 처리 완료
```
