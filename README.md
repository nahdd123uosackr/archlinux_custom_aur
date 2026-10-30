# archlinux_custom_aur

Arch Linux용 커스텀 AUR 패키지 미러입니다. AUR에는 이 저장소의 `PKGBUILD`/`.SRCINFO`가 그대로 올라갑니다.

## 패키지

| 패키지 | 설명 | AUR |
|---|---|---|
| `ieumoffice-bin` | 이음오피스(IeumOffice) — DOCX/XLSX/PPTX/PDF/HWP/마크다운 오피스 (prebuilt rpm) | https://aur.archlinux.org/packages/ieumoffice-bin |

## 자동화 구조

```
GitHub Actions (30분마다, schedule)
  ├─ 업스트림 최신 릴리스 확인
  ├─ PKGBUILD/.SRCINFO 갱신 (pkgver + sha512 + source URL)
  ├─ makepkg --verifysource 로 체크섬 검증
  ├─ 이 저장소에 커밋
  └─ AUR 저장소에 push   ← secret AUR_SSH_PRIVATE_KEY 사용
```

로컬 데몬이 필요 없습니다. 서버에서 전 과정이 끝납니다.

- 확인 주기는 30분입니다. GitHub schedule 특성상 수 분~수십 분 지연될 수 있습니다.
- 공개 저장소는 60일간 커밋이 없으면 schedule이 자동 비활성화되므로, 매주 월요일 타임스탬프 커밋(keepalive)을 남깁니다.

## 최초 설정 (1회)

### 1. 전용 SSH 키 등록

CI 전용 키를 AUR 계정에 등록합니다. 로컬 작업용 키(`~/.ssh/aur`)와 분리하면 유출 시 해당 키만 삭제하면 됩니다.

```bash
ssh-keygen -t ed25519 -N '' -C 'aur-ci-github-actions' -f ~/.ssh/aur_ci
cat ~/.ssh/aur_ci.pub
```

출력된 공개키를 https://aur.archlinux.org/account/ 의 **SSH Public Key** 에 추가합니다.
(AUR은 계정 단위 키만 지원하며 패키지별 권한 제한은 없습니다.)

### 2. 저장소 secret 등록

```bash
gh secret set AUR_SSH_PRIVATE_KEY < ~/.ssh/aur_ci
```

웹 UI로 하려면 *Settings → Secrets and variables → Actions → New repository secret* 에서 이름 `AUR_SSH_PRIVATE_KEY`, 값은 `~/.ssh/aur_ci` 파일 내용 전체.

### 3. 워크플로 활성화 확인

*Actions* 탭에서 `AUR release sync` 를 한 번 `Run workflow` 로 수동 실행해 검증합니다.

## 수동 사용법

```bash
# 갱신 + 미러 커밋만 (AUR push 없음)
scripts/update-package.sh ieumoffice-bin pblsketch/openoffice v

# 로컬에서 AUR push (Actions 대신 수동으로 돌릴 때)
AUR_KEY=~/.ssh/aur scripts/deploy-aur.sh --dry-run
AUR_KEY=~/.ssh/aur scripts/deploy-aur.sh
```

`systemd/` 유닛은 로컬에서 주기 배포를 원할 때만 쓰는 선택 사항입니다(현재 구성에서는 불필요).

## 보안 메모

- CI 키는 **AUR 계정 전체 권한**을 가집니다. AUR이 저장소별 deploy key를 지원하지 않기 때문입니다.
- 따라서 ① 전용 키를 따로 만들고 ② 유출 의심 시 AUR 계정에서 해당 키만 삭제하는 것을 권장합니다.
- 워크플로 트리거는 `schedule` 과 `workflow_dispatch` 만 사용합니다. `pull_request` 계열 트리거는 쓰지 않으므로 포크 PR로 secret이 주입될 경로가 없습니다.
- 러너는 매 실행마다 파기되며, 스크립트는 push 직후 키 파일을 삭제합니다.

## 설치 (사용자)

```bash
yay -S ieumoffice-bin
```
