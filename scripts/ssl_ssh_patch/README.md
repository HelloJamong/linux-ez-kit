# OpenSSL / OpenSSH 보안 패치 자동화

Rocky Linux / RHEL 9.x 환경에서 OpenSSL과 OpenSSH 보안 취약점(CVE)을 패치하는 자동화 스크립트입니다. 백업, RPM 설치, 버전 검증, CVE 반영 확인까지 전체 프로세스를 자동으로 수행합니다.

## 주요 기능

- **CVE 기반 패치 관리**: `CVE_LIST` 변수에 점검할 CVE 코드를 지정하여 해당 패치가 포함되었는지 사전 및 사후 검증
- **자동 백업**: 패치 적용 전 현재 패키지 정보, 설정 파일, 라이브러리를 타임스탬프 폴더로 백업
- **FIPS Provider 감지**: Rocky 9.5+ (`fips-provider-next`)와 9.0~9.4 (`openssl-fips-provider`) 환경을 자동 감지하여 적절한 패키지만 설치
- **롤백 지원**: 설치 실패 시 백업된 라이브러리 파일 복구 및 수동 롤백 안내
- **결과 보고서**: 패치 전후 버전, CVE 반영 상태, 백업 경로를 포함한 보고서 파일 자동 생성

## 시스템 요구사항

- Rocky Linux 9.x 또는 RHEL 9.x
- Root 권한
- 패치 RPM 파일 (아래 디렉토리 구조 참조)

## 파일 구성

```
ssl_ssh_patch/
├── patch_script.sh          # 패치 메인 스크립트
├── openssh/                 # OpenSSH 패키지 RPM 폴더
│   ├── openssh-<ver>.rpm
│   ├── openssh-server-<ver>.rpm
│   └── openssh-clients-<ver>.rpm
├── openssl/                 # OpenSSL 패키지 RPM 폴더
│   ├── openssl-<ver>.rpm
│   ├── openssl-libs-<ver>.rpm
│   ├── openssl-devel-<ver>.rpm          # 선택사항
│   └── openssl-fips-provider-<ver>.rpm  # 선택사항 (9.0~9.4 환경)
└── README.md                # 이 문서
```

현재 폴더에 포함된 RPM 예시:
```
openssh/
├── openssh-9.9p1-7.el9_8.rocky.0.1.x86_64.rpm
├── openssh-clients-9.9p1-7.el9_8.rocky.0.1.x86_64.rpm
└── openssh-server-9.9p1-7.el9_8.rocky.0.1.x86_64.rpm

openssl/
├── openssl-3.5.5-4.el9_8.x86_64.rpm
├── openssl-fips-provider-3.5.5-4.el9_8.x86_64.rpm
└── openssl-libs-3.5.5-4.el9_8.x86_64.rpm
```

> **참고**: `openssl-devel` 패키지는 el9_8 BaseOS 저장소에 포함되지 않습니다. 필요 시 CRB(CodeReady Builder) 저장소에서 별도 다운로드하세요.

## 사용 방법

### 1. CVE 코드 설정

`patch_script.sh` 상단의 `CVE_LIST` 변수에 점검할 CVE 코드를 공백으로 구분하여 입력합니다:

```bash
CVE_LIST="CVE-2026-34181 CVE-2026-34182 CVE-2026-34183"
```

### 2. RPM 파일 배치

`openssh/`, `openssl/` 폴더에 해당 패치 버전의 RPM 파일을 배치합니다. 스크립트는 폴더 내 파일명 패턴으로 자동 검색하므로 파일명을 변경하지 않아야 합니다.

> **참고**: 스크립트는 실행 경로와 무관하게 `/tmp/ssl_ssh_patch/` 경로를 기본 작업 디렉토리로 사용합니다. 배포 시 해당 경로로 폴더를 복사하거나, 스크립트 내 `SCRIPT_DIR` 변수를 수정하세요.

### 3. 스크립트 실행

```bash
# 실행 권한 부여
chmod +x patch_script.sh

# root 권한으로 실행
sudo ./patch_script.sh
```

### 4. 실행 중 확인 프롬프트

스크립트는 각 단계에서 사용자 확인을 요청합니다:

1. CVE 사전 확인 후, 패치가 포함되지 않은 CVE가 있으면 계속 진행 여부 확인
2. `/usr/local`에 수동 설치된 SSH가 있으면 백업 후 제거 여부 확인
3. OpenSSH 패치 진행 여부 확인
4. OpenSSL 패치 진행 여부 확인

## 패치 프로세스 상세

스크립트는 다음 순서로 실행됩니다:

```
1. OS 버전 감지 (Rocky Linux / RHEL 9.x 확인)
2. Root 권한 및 디렉토리 존재 확인
3. RPM 패키지 파일 존재 확인
4. CVE 사전 검증 (패키지 changelog에서 CVE 코드 확인)
5. /usr/local 수동 설치 SSH 확인 및 제거
   ├── 6a. OpenSSH 백업 → 설치 → 버전 검증
   └── 6b. OpenSSL 백업 → 설치 → ldconfig/hash -r → sshd 재시작 → CVE 검증
7. 최종 검증 (패키지 버전, 서비스 상태)
8. 결과 보고서 파일 생성
```

### FIPS Provider별 설치 동작

| 환경 | FIPS 타입 | 설치되는 패키지 |
|------|-----------|----------------|
| Rocky 9.5 이상 | `fips-provider-next` | openssl, openssl-libs, openssl-devel (fips-provider 제외) |
| Rocky 9.0~9.4 | `openssl-fips-provider` | 모든 openssl 패키지 |
| FIPS 미사용 | none | 모든 openssl 패키지 |

## 백업 구조

백업은 실행 시간의 타임스탬프로 폴더를 생성하여 저장됩니다:

```
/tmp/ssl_ssh_patch/backup/backup_YYYYMMDD_HHMMSS/
├── openssh/
│   ├── package_info.txt     # rpm -qi 패키지 정보
│   ├── changelog.txt        # openssh-server changelog
│   ├── versions.txt         # 패치 전 패키지 버전
│   └── ssh/                 # /etc/ssh 설정 파일 전체
└── openssl/
    ├── package_info.txt     # rpm -qi 패키지 정보
    ├── changelog.txt        # openssl changelog
    ├── versions.txt         # 패치 전 패키지 버전
    ├── fips_info.txt        # FIPS provider 타입 및 설치 상태
    ├── libssl.so*           # 백업된 라이브러리
    └── libcrypto.so*        # 백업된 라이브러리
```

## 출력 파일

| 파일 | 위치 | 내용 |
|------|------|------|
| 로그 파일 | `/tmp/ssl_ssh_patch/logs/patch_YYYYMMDD_HHMMSS.log` | 전체 실행 로그 |
| 결과 보고서 | `/tmp/ssl_ssh_patch/result_patch_YYYYMMDD_HHMMSS.log` | 패치 전후 버전, CVE 상태, 백업 경로 |

## 롤백 및 복구

스크립트는 설치 실패 시 자동으로 롤백을 시도합니다. 세부 내용은 아래와 같습니다:

### OpenSSH 롤백
- 자동 롤백 불가 (온라인 저장소 연동 없음)
- 백업된 `versions.txt`를 참고하여 이전 RPM 파일을 수동으로 설치해야 합니다

### OpenSSL 롤백
- `libssl.so*`, `libcrypto.so*` 라이브러리 파일은 백업에서 자동 복구
- `ldconfig`를 실행하여 라이브러리 캐시를 갱신
- RPM 패키지 정보는 수동 복구가 필요합니다

### 수동 복구 예시

```bash
# OpenSSH 이전 버전 복구
rpm -Uvh /tmp/ssl_ssh_patch/backup/backup_YYYYMMDD_HHMMSS/openssh/*.rpm

# OpenSSL 라이브러리 수동 복구
cp -af /tmp/ssl_ssh_patch/backup/backup_YYYYMMDD_HHMMSS/openssl/libssl.so* /usr/lib64/
cp -af /tmp/ssl_ssh_patch/backup/backup_YYYYMMDD_HHMMSS/openssl/libcrypto.so* /usr/lib64/
ldconfig
```

## 문제 해결

### 스크립트 실행 권한 오류
```bash
chmod +x patch_script.sh
```

