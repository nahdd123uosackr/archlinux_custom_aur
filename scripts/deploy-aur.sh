#!/usr/bin/env bash
# AUR push 전용 (로컬 실행)
#
# AUR SSH 개인키는 이 PC(~/.ssh/aur)에만 존재한다. GitHub에는 아무 자격증명도 두지 않는다.
#
# 사용법:
#   scripts/deploy-aur.sh              # 변경분만 push
#   scripts/deploy-aur.sh --dry-run    # 무엇이 바뀔지 확인
#
# 환경변수:
#   AUR_KEY   SSH 키 경로 (기본: ~/.ssh/aur)
#   AUR_ROOT  AUR 체크아웃 디렉터리 (기본: ~/.cache/aur-push)
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AUR_KEY=${AUR_KEY:-$HOME/.ssh/aur}
AUR_ROOT=${AUR_ROOT:-$HOME/.cache/aur-push}
DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1

[[ -f ${AUR_KEY} ]] || { echo "SSH 키가 없습니다: ${AUR_KEY}" >&2; exit 1; }
export GIT_SSH_COMMAND="ssh -i ${AUR_KEY} -o IdentitiesOnly=yes -o BatchMode=yes"

# 1) 미러 저장소 최신화 (변경이 없으면 즉시 종료)
git -C "${REPO_DIR}" pull --ff-only --quiet || { echo "pull 실패: ${REPO_DIR}" >&2; exit 1; }

changed=0
mkdir -p "${AUR_ROOT}"

shopt -s nullglob
for pkgdir in "${REPO_DIR}"/*/; do
  [[ -f ${pkgdir}PKGBUILD ]] || continue
  pkgbase=$(sed -n 's/^pkgbase = //p' "${pkgdir}.SRCINFO" 2>/dev/null | head -1)
  [[ -z ${pkgbase} ]] && pkgbase=$(basename "${pkgdir}")

  aur_dir="${AUR_ROOT}/${pkgbase}"
  if [[ -d ${aur_dir}/.git ]]; then
    git -C "${aur_dir}" pull --ff-only --quiet || true
  else
    git clone --quiet "ssh://aur@aur.archlinux.org/${pkgbase}.git" "${aur_dir}" 2>/dev/null \
      || { echo "AUR에 ${pkgbase} 저장소가 없습니다 (최초 등록은 수동 push 필요)" >&2; continue; }
  fi

  # .SRCINFO 일치 검증 후 복사
  if ! diff -q "${pkgdir}PKGBUILD" "${aur_dir}/PKGBUILD" >/dev/null 2>&1 \
     || ! diff -q "${pkgdir}.SRCINFO" "${aur_dir}/.SRCINFO" >/dev/null 2>&1; then
    ver=$(sed -n 's/^pkgver=//p' "${pkgdir}PKGBUILD")
    rel=$(sed -n 's/^pkgrel=//p' "${pkgdir}PKGBUILD")
    echo "변경 감지: ${pkgbase} ${ver}-${rel}"

    if (( DRY_RUN )); then
      diff -u "${aur_dir}/PKGBUILD" "${pkgdir}PKGBUILD" || true
      changed=1
      continue
    fi

    cp "${pkgdir}PKGBUILD" "${pkgdir}.SRCINFO" "${aur_dir}/"
    git -C "${aur_dir}" add PKGBUILD .SRCINFO
    git -C "${aur_dir}" commit -q -m "upgpkg: ${pkgbase} ${ver}-${rel}"
    git -C "${aur_dir}" push -q
    echo "AUR push 완료: ${pkgbase} ${ver}-${rel}"
    changed=1
  fi
done

(( changed )) || echo "AUR에 반영할 변경 없음"
