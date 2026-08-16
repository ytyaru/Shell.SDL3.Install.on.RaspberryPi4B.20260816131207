#!/usr/bin/env bash
#
# Raspberry Pi 4B (aarch64) 用
#
# SDL3 本体 + SDL3_image + SDL3_ttf + SDL3_mixer + SDL3_net
# を GitHub の最新安定版から取得してビルドし、
# checkinstall で Debian パッケージとしてインストールする。
#
# 作業場所: /tmp/sdl3-build
#
# 再実行すると、その時点の GitHub 最新安定版を再取得して更新する。
#
# 必要:
#   Raspberry Pi OS / Debian 系
#   sudo 権限
#
# インストール後:
#
#   g++ test_sdl3.cpp -o test_sdl3 \
#       $(pkg-config --cflags --libs \
#           sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)
#
# ================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------
# 設定
# ----------------------------------------------------------------

WORK_ROOT="/tmp/sdl3-build"
PREFIX="/usr/local"

# Raspberry Pi 4B 4GB では過剰な並列化を避ける。
BUILD_JOBS="${BUILD_JOBS:-2}"

# GitHub API
GITHUB_API="https://api.github.com/repos"

# SDL 関連リポジトリ
SDL_REPO="libsdl-org/SDL"
SDL_IMAGE_REPO="libsdl-org/SDL_image"
SDL_TTF_REPO="libsdl-org/SDL_ttf"
SDL_MIXER_REPO="libsdl-org/SDL_mixer"
SDL_NET_REPO="libsdl-org/SDL_net"

# ----------------------------------------------------------------
# 日本語メッセージ
# ----------------------------------------------------------------

info()
{
    echo
    echo "==> $*"
}

ok()
{
    echo "    [OK] $*"
}

warn()
{
    echo "    [警告] $*" >&2
}

die()
{
    echo
    echo "[ERROR] $*" >&2
    exit 1
}

trap '
    echo
    echo "[ERROR] スクリプトの実行に失敗しました。"
    echo "[ERROR] 行番号: ${LINENO}"
    echo "[ERROR] コマンド: ${BASH_COMMAND}"
' ERR

# ----------------------------------------------------------------
# root確認
# ----------------------------------------------------------------

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# ----------------------------------------------------------------
# CPU確認
# ----------------------------------------------------------------

ARCH="$(uname -m)"

if [[ "${ARCH}" != "aarch64" ]]; then
    warn "このスクリプトは Raspberry Pi 4B の aarch64 を想定しています。"
    warn "現在のCPUアーキテクチャ: ${ARCH}"
fi

# ----------------------------------------------------------------
# Raspberry Pi / Debian確認
# ----------------------------------------------------------------

if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get が見つかりません。Debian系OSで実行してください。"
fi

# ----------------------------------------------------------------
# 必須ツール・SDL3フル機能用依存パッケージ
# ----------------------------------------------------------------

info "必要なビルド環境とSDL3関連依存パッケージをインストールします"

${SUDO} apt-get update

