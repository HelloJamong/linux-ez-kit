# 커널 보안 패치 자동화 (kernel_patch)

Rocky Linux / RHEL 9.x 환경에서 커널 보안 취약점(CVE)을 오프라인 RPM으로 패치하는 자동화 스크립트입니다.  
기존 커널은 유지하고 새 커널을 추가 설치하므로 **GRUB 부트 메뉴를 통한 롤백이 가능**합니다.  
재부팅은 자동으로 수행되지 않으며, 완료 후 수동 재부팅 안내를 제공합니다.

## 주요 기능

- **CVE 기반 패치 관리**: `CVE_LIST` 변수에 점검할 CVE 코드를 지정하여 사전 및 사후 검증
- **자동 백업**: 패치 전 현재 커널 버전, GRUB 기본 설정, grub.cfg를 저장
- **비파괴 설치**: `rpm -ivh`(추가 설치)를 사용하여 기존 커널 삭제 없이 새 커널 추가
- **GRUB 자동 설정**: 설치 후 `grubby`로 새 커널을 기본 부팅 항목으로 지정
- **롤백 안내**: 이전 커널로 되돌리는 명령어를 백업 파일과 화면에 함께 제공
- **재부팅 안내**: 자동 재부팅 없이 수동 재부팅 방법을 안내
- **결과 보고서**: 패치 전후 버전, CVE 상태, 백업 경로 포함 보고서 자동 생성

## 시스템 요구사항

- Rocky Linux 9.x 또는 RHEL 9.x
- Root 권한
- 패치 RPM 파일 (아래 디렉토리 구조 참조)

## 파일 구성

```
kernel_patch/
├── patch_script.sh          # 패치 메인 스크립트
├── kernel/                  # 커널 패키지 RPM 폴더
│   ├── kernel-<ver>.rpm
│   ├── kernel-core-<ver>.rpm
│   ├── kernel-modules-<ver>.rpm
│   └── kernel-modules-core-<ver>.rpm
└── README.md                # 이 문서
```

현재 포함된 RPM (CVE-2026-23111 조치용):
```
kernel/
├── kernel-5.14.0-687.15.1.el9_8.x86_64.rpm
├── kernel-core-5.14.0-687.15.1.el9_8.x86_64.rpm
├── kernel-modules-5.14.0-687.15.1.el9_8.x86_64.rpm
└── kernel-modules-core-5.14.0-687.15.1.el9_8.x86_64.rpm
```

> **Rocky Linux 9.x 버전 호환성**: 커널은 userspace와 독립적으로 설치됩니다.  
> `el9_8` 태그의 커널 RPM은 Rocky Linux 9.0 ~ 9.7 서버에도 추가 설치 가능합니다.  
> Rocky Linux는 el9 메이저 버전 내 kABI(커널 ABI) 안정성을 보장합니다.

## 사용 방법

### 1. CVE 코드 설정

`patch_script.sh` 상단의 `CVE_LIST` 변수를 수정합니다:

```bash
CVE_LIST="CVE-2026-23111"
```

### 2. RPM 파일 배치

스크립트는 `/tmp/kernel_patch/kernel/` 경로를 기본 RPM 디렉토리로 사용합니다.  
배포 전 해당 경로로 폴더를 복사하거나 스크립트 내 `SCRIPT_DIR` 변수를 수정하세요:

```bash
# 배포 예시
cp -r kernel_patch/ /tmp/kernel_patch/
```

### 3. 스크립트 실행

```bash
chmod +x patch_script.sh
sudo ./patch_script.sh
```

### 4. 실행 중 확인 프롬프트

1. CVE 사전 확인 후, 패치가 changelog에 없으면 계속 진행 여부 확인
2. 커널 패치 진행 여부 최종 확인

### 5. 패치 완료 후 수동 재부팅

스크립트는 재부팅을 수행하지 않습니다. 안내된 명령어로 직접 재부팅하세요:

```bash
reboot
```

재부팅 후 커널 확인:
```bash
uname -r
# 예상 출력: 5.14.0-687.15.1.el9_8.x86_64
```

## 패치 프로세스 상세

