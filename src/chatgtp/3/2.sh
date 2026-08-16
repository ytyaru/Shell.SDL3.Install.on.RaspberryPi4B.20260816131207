#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ================================================================
# Raspberry Pi 4B / aarch64
#
# SDL3
# SDL3_image
# SDL3_ttf
# SDL3_mixer
# SDL3_net
#
# GitHub最新安定版
#   ↓
# submoduleを含めて取得
#   ↓
# CMake / Ninja
#   ↓
# checkinstall
#   ↓
# Debianパッケージとしてインストール
#   ↓
# pkg-configで全ライブラリを検証
#
# 作業場所:
#   /tmp/sdl3-build
#
# 再実行可能。
# ================================================================

set +e

WORK_ROOT="/tmp/sdl3-build"
PREFIX="/usr/local"

# Raspberry Pi 4B 4GB向け
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

set -e

# ------------------------------------------------
# 基本確認
# ------------------------------------------------

[[ "$(uname -m)" == "aarch64" ]] ||
    die "aarch64ではありません: $(uname -m)"

command -v apt-get >/dev/null ||
    die "apt-get がありません"

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
# 作業場所
# ------------------------------------------------

msg "作業場所を初期化します"

rm -rf "${WORK_ROOT}"

mkdir -p \
    "${WORK_ROOT}" \
    "${WORK_ROOT}/packages"

cd "${WORK_ROOT}"

# ------------------------------------------------
# GitHub最新安定版取得
#
# stdoutにはタグだけ。
# ------------------------------------------------

get_latest_release_tag()
{
    local repo="$1"
    local json
    local tag

    printf 'GitHubから %s の最新安定版を取得します\n' \
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

for r in json.load(sys.stdin):
    if r.get("draft"):
        continue
    if r.get("prerelease"):
        continue

    t = r.get("tag_name")

    if t:
        print(t)
        break
'
    )"

    [[ -n "${tag}" ]] ||
        die "${repo}: 最新安定版を取得できません"

    printf '%s\n' "${tag}"
}

# ------------------------------------------------
# Gitタグ確認
# ------------------------------------------------

verify_tag()
{
    local repo="$1"
    local tag="$2"

    git ls-remote \
        --exit-code \
        --refs \
        "https://github.com/${repo}.git" \
        "refs/tags/${tag}" \
        >/dev/null 2>&1 ||
        die "${repo}: ${tag} がGitHubに存在しません"
}

# ------------------------------------------------
# submodule込みclone
# ------------------------------------------------

clone_release()
{
    local repo="$1"
    local tag="$2"
    local directory="$3"

    msg "${directory} ${tag} を取得します"

    verify_tag "${repo}" "${tag}"

    git clone \
        --depth 1 \
        --branch "${tag}" \
        --single-branch \
        --recurse-submodules \
        --shallow-submodules \
        "https://github.com/${repo}.git" \
        "${directory}"

    # 念のためsubmoduleを同期・更新
    cd "${WORK_ROOT}/${directory}"

    git submodule sync --recursive

    git submodule update \
        --init \
        --recursive \
        --depth 1

    ok "${directory}: ${tag}（submodule込み）"
}

# ------------------------------------------------
# バージョン取得
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
echo "SDL3        : ${SDL_TAG}" >&2
echo "SDL3_image  : ${SDL_IMAGE_TAG}" >&2
echo "SDL3_ttf    : ${SDL_TTF_TAG}" >&2
echo "SDL3_mixer  : ${SDL_MIXER_TAG}" >&2
echo "SDL3_net    : ${SDL_NET_TAG}" >&2
echo "===============================================================" >&2

# ------------------------------------------------
# clone
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
    local v="$1"

    v="${v#release-}"
    v="${v#v}"

    printf '%s\n' "${v}"
}

SDL_VERSION="$(version_from_tag "${SDL_TAG}")"
SDL_IMAGE_VERSION="$(version_from_tag "${SDL_IMAGE_TAG}")"
SDL_TTF_VERSION="$(version_from_tag "${SDL_TTF_TAG}")"
SDL_MIXER_VERSION="$(version_from_tag "${SDL_MIXER_TAG}")"
SDL_NET_VERSION="$(version_from_tag "${SDL_NET_TAG}")"