${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    git \
    curl \
    ca-certificates \
    pkg-config \
    cmake \
    ninja-build \
    checkinstall \
    fakeroot \
    dpkg-dev \
    make \
    gcc \
    g++ \
    python3 \
    perl \
    \
    libasound2-dev \
    libpulse-dev \
    libpipewire-0.3-dev \
    libjack-dev \
    libsndio-dev \
    \
    libx11-dev \
    libxext-dev \
    libxrandr-dev \
    libxcursor-dev \
    libxfixes-dev \
    libxi-dev \
    libxss-dev \
    libxtst-dev \
    libxrender-dev \
    libxinerama-dev \
    libxkbcommon-dev \
    \
    libwayland-dev \
    wayland-protocols \
    libdecor-0-dev \
    \
    libdrm-dev \
    libgbm-dev \
    libgl1-mesa-dev \
    libgles2-mesa-dev \
    libegl1-mesa-dev \
    \
    libvulkan-dev \
    \
    libdbus-1-dev \
    libibus-1.0-dev \
    libudev-dev \
    libusb-1.0-0-dev \
    \
    libthai-dev \
    libfribidi-dev \
    liburing-dev

ok "依存パッケージの準備完了"

# ----------------------------------------------------------------
# checkinstall確認
# ----------------------------------------------------------------

command -v checkinstall >/dev/null 2>&1 \
    || die "checkinstall のインストールに失敗しました"

command -v git >/dev/null 2>&1 \
    || die "git が見つかりません"

command -v curl >/dev/null 2>&1 \
    || die "curl が見つかりません"

command -v cmake >/dev/null 2>&1 \
    || die "cmake が見つかりません"

command -v pkg-config >/dev/null 2>&1 \
    || die "pkg-config が見つかりません"

# ----------------------------------------------------------------
# 作業ディレクトリ
# ----------------------------------------------------------------

info "作業ディレクトリを準備します"

rm -rf "${WORK_ROOT}"
mkdir -p "${WORK_ROOT}"

cd "${WORK_ROOT}"

ok "作業場所: ${WORK_ROOT}"

# ----------------------------------------------------------------
# GitHub APIから最新安定版タグを取得
#
# prerelease / draft は除外する。
# GitHub Releases の latest release を使用する。
# ----------------------------------------------------------------

get_latest_release_tag()
{
    local repo="$1"
    local json
    local tag

    info "GitHubから ${repo} の最新安定版を確認します"

    json="$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --retry 5 \
            --retry-delay 2 \
            --connect-timeout 15 \
            --max-time 60 \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/${repo}/releases?per_page=30"
    )"

    tag="$(
        printf '%s\n' "${json}" |
        python3 -c '
import json
import sys

releases = json.load(sys.stdin)

for release in releases:
    if release.get("draft"):
        continue

    if release.get("prerelease"):
        continue

    tag = release.get("tag_name")
    if tag:
        print(tag)
        break
'
    )"

    if [[ -z "${tag}" ]]; then
        die "${repo} の安定版リリースタグを取得できませんでした"
    fi

    echo "${tag}"
}

# ----------------------------------------------------------------
# Git clone
# ----------------------------------------------------------------

clone_release()
{
    local repo="$1"
    local tag="$2"
    local name="$3"

    info "${name} ${tag} を取得します"

    git clone \
        --depth 1 \
        --branch "${tag}" \
        --single-branch \
        "https://github.com/${repo}.git" \
        "${name}"

    ok "${name}: ${tag}"
}

# ----------------------------------------------------------------
# バージョン取得
# ----------------------------------------------------------------

SDL_TAG="$(get_latest_release_tag "${SDL_REPO}")"
SDL_IMAGE_TAG="$(get_latest_release_tag "${SDL_IMAGE_REPO}")"
SDL_TTF_TAG="$(get_latest_release_tag "${SDL_TTF_REPO}")"
SDL_MIXER_TAG="$(get_latest_release_tag "${SDL_MIXER_REPO}")"
SDL_NET_TAG="$(get_latest_release_tag "${SDL_NET_REPO}")"

echo
echo "==============================================================="
echo "取得するSDL3関連バージョン"
echo "==============================================================="
echo "SDL3        : ${SDL_TAG}"
echo "SDL3_image  : ${SDL_IMAGE_TAG}"
echo "SDL3_ttf    : ${SDL_TTF_TAG}"
echo "SDL3_mixer  : ${SDL_MIXER_TAG}"
echo "SDL3_net    : ${SDL_NET_TAG}"
echo "==============================================================="
echo

# ----------------------------------------------------------------
# ソース取得
# ----------------------------------------------------------------