```
1. OS 버전 감지 (Rocky Linux / RHEL 9.x 확인)
2. Root 권한 및 RPM 디렉토리 존재 확인
3. 필수 커널 패키지 4종 존재 확인
4. CVE 사전 검증 (패키지 changelog에서 CVE 코드 확인)
5. 현재 커널 정보 백업 (버전, GRUB 설정, grub.cfg)
6. 커널 패키지 설치 (rpm -ivh, 기존 커널 유지)
7. GRUB 기본 부팅 커널 설정 (grubby --set-default)
8. 설치 검증 (RPM 설치 확인, CVE changelog 확인)
9. 결과 보고서 파일 생성
10. 재부팅 안내 출력 (자동 재부팅 없음)
```

### ssl_ssh_patch와의 차이점

| 항목 | ssl_ssh_patch | kernel_patch |
|------|--------------|--------------|
| 설치 방식 | `rpm -Uvh` (교체) | `rpm -ivh` (추가) |
| 기존 버전 | 삭제됨 | GRUB에 보존 |
| 서비스 재시작 | sshd 재시작 | 해당 없음 |
| 재부팅 | 불필요 | **필수 (수동)** |
| 롤백 | 라이브러리 파일 복구 | grubby로 이전 커널 지정 |

## 백업 구조

```
/tmp/kernel_patch/backup/backup_YYYYMMDD_HHMMSS/
├── current_kernel.txt     # 패치 전 실행 중 커널 버전 (uname -r)
├── grub_default.txt       # 패치 전 GRUB 기본 커널 경로
├── installed_kernels.txt  # 패치 전 설치된 커널 전체 목록
├── grub.cfg.bak           # /boot/grub2/grub.cfg 백업
└── rollback_guide.txt     # 롤백 명령어 안내
```

## 출력 파일

| 파일 | 위치 | 내용 |
|------|------|------|
| 로그 파일 | `/tmp/kernel_patch/logs/patch_YYYYMMDD_HHMMSS.log` | 전체 실행 로그 |
| 결과 보고서 | `/tmp/kernel_patch/result_patch_YYYYMMDD_HHMMSS.log` | 패치 전후 버전, CVE 상태, 재부팅 안내 |

## 롤백 방법

새 커널로 재부팅 후 문제가 발생하면 이전 커널로 롤백할 수 있습니다.

### 방법 1: 명령어 롤백 (부팅 후 접속 가능한 경우)

```bash
# 이전 커널을 기본으로 재지정
grubby --set-default /boot/vmlinuz-<패치_전_커널_버전>

# 예시
grubby --set-default /boot/vmlinuz-5.14.0-503.35.1.el9_5.x86_64

# 재부팅
reboot
```

`<패치_전_커널_버전>` 확인:
```bash
cat /tmp/kernel_patch/backup/backup_*/current_kernel.txt
```

### 방법 2: GRUB 메뉴 (재부팅 시 직접 선택)

서버 재부팅 시 GRUB 메뉴에서 이전 커널 항목을 직접 선택할 수 있습니다.  
콘솔 접근이 가능한 경우 가장 빠른 롤백 방법입니다.

## 새 버전 RPM 다운로드 가이드

Rocky Linux 공식 저장소에서 최신 커널 RPM을 다운로드할 수 있습니다.

**공식 저장소 URL:**  
[https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/k/](https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/k/)

```bash
BASE="https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/k"
VER="5.14.0-687.15.1.el9_8.x86_64"

wget "$BASE/kernel-${VER}.rpm"
wget "$BASE/kernel-core-${VER}.rpm"
wget "$BASE/kernel-modules-${VER}.rpm"
wget "$BASE/kernel-modules-core-${VER}.rpm"
```

> **참고**: `<VER>` 부분은 저장소에서 확인한 실제 버전 문자열로 대체하세요.

## 주의사항

1. **Root 권한 필수**: 커널 설치와 GRUB 설정 변경에 root 권한이 필요합니다
2. **콘솔 접근 준비**: 재부팅 전 콘솔 또는 iDRAC/iLO 등 대역외 접속 수단을 확보하세요
3. **서비스 영향**: 커널 패치 적용은 재부팅 시점에 이루어집니다. 서비스 중단 시간을 계획하세요
4. **디스크 공간**: 커널 RPM 4종 약 100~150MB의 여유 공간이 `/boot`에 필요합니다
5. **테스트 환경 우선**: 프로덕션 적용 전 동일 OS 버전의 테스트 환경에서 먼저 검증하세요