### "Root 권한이 필요합니다" 오류
```bash
sudo ./patch_script.sh
```

### 패키지 디렉토리를 찾을 수 없음
스크립트는 기본 경로 `/tmp/ssl_ssh_patch/openssh`, `/tmp/ssl_ssh_patch/openssl`를 참조합니다. RPM 파일이 해당 경로에 있는지 확인합니다:
```bash
ls /tmp/ssl_ssh_patch/openssh/
ls /tmp/ssl_ssh_patch/openssl/
```

### CVE 패치를 패키지에서 찾을 수 없음
`CVE_LIST`에 지정된 CVE가 배치된 RPM의 changelog에 포함되지 않은 경우 발생합니다. 배치된 RPM 파일이 해당 CVE 패치 이후 버전인지 확인하세요:
```bash
rpm -qp --changelog /tmp/ssl_ssh_patch/openssl/openssl-*.rpm | grep "CVE-xxxx-xxxxx"
```

### SSH 서비스 재시작 실패
OpenSSL 패치 후 sshd 재시작이 실패하면 스크립트가 OpenSSL 롤백을 자동 시도합니다. 롤백 후도 문제가 유지되면 콘솔 접속을 통해 수동 점검이 필요합니다.

## 주의사항

1. **Root 권한 필수**: 패키지 설치와 시스템 파일 조작이므로 반드시 root로 실행해야 합니다
2. **SSH 세션 유지**: 패치 중 현재 SSH 세션이 끊어질 수 있으므로, 콘솔 또는 추가 세션을 준비하세요
3. **패치 순서**: OpenSSH를 먼저 패치한 후 OpenSSL을 패치하는 순서를 준수해야 합니다
4. **RPM 파일명 유지**: 스크립트가 파일명 패턴으로 자동 검색하므로, 파일명을 임의로 변경하면 안 됩니다
5. **테스트 환경 우선**: 프로덕션 환경 적용 전 동일 OS 버전의 테스트 환경에서 먼저 검증하세요
6. **FIPS Provider 주의**: Rocky 9.5 이상에서는 `openssl-fips-provider` 패키지를 설치하지 않습니다. 잘못된 설치는 시스템 오류를 일으킬 수 있습니다

## 다른 버전의 RPM 다운로드 가이드

현재 폴더에 포함된 RPM 파일이 아닌 다른 버전을 사용하려면 Rocky Linux 공식 저장소에서 직접 다운로드할 수 있습니다.

**공식 저장소 URL:**
[https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/](https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/)

### 다운로드 절차

1. 위 URL을 방문하여 패키지 이름의 첫 글자 폴더로 이동합니다 (예: `o/` → openssl, openssh)
2. 필요한 버전의 `.rpm` 파일을 다운로드합니다
3. 다운로드된 파일을 아래와 같이 배치합니다:

```
openssh/   ← openssh-*.rpm, openssh-server-*.rpm, openssh-clients-*.rpm
openssl/   ← openssl-*.rpm, openssl-libs-*.rpm, openssl-devel-*.rpm, openssl-fips-provider-*.rpm
```

### 다운로드 예시 (wget)

```bash
# OpenSSL 패키지
wget "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/o/openssl-<ver>.el9.x86_64.rpm" -O openssl/openssl-<ver>.el9.x86_64.rpm
wget "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/o/openssl-libs-<ver>.el9.x86_64.rpm" -O openssl/openssl-libs-<ver>.el9.x86_64.rpm

# OpenSSH 패키지
wget "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/o/openssh-<ver>.el9.x86_64.rpm" -O openssh/openssh-<ver>.el9.x86_64.rpm
wget "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/o/openssh-server-<ver>.el9.x86_64.rpm" -O openssh/openssh-server-<ver>.el9.x86_64.rpm
wget "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/o/openssh-clients-<ver>.el9.x86_64.rpm" -O openssh/openssh-clients-<ver>.el9.x86_64.rpm
```

> **참고**: `<ver>` 부분은 저장소에서 확인한 실제 버전 문자열로 대체하세요. 다운로드 후 파일명이 원본과 동일한 형식인지 확인하고, RPM 서명 검증을 권장합니다.