clone_release "${SDL_REPO}"       "${SDL_TAG}"       "SDL"
clone_release "${SDL_IMAGE_REPO}" "${SDL_IMAGE_TAG}" "SDL_image"
clone_release "${SDL_TTF_REPO}"   "${SDL_TTF_TAG}"   "SDL_ttf"
clone_release "${SDL_MIXER_REPO}" "${SDL_MIXER_TAG}" "SDL_mixer"
clone_release "${SDL_NET_REPO}"   "${SDL_NET_TAG}"   "SDL_net"

# ----------------------------------------------------------------
# Gitタグからパッケージバージョンを作る
#
# 例:
#   release-3.4.12 -> 3.4.12
# ----------------------------------------------------------------

version_from_tag()
{
    local tag="$1"

    tag="${tag#release-}"
    tag="${tag#v}"

    printf '%s\n' "${tag}"
}

SDL_VERSION="$(version_from_tag "${SDL_TAG}")"
SDL_IMAGE_VERSION="$(version_from_tag "${SDL_IMAGE_TAG}")"
SDL_TTF_VERSION="$(version_from_tag "${SDL_TTF_TAG}")"
SDL_MIXER_VERSION="$(version_from_tag "${SDL_MIXER_TAG}")"
SDL_NET_VERSION="$(version_from_tag "${SDL_NET_TAG}")"

# ----------------------------------------------------------------
# SDL3本体
# ----------------------------------------------------------------

build_sdl()
{
    info "SDL3 ${SDL_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=ON \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL=ON \
        -DSDL_INSTALL_DOCS=OFF \
        -DSDL_RELOCATABLE=OFF \
        -DSDL_PRESEED=ON \
        -DSDL_HIDAPI=ON \
        -DSDL_HIDAPI_LIBUSB=ON \
        -DSDL_HIDAPI_JOYSTICK=ON \
        -DSDL_VULKAN=ON \
        -DSDL_OPENGL=ON \
        -DSDL_OPENGLES=ON \
        -DSDL_WAYLAND=ON \
        -DSDL_KMSDRM=ON \
        -DSDL_X11=ON \
        -DSDL_LIBUDEV=ON \
        -DSDL_DBUS=ON \
        -DSDL_IBUS=ON \
        -DSDL_LIBURING=ON \
        -DSDL_PTHREADS=ON \
        -DSDL_FRIBIDI=ON \
        -DSDL_LIBTHAI=ON

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    ok "SDL3のビルド完了"

    info "SDL3をcheckinstallでDebianパッケージ化してインストールします"

    cd build

    ${SUDO} checkinstall \
        --default \
        --install=yes \
        --fstrans=no \
        --backup=no \
        --pakdir="${WORK_ROOT}/packages" \
        --pkgname="libsdl3" \
        --pkgversion="${SDL_VERSION}" \
        --pkgrelease="1" \
        --pkgarch="arm64" \
        --maintainer="local" \
        --nodoc \
        --deldoc=yes \
        --backup=no \
        --strip=yes \
        --stripso=yes \
        cmake --install . --prefix "${PREFIX}"

    ok "SDL3のインストール完了"
}

# ----------------------------------------------------------------
# SDL3_image
# ----------------------------------------------------------------

build_sdl_image()
{
    info "SDL3_image ${SDL_IMAGE_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_image"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
        -DBUILD_SHARED_LIBS=ON \
        -DSDLIMAGE_INSTALL=ON \
        -DSDLIMAGE_VENDORED=ON \
        -DSDLIMAGE_STRICT=OFF \
        -DSDLIMAGE_SAMPLES=OFF \
        -DSDLIMAGE_TESTS=OFF \
        -DSDLIMAGE_BACKEND_STB=ON

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    ${SUDO} checkinstall \
        --default \
        --install=yes \
        --fstrans=no \
        --backup=no \
        --pakdir="${WORK_ROOT}/packages" \
        --pkgname="libsdl3-image" \
        --pkgversion="${SDL_IMAGE_VERSION}" \
        --pkgrelease="1" \
        --pkgarch="arm64" \
        --maintainer="local" \
        --nodoc \
        --deldoc=yes \
        --strip=yes \
        --stripso=yes \
        cmake --install . --prefix "${PREFIX}"

    ok "SDL3_imageのインストール完了"
}

