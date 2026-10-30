#!/usr/bin/env bash
# PKGBUILD 자동 갱신 (CI/로컬 공용)
#
# 사용법: scripts/update-package.sh <패키지디렉터리> <github-owner/repo> [태그접두사]
# 예:    scripts/update-package.sh ieumoffice-bin pblsketch/openoffice v
#
# 환경변수:
#   BUMP_PKGREL=1  업스트림이 최신일 때 pkgrel만 올려 AUR push 경로를 검증한다
#
# 출력: 마지막 줄 CHANGED=1 (변경 있음) 또는 CHANGED=0 (변경 없음)
set -euo pipefail

pkgdir=${1:?package dir required}
ghrepo=${2:?github owner/repo required}
pretag=${3:-v}
api="https://api.github.com/repos/${ghrepo}"
dl="https://github.com/${ghrepo}/releases/download"

[[ -f ${pkgdir}/PKGBUILD ]] || { echo "PKGBUILD not found: ${pkgdir}" >&2; exit 1; }
command -v makepkg >/dev/null 2>&1 || { echo "makepkg 없음" >&2; exit 1; }

gen_srcinfo() {
  local dir=$1 builder buildtmp
  if [[ ${EUID} -ne 0 ]]; then
    ( cd "${dir}" && makepkg --printsrcinfo > .SRCINFO )
    return
  fi
  builder=$(id -un corp 2>/dev/null || id -un builder 2>/dev/null || true)
  [[ -z ${builder} ]] && { echo "root 실행: makepkg용 일반 사용자를 찾을 수 없습니다" >&2; return 1; }
  buildtmp=$(mktemp -d)
  cp "${dir}/PKGBUILD" "${buildtmp}/"
  chown -R "${builder}" "${buildtmp}"
  su -s /bin/bash "${builder}" -c "cd '${buildtmp}' && makepkg --printsrcinfo" > "${dir}/.SRCINFO"
  rm -rf "${buildtmp}"
}

tag=$(curl -fsSL --retry 3 "${api}/releases/latest" | jq -r '.tag_name')
[[ -n ${tag} && ${tag} != null ]] || { echo "cannot read latest tag" >&2; exit 1; }
newver=${tag#"$pretag"}
oldver=$(sed -n 's/^pkgver=//p' "${pkgdir}/PKGBUILD")

echo "latest tag=${tag} -> pkgver=${newver} (local=${oldver})"

if [[ ${newver} == "${oldver}" ]]; then
  if [[ ${BUMP_PKGREL:-0} == 1 ]]; then
    oldrel=$(sed -n 's/^pkgrel=//p' "${pkgdir}/PKGBUILD")
    newrel=$(( oldrel + 1 ))
    echo "동일 버전 - AUR push 경로 검증을 위해 pkgrel ${oldrel} -> ${newrel}"
    sed -i "s/^pkgrel=.*/pkgrel=${newrel}/" "${pkgdir}/PKGBUILD"
    gen_srcinfo "${pkgdir}"
    echo ".SRCINFO 갱신 완료"
    echo "CHANGED=1"
    exit 0
  fi
  echo "이미 최신입니다."
  echo "CHANGED=0"
  exit 0
fi

mapfile -t assets < <(curl -fsSL --retry 3 "${api}/releases/latest" | jq -r '.assets[].name')
pick() { printf '%s\n' "${assets[@]}" | grep -E "$1" | head -1 || true; }

rpm=$(pick '\.rpm$')
appimage=$(pick '\.AppImage$')
license_url="https://raw.githubusercontent.com/${ghrepo}/${tag}/LICENSE"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

declare -a urls=() sums=()

if [[ -n ${rpm} ]]; then
  asset=${rpm}
elif [[ -n ${appimage} ]]; then
  asset=${appimage}
else
  echo "no .rpm/.AppImage asset in ${tag}" >&2
  exit 1
fi

echo "asset: ${asset}"
curl -fsSL --retry 3 -o "${tmp}/${asset}" "${dl}/${tag}/${asset}"
urls+=("${dl}/${tag}/${asset}")
sums+=("$(sha512sum "${tmp}/${asset}" | cut -d' ' -f1)")
rm -f "${tmp}/${asset}"

curl -fsSL --retry 3 -o "${tmp}/LICENSE" "${license_url}"
urls+=("${license_url}")
sums+=("$(sha512sum "${tmp}/LICENSE" | cut -d' ' -f1)")

python3 - "$pkgdir" "$newver" "${urls[@]}" -- "${sums[@]}" <<'PY'
import re, sys
path, ver = sys.argv[1], sys.argv[2]
argv = sys.argv[3:]
sep = argv.index('--')
urls, sums = argv[:sep], argv[sep+1:]
file = f"{path}/PKGBUILD"
text = open(file, encoding='utf-8').read()
text = re.sub(r'^pkgver=.*$', f'pkgver={ver}', text, flags=re.M)
text = re.sub(r'^pkgrel=.*$', 'pkgrel=1', text, flags=re.M)
src = "source=(" + "\n        ".join(f'"{u}"' for u in urls) + "\n)"
text = re.sub(r'^source=\(.*?\)\n', src + "\n", text, flags=re.M | re.S, count=1)
sha = "sha512sums=(" + "\n            ".join(f"'{s}'" for s in sums) + "\n)"
text = re.sub(r"^sha512sums=\(.*?\)\n", sha + "\n", text, flags=re.M | re.S, count=1)
open(file, 'w', encoding='utf-8').write(text)
print(f"PKGBUILD -> {ver}")
PY

gen_srcinfo "${pkgdir}"
echo ".SRCINFO 갱신 완료"
echo "CHANGED=1"
