#!/usr/bin/env bash
# PKGBUILD 자동 갱신 (CI/로컬 공용)
#
# 사용법: scripts/update-package.sh <패키지디렉터리> <github-owner/repo> [태그접두사] [asset 정규식] [추가 소스 경로...]
# 예:    scripts/update-package.sh ieumoffice-bin pblsketch/openoffice v
#        scripts/update-package.sh copilot-desktop-gtk-bin sirredbeard/copilot-desktop-gtk v \
#            '^copilot-desktop-gtk-x86_64$' LICENSE NOTICE assets/desktop/copilot-desktop-gtk.desktop
#
# asset 정규식: 릴리스 asset 이름을 직접 지정한다 (.rpm/.AppImage/tar.gz 자동 탐색 생략).
# 추가 소스 경로: 해당 태그의 raw.githubusercontent.com 기준 경로. 미지정 시 LICENSE만 받는다.
#
# 환경변수:
#   BUMP_PKGREL=1        업스트림이 최신일 때 pkgrel만 올려 AUR push 경로를 검증한다
#   INCLUDE_PRERELEASE=1 /releases/latest 대신 pre-release 를 포함한 최신 릴리스를 쓴다
#
# 출력: 마지막 줄 CHANGED=1 (변경 있음) 또는 CHANGED=0 (변경 없음)
set -euo pipefail

pkgdir=${1:?package dir required}
ghrepo=${2:?github owner/repo required}
pretag=${3:-v}
asset_re=${4:-}
extra_sources=()
if (( $# > 4 )); then
    extra_sources=("${@:5}")
fi
api="https://api.github.com/repos/${ghrepo}"
dl="https://github.com/${ghrepo}/releases/download"

github_api_curl() {
    local args=(-fsSL --retry 3)
    if [[ -n ${GITHUB_TOKEN:-} ]]; then
        local auth_header
        auth_header="Authorization: Bearer "
        auth_header+="${GITHUB_TOKEN}"
        args+=(
            -H "$auth_header"
            -H "Accept: application/vnd.github+json"
            -H "X-GitHub-Api-Version: 2022-11-28"
        )
    fi
    curl "${args[@]}" "$@"
}

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

if [[ ${INCLUDE_PRERELEASE:-0} == 1 ]]; then
  # 일부 업스트림은 새 빌드를 pre-release 로만 올린다 (예: copilot-desktop-gtk).
  release_json=$(github_api_curl "${api}/releases?per_page=20" \
    | jq -c '[.[] | select(.draft == false)][0]')
else
  release_json=$(github_api_curl "${api}/releases/latest")
fi
tag=$(printf '%s' "${release_json}" | jq -r '.tag_name')
[[ -n ${tag} && ${tag} != null ]] || { echo "cannot read latest tag" >&2; exit 1; }
newver=${tag#"$pretag"}
oldver=$(sed -n 's/^pkgver=//p' "${pkgdir}/PKGBUILD")

echo "latest tag=${tag} -> pkgver=${newver} (local=${oldver})"

if [[ ${newver} != "${oldver}" ]] && command -v vercmp >/dev/null 2>&1; then
  if (( $(vercmp "${newver}" "${oldver}") < 0 )); then
    echo "업스트림 ${newver} 이(가) 로컬 ${oldver} 보다 낮아 건너뜁니다 (다운그레이드 방지)."
    echo "CHANGED=0"
    exit 0
  fi
fi

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

mapfile -t assets < <(printf '%s' "${release_json}" | jq -r '.assets[].name')
pick() { printf '%s\n' "${assets[@]}" | grep -E "$1" | head -1 || true; }

rpm=$(pick '\.rpm$')
appimage=$(pick '\.AppImage$')
tar_x86_64=$(pick '(^|/)rhwp-v[0-9][^/]*-linux-x86_64\.tar\.gz$|^rhwp-v[0-9].*-linux-x86_64\.tar\.gz$|linux-x86_64\.tar\.gz$')

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

declare -a urls=() sums=()

if [[ -n ${asset_re} ]]; then
  asset=$(pick "${asset_re}")
  if [[ -z ${asset} ]]; then
    echo "asset 정규식과 일치하는 릴리스 파일이 없습니다: ${asset_re} (${tag})"
    echo "CHANGED=0"
    exit 0
  fi
elif [[ -n ${rpm} ]]; then
  asset=${rpm}
elif [[ -n ${appimage} ]]; then
  asset=${appimage}
elif [[ -n ${tar_x86_64} ]]; then
  asset=${tar_x86_64}
else
  echo "지원되는 릴리스 asset이 아직 없습니다 (.rpm, .AppImage, linux-x86_64.tar.gz): ${tag}"
  echo "릴리스 asset이 게시될 때까지 패키지를 건너뜁니다."
  echo "CHANGED=0"
  exit 0
fi

echo "asset: ${asset}"
curl -fsSL --retry 3 -o "${tmp}/${asset}" "${dl}/${tag}/${asset}"
urls+=("${dl}/${tag}/${asset}")
sums+=("$(sha512sum "${tmp}/${asset}" | cut -d' ' -f1)")
rm -f "${tmp}/${asset}"

raw_paths=(LICENSE)
if (( ${#extra_sources[@]} > 0 )); then
  raw_paths=("${extra_sources[@]}")
fi

declare -A used_names=()
for path in "${raw_paths[@]}"; do
  fname=${path##*/}
  if [[ -n ${used_names[${fname}]:-} ]]; then
    echo "추가 소스 파일명이 중복됩니다: ${fname}" >&2
    exit 1
  fi
  used_names[${fname}]=1
  raw_url="https://raw.githubusercontent.com/${ghrepo}/${tag}/${path}"
  curl -fsSL --retry 3 -o "${tmp}/${fname}" "${raw_url}"
  urls+=("${raw_url}")
  sums+=("$(sha512sum "${tmp}/${fname}" | cut -d' ' -f1)")
  rm -f "${tmp}/${fname}"
done

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
