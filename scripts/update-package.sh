#!/usr/bin/env bash
# PKGBUILD 자동 갱신 (CI/로컬 공용)
#
# 사용법: scripts/update-package.sh <패키지디렉터리> <github-owner/repo> [태그접두사]
# 예:    scripts/update-package.sh ieumoffice-bin pblsketch/openoffice v
#
# 동작:
#   1) GitHub 최신 릴리스 태그를 읽어 버전을 뽑는다
#   2) PKGBUILD의 pkgver와 같으면 아무것도 하지 않는다 (exit 0)
#   3) 다르면 source URL / pkgver / pkgrel / sha512sums를 갱신하고 .SRCINFO를 다시 만든다
#   4) 변경이 있었으면 마지막 줄에 CHANGED=1 을 출력한다
set -euo pipefail

pkgdir=${1:?package dir required}
ghrepo=${2:?github owner/repo required}
pretag=${3:-v}
api="https://api.github.com/repos/${ghrepo}"
dl="https://github.com/${ghrepo}/releases/download"

[[ -f ${pkgdir}/PKGBUILD ]] || { echo "PKGBUILD not found: ${pkgdir}" >&2; exit 1; }

tag=$(curl -fsSL --retry 3 "${api}/releases/latest" | jq -r '.tag_name')
[[ -n ${tag} && ${tag} != null ]] || { echo "cannot read latest tag" >&2; exit 1; }
newver=${tag#"$pretag"}
oldver=$(sed -n 's/^pkgver=//p' "${pkgdir}/PKGBUILD")

echo "latest tag=${tag} -> pkgver=${newver} (local=${oldver})"
if [[ ${newver} == "${oldver}" ]]; then
  echo "이미 최신입니다."
  echo "CHANGED=0"
  exit 0
fi

# 릴리스 자산에서 source 파일 이름을 찾는다 (rpm 우선, 없으면 AppImage)
mapfile -t assets < <(curl -fsSL --retry 3 "${api}/releases/latest" | jq -r '.assets[].name')
pick() { local pat=$1; printf '%s\n' "${assets[@]}" | grep -E "${pat}" | head -1 || true; }

rpm=$(pick '\.rpm$')
appimage=$(pick '\.AppImage$')
license_url="https://raw.githubusercontent.com/${ghrepo}/${tag}/LICENSE"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

declare -a urls=() sums=()

if [[ -n ${rpm} ]]; then
  echo "asset: ${rpm}"
  curl -fsSL --retry 3 -o "${tmp}/${rpm}" "${dl}/${tag}/${rpm}"
  urls+=("${dl}/${tag}/${rpm}")
  sums+=("$(sha512sum "${tmp}/${rpm}" | cut -d' ' -f1)")
  rm -f "${tmp}/${rpm}"
elif [[ -n ${appimage} ]]; then
  echo "asset: ${appimage}"
  curl -fsSL --retry 3 -o "${tmp}/${appimage}" "${dl}/${tag}/${appimage}"
  urls+=("${dl}/${tag}/${appimage}")
  sums+=("$(sha512sum "${tmp}/${appimage}" | cut -d' ' -f1)")
  rm -f "${tmp}/${appimage}"
else
  echo "no .rpm/.AppImage asset in ${tag}" >&2
  exit 1
fi

curl -fsSL --retry 3 -o "${tmp}/LICENSE" "${license_url}"
urls+=("${license_url}")
sums+=("$(sha512sum "${tmp}/LICENSE" | cut -d' ' -f1)")

# PKGBUILD 갱신 (python로 안전하게 치환)
python3 - "$pkgdir" "$newver" "$tag" "${urls[@]}" -- "${sums[@]}" <<'PY'
import re, sys
path, ver, tag = sys.argv[1], sys.argv[2], sys.argv[3]
argv = sys.argv[4:]
sep = argv.index('--')
urls, sums = argv[:sep], argv[sep+1:]
text = open(f"{path}/PKGBUILD", encoding='utf-8').read()
text = re.sub(r'^pkgver=.*$', f'pkgver={ver}', text, flags=re.M)
text = re.sub(r'^pkgrel=.*$', 'pkgrel=1', text, flags=re.M)
if 'releases/download/v${pkgver}' not in text:
    raise SystemExit('source URL pattern not found (expected releases/download/v${pkgver})')
src = "source=(" + "\n        ".join(f'"{u}"' for u in urls) + "\n)"
text = re.sub(r'^source=\(.*?\)\n', src + "\n", text, flags=re.M | re.S, count=1)
sha = "sha512sums=(" + "\n            ".join(f"'{s}'" for s in sums) + "\n)"
text = re.sub(r"^sha512sums=\(.*?\)\n", sha + "\n", text, flags=re.M | re.S, count=1)
open(f"{path}/PKGBUILD", 'w', encoding='utf-8').write(text)
print(f"PKGBUILD -> {ver}")
PY

# .SRCINFO 재생성 (makepkg 필요, root로는 실행 불가하므로 임시 디렉터리 + 일반 사용자)
if ! command -v makepkg >/dev/null 2>&1; then
  echo "경고: makepkg 없음 - .SRCINFO를 갱신하지 못했습니다" >&2
  exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
  ( cd "${pkgdir}" && makepkg --printsrcinfo > .SRCINFO )
else
  builder=$(id -un corp 2>/dev/null || id -un builder 2>/dev/null || true)
  [[ -z ${builder} ]] && { echo "root 실행: makepkg용 일반 사용자를 찾을 수 없습니다" >&2; exit 1; }
  buildtmp=$(mktemp -d)
  cp "${pkgdir}/PKGBUILD" "${buildtmp}/"
  chown -R "${builder}" "${buildtmp}"
  su -s /bin/bash "${builder}" -c "cd '${buildtmp}' && makepkg --printsrcinfo" > "${pkgdir}/.SRCINFO"
  rm -rf "${buildtmp}"
fi
echo ".SRCINFO 갱신 완료"

echo "CHANGED=1"
