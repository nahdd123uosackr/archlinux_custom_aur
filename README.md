# archlinux_custom_aur

Arch Linux용 커스텀 AUR 패키지 미러입니다. AUR에는 이 저장소의 `PKGBUILD`/`.SRCINFO`가 그대로 올라갑니다.

## 패키지

| 패키지 | 설명 | AUR |
|---|---|---|
| `ieumoffice-bin` | 이음오피스(IeumOffice) — DOCX/XLSX/PPTX/PDF/HWP/마크다운 오피스 (prebuilt rpm) | https://aur.archlinux.org/packages/ieumoffice-bin |

## 구조

```
ieumoffice-bin/            PKGBUILD, .SRCINFO
scripts/update-package.sh  최신 릴리스 확인 → PKGBUILD/.SRCINFO 자동 갱신
scripts/deploy-aur.sh      갱신분을 AUR로 push (로컬 SSH 키 사용)
systemd/                   주기적 배포용 유닛 (선택)
.github/workflows/         GitHub Actions: 갱신 커밋만 수행 (자격증명 없음)
```

## 자동 갱신 흐름

```
GitHub Actions (secret 없음)
  매일 업스트림 릴리스 확인 → PKGBUILD/.SRCINFO 갱신 → 이 저장소에 커밋
        ↓
로컬 PC (scripts/deploy-aur.sh, ~/.ssh/aur)
  git pull → AUR로 push
```

AUR SSH 개인키는 **로컬에만** 존재합니다. GitHub Actions에는 어떤 자격증명도 등록하지 않습니다.

## 수동 사용법

```bash
# 1) 갱신 확인 (변경 있으면 커밋)
scripts/update-package.sh ieumoffice-bin pblsketch/openoffice v

# 2) AUR로 배포
scripts/deploy-aur.sh --dry-run   # 미리보기
scripts/deploy-aur.sh             # 실제 push

# 3) 자동 배포 타이머 (선택)
mkdir -p ~/.config/systemd/user
cp systemd/aur-deploy.* ~/.config/systemd/user/
systemctl --user enable --now aur-deploy.timer
```

## 설치 (사용자)

```bash
yay -S ieumoffice-bin
```