# ----------------------------------------------------------------
# SDL3_ttf
# ----------------------------------------------------------------

build_sdl_ttf()
{
    info "SDL3_ttf ${SDL_TTF_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_ttf"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
        -DBUILD_SHARED_LIBS=ON \
        -DSDLTTF_INSTALL=ON \
        -DSDLTTF_VENDORED=ON \
        -DSDLTTF_HARFBUZZ=ON \
        -DSDLTTF_STRICT=OFF \
        -DSDLTTF_SAMPLES=OFF

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    ${SUDO} checkinstall \
        --default \
        --install=yes \
        --fstrans=no \
        --backup=no \
        --pakdir="${WORK_ROOT}/packages" \
        --pkgname="libsdl3-ttf" \
        --pkgversion="${SDL_TTF_VERSION}" \
        --pkgrelease="1" \
        --pkgarch="arm64" \
        --maintainer="local" \
        --nodoc \
        --deldoc=yes \
        --strip=yes \
        --stripso=yes \
        cmake --install . --prefix "${PREFIX}"

    ok "SDL3_ttfのインストール完了"
}

# ----------------------------------------------------------------
# SDL3_mixer
# ----------------------------------------------------------------

build_sdl_mixer()
{
    info "SDL3_mixer ${SDL_MIXER_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_mixer"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
        -DBUILD_SHARED_LIBS=ON \
        -DSDLMIXER_INSTALL=ON \
        -DSDLMIXER_VENDORED=ON \
        -DSDLMIXER_STRICT=OFF \
        -DSDLMIXER_TESTS=OFF \
        -DSDLMIXER_EXAMPLES=OFF \
        \
        -DSDLMIXER_AIFF=ON \
        -DSDLMIXER_WAVE=ON \
        -DSDLMIXER_VOC=ON \
        -DSDLMIXER_AU=ON \
        -DSDLMIXER_FLAC=ON \
        -DSDLMIXER_GME=ON \
        -DSDLMIXER_MOD=ON \
        -DSDLMIXER_MOD_XMP=ON \
        -DSDLMIXER_MP3=ON \
        -DSDLMIXER_OGG=ON \
        -DSDLMIXER_OPUS=ON \
        -DSDLMIXER_MIDI=ON \
        -DSDLMIXER_MIDI_FLUIDSYNTH=ON

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    ${SUDO} checkinstall \
        --default \
        --install=yes \
        --fstrans=no \
        --backup=no \
        --pakdir="${WORK_ROOT}/packages" \
        --pkgname="libsdl3-mixer" \
        --pkgversion="${SDL_MIXER_VERSION}" \
        --pkgrelease="1" \
        --pkgarch="arm64" \
        --maintainer="local" \
        --nodoc \
        --deldoc=yes \
        --strip=yes \
        --stripso=yes \
        cmake --install . --prefix "${PREFIX}"

    ok "SDL3_mixerのインストール完了"
}

# ----------------------------------------------------------------
# SDL3_net
# ----------------------------------------------------------------

build_sdl_net()
{
    info "SDL3_net ${SDL_NET_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_net"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
        -DBUILD_SHARED_LIBS=ON \
        -DSDLNET_INSTALL=ON \
        -DSDLNET_TESTS=OFF \
        -DSDLNET_EXAMPLES=OFF

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    ${SUDO} checkinstall \
        --default \
        --install=yes \
        --fstrans=no \
        --backup=no \
        --pakdir="${WORK_ROOT}/packages" \
        --pkgname="libsdl3-net" \
        --pkgversion="${SDL_NET_VERSION}" \
        --pkgrelease="1" \
        --pkgarch="arm64" \
        --maintainer="local" \
        --nodoc \
        --deldoc=yes \
        --strip=yes \
        --stripso=yes \
        cmake --install . --prefix "${PREFIX}"

    ok "SDL3_netのインストール完了"
}