# ------------------------------------------------
# checkinstall
# ------------------------------------------------

make_package()
{
    local package="$1"
    local version="$2"

    "${SUDO[@]}" checkinstall \
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

# ================================================================
# SDL3
# ================================================================

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
        -DSDL_SHARED=ON \
        -DSDL_STATIC=ON \
        -DSDL_INSTALL=ON \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_VULKAN=ON \
        -DSDL_OPENGL=ON \
        -DSDL_OPENGLES=ON \
        -DSDL_WAYLAND=ON \
        -DSDL_X11=ON \
        -DSDL_KMSDRM=ON \
        -DSDL_HIDAPI=ON \
        -DSDL_HIDAPI_LIBUSB=ON \
        -DSDL_LIBUDEV=ON \
        -DSDL_DBUS=ON \
        -DSDL_IBUS=ON

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

# ================================================================
# SDL3_image
# ================================================================

build_sdl_image()
{
    msg "SDL3_image ${SDL_IMAGE_VERSION} をビルドします"

    cd "${WORK_ROOT}/SDL_image"

    # submoduleが本当に存在するか確認
    [[ -f external/zlib/CMakeLists.txt ]] ||
        die "SDL_image: external/zlib がありません。submodule取得に失敗しています"

    rm -rf build

    cmake \
        -S . \
        -B build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON \
        -DSDLIMAGE_INSTALL=ON \
        -DSDLIMAGE_VENDORED=ON \
        -DSDLIMAGE_STRICT=OFF \
        -DSDLIMAGE_SAMPLES=OFF \
        -DSDLIMAGE_TESTS=OFF

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

# ================================================================
# SDL3_ttf
# ================================================================

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

# ================================================================
# SDL3_mixer
# ================================================================

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
        -DBUILD_SHARED_LIBS=ON \
        -DSDLMIXER_INSTALL=ON \
        -DSDLMIXER_VENDORED=ON \
        -DSDLMIXER_STRICT=OFF \
        -DSDLMIXER_TESTS=OFF \
        -DSDLMIXER_EXAMPLES=OFF

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

# ================================================================
# SDL3_net
# ================================================================

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

# ================================================================
# ビルド
# ================================================================

build_sdl
build_sdl_image
build_sdl_ttf
build_sdl_mixer
build_sdl_net

# ================================================================
# ldconfig
# ================================================================

msg "共有ライブラリキャッシュを更新します"

printf '%s/lib\n' "${PREFIX}" |
    "${SUDO[@]}" tee /etc/ld.so.conf.d/sdl3.conf >/dev/null

"${SUDO[@]}" ldconfig

ok "ldconfig完了"

# ================================================================
# pkg-config
# ================================================================

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"

msg "pkg-configを検証します"

for pc in \
    sdl3 \
    sdl3-image \
    sdl3-ttf \
    sdl3-mixer \
    sdl3-net
do
    pkg-config --exists "${pc}" ||
        die "pkg-config: ${pc} が見つかりません"

    printf '    %s = %s\n' \
        "${pc}" \
        "$(pkg-config --modversion "${pc}")"

    pkg-config --cflags "${pc}" >/dev/null
    pkg-config --libs "${pc}" >/dev/null
done

ok "pkg-config確認完了"

# ================================================================
# ユーザー指定のコンパイルコマンドを実行
# ================================================================

msg "SDL3全ライブラリを実際にコンパイル・リンクします"

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

ok "g++によるコンパイル・リンク成功"

./test_sdl3

ok "テストプログラム実行成功"

# ================================================================
# dpkg確認
# ================================================================

msg "インストール済みパッケージを確認します"

dpkg-query \
    -W \
    -f='${binary:Package}\t${Version}\n' \
    libsdl3 \
    libsdl3-image \
    libsdl3-ttf \
    libsdl3-mixer \
    libsdl3-net

# ================================================================
# 完了
# ================================================================

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
echo "Debianパッケージ:"
echo "  ${WORK_ROOT}/packages/"
echo
echo "コンパイル:"
echo
echo '  g++ test_sdl3.cpp -o test_sdl3 $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)'
echo
echo "==============================================================="

