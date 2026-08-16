#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ================================================================
# Raspberry Pi 4B / Raspberry Pi OS (aarch64)
#
# SDL3
# SDL3_image
# SDL3_ttf
# SDL3_mixer
# SDL3_net
#
# GitHub の最新安定版 Release を自動取得
# ↓
# CMake / Ninja でビルド
# ↓
# checkinstall で Debian パッケージ化
# ↓
# dpkg に登録
# ↓
# pkg-config を検証
#
# 作業場所:
#   /tmp/sdl3-build
#
# 再実行するだけで、その時点の最新安定版を取得する。
#
# ================================================================

WORK_ROOT="/tmp/sdl3-build"
PREFIX="/usr/local"
BUILD_JOBS="${BUILD_JOBS:-2}"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------
# sudo
# ------------------------------------------------

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

# ------------------------------------------------
# メッセージ
# ------------------------------------------------

msg()
{
    printf '\n==> %s\n' "$*" >&2
}

ok()
{
    printf '    [OK] %s\n' "$*" >&2
}

die()
{
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

trap '
    echo >&2
    echo "[ERROR] スクリプトが異常終了しました。" >&2
    echo "[ERROR] 行番号: ${LINENO}" >&2
    echo "[ERROR] コマンド: ${BASH_COMMAND}" >&2
' ERR

# ------------------------------------------------
# 基本確認
# ------------------------------------------------

[[ "$(uname -m)" == "aarch64" ]] ||
    die "aarch64ではありません: $(uname -m)"

command -v apt-get >/dev/null ||
    die "apt-get がありません"

command -v curl >/dev/null ||
    die "curl がありません"

command -v python3 >/dev/null ||
    die "python3 がありません"

# ------------------------------------------------
# 必要パッケージ
# ------------------------------------------------

msg "必要なパッケージをインストールします"

"${SUDO[@]}" apt-get update

"${SUDO[@]}" apt-get install -y \
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    ninja-build \
    git \
    curl \
    ca-certificates \
    python3 \
    pkg-config \
    checkinstall \
    fakeroot \
    dpkg-dev \
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
    liburing-dev \
    \
    libunwind-dev

ok "必要パッケージのインストール完了"

# ------------------------------------------------
# 作業ディレクトリ
# ------------------------------------------------

msg "作業ディレクトリを初期化します"

rm -rf "${WORK_ROOT}"

mkdir -p \
    "${WORK_ROOT}" \
    "${WORK_ROOT}/packages"

cd "${WORK_ROOT}"

ok "${WORK_ROOT}"

# ------------------------------------------------
# GitHub Releases API
#
# stdoutにはタグだけを出す。
# メッセージはstderrへ出す。
#
# これが前回のバグを防ぐ。
# ------------------------------------------------

get_latest_release_tag()
{
    local repo="$1"
    local json
    local tag

    printf '==> GitHubから %s の最新安定版を取得します\n' \
        "${repo}" >&2

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
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "https://api.github.com/repos/${repo}/releases?per_page=100"
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

    [[ -n "${tag}" ]] ||
        die "${repo}: 安定版Releaseが取得できません"

    # stdoutにはタグだけ
    printf '%s\n' "${tag}"
}

# ------------------------------------------------
# Gitタグ実在確認
# ------------------------------------------------

verify_git_tag()
{
    local repo="$1"
    local tag="$2"

    printf '    Gitタグを確認: %s\n' "${tag}" >&2

    git ls-remote \
        --exit-code \
        --refs \
        "https://github.com/${repo}.git" \
        "refs/tags/${tag}" \
        >/dev/null 2>&1 ||
        die "${repo}: Gitタグ ${tag} が存在しません"

    ok "${repo}: ${tag}"
}

# ------------------------------------------------
# ソース取得
# ------------------------------------------------

clone_release()
{
    local repo="$1"
    local tag="$2"
    local directory="$3"

    msg "${directory} ${tag} を取得します"

    verify_git_tag "${repo}" "${tag}"

    git clone \
        --depth 1 \
        --branch "${tag}" \
        --single-branch \
        "https://github.com/${repo}.git" \
        "${directory}"

    ok "${directory}: ${tag}"
}

# ------------------------------------------------
# 最新バージョン取得
# ------------------------------------------------

SDL_TAG="$(get_latest_release_tag "libsdl-org/SDL")"
SDL_IMAGE_TAG="$(get_latest_release_tag "libsdl-org/SDL_image")"
SDL_TTF_TAG="$(get_latest_release_tag "libsdl-org/SDL_ttf")"
SDL_MIXER_TAG="$(get_latest_release_tag "libsdl-org/SDL_mixer")"
SDL_NET_TAG="$(get_latest_release_tag "libsdl-org/SDL_net")"

echo >&2
echo "===============================================================" >&2
echo "取得するSDL3関連バージョン" >&2
echo "===============================================================" >&2
printf 'SDL3        : %s\n' "${SDL_TAG}" >&2
printf 'SDL3_image  : %s\n' "${SDL_IMAGE_TAG}" >&2
printf 'SDL3_ttf    : %s\n' "${SDL_TTF_TAG}" >&2
printf 'SDL3_mixer  : %s\n' "${SDL_MIXER_TAG}" >&2
printf 'SDL3_net    : %s\n' "${SDL_NET_TAG}" >&2
echo "===============================================================" >&2

# ------------------------------------------------
# ソース取得
# ------------------------------------------------

clone_release \
    "libsdl-org/SDL" \
    "${SDL_TAG}" \
    "SDL"

clone_release \
    "libsdl-org/SDL_image" \
    "${SDL_IMAGE_TAG}" \
    "SDL_image"

clone_release \
    "libsdl-org/SDL_ttf" \
    "${SDL_TTF_TAG}" \
    "SDL_ttf"

clone_release \
    "libsdl-org/SDL_mixer" \
    "${SDL_MIXER_TAG}" \
    "SDL_mixer"

clone_release \
    "libsdl-org/SDL_net" \
    "${SDL_NET_TAG}" \
    "SDL_net"

# ------------------------------------------------
# バージョン番号
# ------------------------------------------------

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

# ------------------------------------------------
# checkinstall共通処理
# ------------------------------------------------

checkinstall_package()
{
    local package="$1"
    local version="$2"

    checkinstall \
        --default \
        --install=yes \
        --fstrans=no \
        --backup=no \
        --pakdir="${WORK_ROOT}/packages" \
        --pkgname="${package}" \
        --pkgversion="${version}" \
        --pkgrelease="1" \
        --pkgarch="arm64" \
        --maintainer="local" \
        --nodoc \
        --deldoc=yes \
        --strip=yes \
        --stripso=yes \
        "$@"
}

# ------------------------------------------------
# SDL3
# ------------------------------------------------

build_sdl()
{
    msg "SDL3 ${SDL_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF \
        \
        -DSDL_INSTALL=ON \
        -DSDL_INSTALL_DOCS=OFF \
        \
        -DSDL_AUDIO=ON \
        -DSDL_VIDEO=ON \
        -DSDL_GPU=ON \
        -DSDL_RENDER=ON \
        -DSDL_CAMERA=ON \
        -DSDL_JOYSTICK=ON \
        -DSDL_HAPTIC=ON \
        -DSDL_HIDAPI=ON \
        -DSDL_POWER=ON \
        -DSDL_SENSOR=ON \
        -DSDL_DIALOG=ON \
        -DSDL_TRAY=ON \
        -DSDL_NOTIFICATION=ON \
        \
        -DSDL_DBUS=ON \
        -DSDL_LIBURING=ON \
        -DSDL_IBUS=ON \
        -DSDL_LIBUDEV=ON \
        \
        -DSDL_OPENGL=ON \
        -DSDL_OPENGLES=ON \
        -DSDL_VULKAN=ON \
        \
        -DSDL_X11=ON \
        -DSDL_X11_XCURSOR=ON \
        -DSDL_X11_XDBE=ON \
        -DSDL_X11_XINPUT=ON \
        -DSDL_X11_XFIXES=ON \
        -DSDL_X11_XRANDR=ON \
        -DSDL_X11_XSCRNSAVER=ON \
        -DSDL_X11_XSHAPE=ON \
        -DSDL_X11_XSYNC=ON \
        -DSDL_X11_XTEST=ON \
        \
        -DSDL_WAYLAND=ON \
        -DSDL_WAYLAND_LIBDECOR=ON \
        \
        -DSDL_KMSDRM=ON \
        -DSDL_RPI=ON \
        \
        -DSDL_HIDAPI_LIBUSB=ON \
        -DSDL_HIDAPI_JOYSTICK=ON \
        \
        -DSDL_PTHREADS=ON \
        -DSDL_FRIBIDI=ON \
        -DSDL_LIBTHAI=ON

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    "${SUDO[@]}" checkinstall \
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
        --strip=yes \
        --stripso=yes \
        cmake --install . --prefix "${PREFIX}"

    ok "SDL3 インストール完了"
}

# ------------------------------------------------
# SDL3_image
# ------------------------------------------------

build_sdl_image()
{
    msg "SDL3_image ${SDL_IMAGE_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_image"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        \
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

    "${SUDO[@]}" checkinstall \
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

    ok "SDL3_image インストール完了"
}

# ------------------------------------------------
# SDL3_ttf
# ------------------------------------------------

build_sdl_ttf()
{
    msg "SDL3_ttf ${SDL_TTF_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_ttf"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        \
        -DBUILD_SHARED_LIBS=ON \
        -DSDLTTF_INSTALL=ON \
        -DSDLTTF_VENDORED=ON \
        -DSDLTTF_STRICT=OFF \
        -DSDLTTF_SAMPLES=OFF \
        -DSDLTTF_TESTS=OFF

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    "${SUDO[@]}" checkinstall \
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

    ok "SDL3_ttf インストール完了"
}

# ------------------------------------------------
# SDL3_mixer
# ------------------------------------------------

build_sdl_mixer()
{
    msg "SDL3_mixer ${SDL_MIXER_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_mixer"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        \
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
        -DSDLMIXER_MIDI=ON

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    "${SUDO[@]}" checkinstall \
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

    ok "SDL3_mixer インストール完了"
}

# ------------------------------------------------
# SDL3_net
# ------------------------------------------------

build_sdl_net()
{
    msg "SDL3_net ${SDL_NET_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_net"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        \
        -DBUILD_SHARED_LIBS=ON \
        -DSDLNET_INSTALL=ON \
        -DSDLNET_TESTS=OFF \
        -DSDLNET_EXAMPLES=OFF

    cmake \
        --build build \
        --parallel "${BUILD_JOBS}"

    cd build

    "${SUDO[@]}" checkinstall \
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

    ok "SDL3_net インストール完了"
}

# ------------------------------------------------
# ビルド実行
# ------------------------------------------------

build_sdl
build_sdl_image
build_sdl_ttf
build_sdl_mixer
build_sdl_net

# ------------------------------------------------
# ldconfig
# ------------------------------------------------

msg "共有ライブラリのキャッシュを更新します"

printf '%s/lib\n' "${PREFIX}" |
    "${SUDO[@]}" tee /etc/ld.so.conf.d/sdl3.conf >/dev/null

"${SUDO[@]}" ldconfig

ok "ldconfig 完了"

# ------------------------------------------------
# pkg-config パス
#
# /usr/local/lib/pkgconfig を標準探索対象にする。
# ------------------------------------------------

PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_PATH

# ------------------------------------------------
# pkg-config確認
# ------------------------------------------------

msg "pkg-config を確認します"

for pc in \
    sdl3 \
    sdl3-image \
    sdl3-ttf \
    sdl3-mixer \
    sdl3-net
do
    if ! pkg-config --exists "${pc}"; then
        die "pkg-config に ${pc} が登録されていません"
    fi

    printf '    %-14s %s\n' \
        "${pc}" \
        "$(pkg-config --modversion "${pc}")"

    pkg-config --cflags "${pc}" >/dev/null
    pkg-config --libs "${pc}" >/dev/null

    ok "${pc}"
done

# ------------------------------------------------
# 実際にユーザー指定のコマンドを検証
# ------------------------------------------------

msg "SDL3全ライブラリのコンパイル・リンクを検証します"

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

ok "指定されたg++コマンドによるリンク成功"

# ------------------------------------------------
# 実行
# ------------------------------------------------

"${WORK_ROOT}/test_sdl3"

ok "生成したテストプログラムの実行成功"

# ------------------------------------------------
# dpkg確認
# ------------------------------------------------

msg "Debianパッケージを確認します"

for package in \
    libsdl3 \
    libsdl3-image \
    libsdl3-ttf \
    libsdl3-mixer \
    libsdl3-net
do
    dpkg-query \
        -W \
        -f='${binary:Package}\t${Version}\n' \
        "${package}"
done

# ------------------------------------------------
# 作成されたdeb
# ------------------------------------------------

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

# ------------------------------------------------
# 最終結果
# ------------------------------------------------

echo
echo "==============================================================="
echo "SDL3 フルセットのインストールが完了しました"
echo "==============================================================="
echo
printf 'SDL3        : %s\n' "${SDL_VERSION}"
printf 'SDL3_image  : %s\n' "${SDL_IMAGE_VERSION}"
printf 'SDL3_ttf    : %s\n' "${SDL_TTF_VERSION}"
printf 'SDL3_mixer  : %s\n' "${SDL_MIXER_VERSION}"
printf 'SDL3_net    : %s\n' "${SDL_NET_VERSION}"
echo
echo "作業場所:"
echo "  ${WORK_ROOT}"
echo
echo "Debianパッケージ:"
echo "  ${WORK_ROOT}/packages/"
echo
echo "コンパイル:"
echo '  g++ test_sdl3.cpp -o test_sdl3 $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)'
echo
echo "==============================================================="