# ----------------------------------------------------------------
# 実行
# ----------------------------------------------------------------

mkdir -p "${WORK_ROOT}/packages"

build_sdl
build_sdl_image
build_sdl_ttf
build_sdl_mixer
build_sdl_net

# ----------------------------------------------------------------
# ldconfig
# ----------------------------------------------------------------

info "共有ライブラリのキャッシュを更新します"

echo "${PREFIX}/lib" | ${SUDO} tee /etc/ld.so.conf.d/sdl3.conf >/dev/null

${SUDO} ldconfig

ok "ldconfig完了"

# ----------------------------------------------------------------
# pkg-config確認
# ----------------------------------------------------------------

info "pkg-config のSDL3情報を確認します"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"

for pc in \
    sdl3 \
    sdl3-image \
    sdl3-ttf \
    sdl3-mixer \
    sdl3-net
do
    if pkg-config --exists "${pc}"; then
        echo
        echo "---------------------------------------------------------------"
        echo "${pc}"
        echo "---------------------------------------------------------------"
        pkg-config --modversion "${pc}"
        pkg-config --cflags "${pc}"
        pkg-config --libs "${pc}"
    else
        die "pkg-config に ${pc} が登録されていません"
    fi
done

# ----------------------------------------------------------------
# コンパイル確認
# ----------------------------------------------------------------

info "SDL3全ライブラリをまとめてリンクできるか確認します"

cat > "${WORK_ROOT}/test_sdl3.cpp" <<'EOF'
#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_mixer/SDL_mixer.h>
#include <SDL3_net/SDL_net.h>

int main()
{
    return 0;
}
EOF

cd "${WORK_ROOT}"

g++ \
    test_sdl3.cpp \
    -o test_sdl3 \
    $(pkg-config \
        --cflags \
        --libs \
        sdl3 \
        sdl3-image \
        sdl3-ttf \
        sdl3-mixer \
        sdl3-net)

ok "SDL3全ライブラリのコンパイル・リンク確認成功"

# ----------------------------------------------------------------
# インストール済みパッケージ確認
# ----------------------------------------------------------------

info "インストール済みDebianパッケージを確認します"

echo
dpkg-query \
    -W \
    -f='${binary:Package}\t${Version}\n' \
    libsdl3 \
    libsdl3-image \
    libsdl3-ttf \
    libsdl3-mixer \
    libsdl3-net

# ----------------------------------------------------------------
# 作成されたdeb確認
# ----------------------------------------------------------------

echo
echo "==============================================================="
echo "作成されたDebianパッケージ"
echo "==============================================================="

find "${WORK_ROOT}/packages" \
    -maxdepth 1 \
    -type f \
    -name '*.deb' \
    -printf '%f\n' |
    sort

# ----------------------------------------------------------------
# 完了
# ----------------------------------------------------------------

echo
echo "==============================================================="
echo "SDL3 フルセットのインストールが完了しました"
echo "==============================================================="
echo
echo "SDL3        : ${SDL_VERSION}"
echo "SDL3_image  : ${SDL_IMAGE_VERSION}"
echo "SDL3_ttf    : ${SDL_TTF_VERSION}"
echo "SDL3_mixer  : ${SDL_MIXER_VERSION}"
echo "SDL3_net    : ${SDL_NET_VERSION}"
echo
echo "作業場所:"
echo "  ${WORK_ROOT}"
echo
echo "コンパイル確認:"
echo "  ${WORK_ROOT}/test_sdl3"
echo
echo "通常のプログラムは以下でコンパイルできます:"
echo
echo '  g++ test_sdl3.cpp -o test_sdl3 $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)'
echo
echo "==============================================================="
