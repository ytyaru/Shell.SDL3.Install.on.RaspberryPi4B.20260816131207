#!/usr/bin/env bash

# ================================================================
# Raspberry Pi 4B / 4GB / aarch64
#
# SDL3 フルセット自動インストーラー
#
# 対象:
#   SDL
#   SDL_image
#   SDL_ttf
#   SDL_mixer
#   SDL_net
#
# 特徴:
#   ・GitHub Releases の公式ソースtarballを使用
#   ・git clone / submodule は使用しない
#   ・/tmp/sdl3-build を保持する
#   ・同じバージョンは再ダウンロードしない
#   ・同じバージョンは再ビルドしない
#   ・新しいバージョンだけ更新する
#   ・checkinstallでDebianパッケージ化
#   ・dpkgでインストール
#   ・pkg-configを検証
#   ・最終的にSDL3全ライブラリを実際にリンクして検証
#
# 作業場所:
#   /tmp/sdl3-build
#
# 推奨実行:
#   chmod +x install-sdl3.sh
#   ./install-sdl3.sh
#
# 並列ビルド数:
#   デフォルト2
#
# 変更する場合:
#   BUILD_JOBS=1 ./install-sdl3.sh
#
# ================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------------------------
# 設定
# ------------------------------------------------

WORK_ROOT="/tmp/sdl3-build"
SOURCE_DIR="${WORK_ROOT}/sources"
BUILD_DIR="${WORK_ROOT}/build"
PACKAGE_DIR="${WORK_ROOT}/packages"
STATE_DIR="${WORK_ROOT}/state"

PREFIX="/usr/local"

# Raspberry Pi 4B 4GBでは2程度を推奨
BUILD_JOBS="${BUILD_JOBS:-2}"

# ------------------------------------------------
# sudo
# ------------------------------------------------

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

# ------------------------------------------------
# エラー処理
# ------------------------------------------------

エラー処理()
{
    echo
    echo "[ERROR] スクリプトが異常終了しました。" >&2
    echo "[ERROR] 行番号: ${BASH_LINENO[0]}" >&2
    echo "[ERROR] コマンド: ${BASH_COMMAND}" >&2
}

trap エラー処理 ERR

# ------------------------------------------------
# メッセージ
# ------------------------------------------------

情報()
{
    echo
    echo "==> $*"
}

成功()
{
    echo "    [OK] $*"
}

失敗()
{
    echo
    echo "[ERROR] $*" >&2
    exit 1
}

# ------------------------------------------------
# 基本確認
# ------------------------------------------------

[[ "$(uname -m)" == "aarch64" ]] ||
    失敗 "aarch64ではありません: $(uname -m)"

command -v apt-get >/dev/null ||
    失敗 "apt-get がありません"

command -v curl >/dev/null ||
    失敗 "curl がありません"

command -v python3 >/dev/null ||
    失敗 "python3 がありません"

command -v git >/dev/null ||
    失敗 "git がありません"

# ------------------------------------------------
# 作業ディレクトリ
#
# 絶対に削除しない。
# ------------------------------------------------

mkdir -p \
    "${WORK_ROOT}" \
    "${SOURCE_DIR}" \
    "${BUILD_DIR}" \
    "${PACKAGE_DIR}" \
    "${STATE_DIR}"

# ================================================================
# 必要パッケージ
# ================================================================

情報 "必要なパッケージを確認します"

"${SUDO[@]}" apt-get update

"${SUDO[@]}" apt-get install -y \
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    ninja-build \
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

成功 "必要パッケージ"

# ================================================================
# GitHub API
# ================================================================

最新安定版()
{
    local repo="$1"

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
        "https://api.github.com/repos/${repo}/releases?per_page=100" |
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
}

# ================================================================
# バージョン文字列
# ================================================================

バージョン番号()
{
    local tag="$1"

    tag="${tag#release-}"
    tag="${tag#v}"

    echo "${tag}"
}

# ================================================================
# 公式tarball URL
#
# GitHub Releaseのタグ形式に依存する。
# SDL系は release-X.Y.Z。
# ================================================================

tarball名()
{
    local project="$1"
    local version="$2"

    case "${project}" in

        SDL)
            echo "SDL-${version}.tar.gz"
            ;;

        SDL_image)
            echo "SDL3_image-${version}.tar.gz"
            ;;

        SDL_ttf)
            echo "SDL3_ttf-${version}.tar.gz"
            ;;

        SDL_mixer)
            echo "SDL3_mixer-${version}.tar.gz"
            ;;

        SDL_net)
            echo "SDL3_net-${version}.tar.gz"
            ;;

        *)
            失敗 "未知のプロジェクト: ${project}"
            ;;
    esac
}

tarballURL()
{
    local project="$1"
    local tag="$2"
    local version="$3"

    local file

    file="$(tarball名 "${project}" "${version}")"

    case "${project}" in

        SDL)
            echo "https://github.com/libsdl-org/SDL/releases/download/${tag}/${file}"
            ;;

        SDL_image)
            echo "https://github.com/libsdl-org/SDL_image/releases/download/${tag}/${file}"
            ;;

        SDL_ttf)
            echo "https://github.com/libsdl-org/SDL_ttf/releases/download/${tag}/${file}"
            ;;

        SDL_mixer)
            echo "https://github.com/libsdl-org/SDL_mixer/releases/download/${tag}/${file}"
            ;;

        SDL_net)
            echo "https://github.com/libsdl-org/SDL_net/releases/download/${tag}/${file}"
            ;;

        *)
            失敗 "未知のプロジェクト: ${project}"
            ;;
    esac
}

# ================================================================
# ソース取得
#
# 既存tarballがあれば再取得しない。
# ================================================================

ソース取得()
{
    local project="$1"
    local tag="$2"
    local version="$3"

    local file
    local url
    local archive

    file="$(tarball名 "${project}" "${version}")"
    archive="${SOURCE_DIR}/${file}"
    url="$(tarballURL "${project}" "${tag}" "${version}")"

    if [[ -f "${archive}" ]]; then
        echo "    既存ソースを使用: ${file}"
        return
    fi

    echo "    ダウンロード: ${file}"
    echo "    URL: ${url}"

    curl \
        --fail \
        --location \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 1800 \
        --progress-bar \
        -o "${archive}.tmp" \
        "${url}"

    mv "${archive}.tmp" "${archive}"

   成功 "ダウンロード: ${file}"
}

# ================================================================
# ソース展開
#
# 既に展開済みなら何もしない。
# ================================================================

ソース展開()
{
    local project="$1"
    local version="$2"

    local file
    local archive
    local target
    local marker

    file="$(tarball名 "${project}" "${version}")"
    archive="${SOURCE_DIR}/${file}"

    target="${SOURCE_DIR}/${project}-${version}"
    marker="${target}/.sdl3-source-ready"

    if [[ -f "${marker}" ]]; then
        echo "    既存ソースを使用: ${target}"
        return
    fi

    if [[ -d "${target}" ]]; then
        echo "    不完全なソースを削除: ${target}"
        rm -rf "${target}"
    fi

    echo "    展開: ${file}"

    mkdir -p "${SOURCE_DIR}/extract"

    rm -rf "${SOURCE_DIR}/extract/"*

    tar \
        -xzf "${archive}" \
        -C "${SOURCE_DIR}/extract"

    local extracted

    extracted="$(
        find "${SOURCE_DIR}/extract" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -print \
            | head -n 1
    )"

    [[ -n "${extracted}" ]] ||
        失敗 "${project}: ソース展開先を確認できません"

    mv "${extracted}" "${target}"

    touch "${marker}"

    rm -rf "${SOURCE_DIR}/extract"

   成功 "ソース展開: ${target}"
}

# ================================================================
# ビルド状態
# ================================================================

ビルド済み()
{
    local project="$1"
    local version="$2"

    [[ -f "${STATE_DIR}/${project}-${version}.built" ]]
}

インストール済み()
{
    local package="$1"
    local version="$2"

    dpkg-query \
        -W \
        -f='${Status} ${Version}\n' \
        "${package}" 2>/dev/null |
    grep -q "^install ok installed ${version}$"
}

# ================================================================
# CMakeビルド
# ================================================================

CMakeビルド()
{
    local project="$1"
    local version="$2"
    local source="$3"
    local build="$4"

    rm -rf "${build}"

    mkdir -p "${build}"

    case "${project}" in

        SDL)

            cmake \
                -S "${source}" \
                -B "${build}" \
                -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DSDL_SHARED=ON \
                -DSDL_STATIC=ON \
                -DSDL_INSTALL=ON \
                -DSDL_TESTS=OFF \
                -DSDL_EXAMPLES=OFF \
                -DSDL_TEST_LIBRARY=OFF

            ;;

        SDL_image)

            cmake \
                -S "${source}" \
                -B "${build}" \
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

            ;;

        SDL_ttf)

            cmake \
                -S "${source}" \
                -B "${build}" \
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

            ;;

        SDL_mixer)

            cmake \
                -S "${source}" \
                -B "${build}" \
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

            ;;

        SDL_net)

            cmake \
                -S "${source}" \
                -B "${build}" \
                -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DBUILD_SHARED_LIBS=ON \
                -DSDLNET_INSTALL=ON \
                -DSDLNET_TESTS=OFF \
                -DSDLNET_EXAMPLES=OFF

            ;;

        *)
            失敗 "未知のプロジェクト: ${project}"
            ;;
    esac

    cmake \
        --build "${build}" \
        --parallel "${BUILD_JOBS}"

    touch "${STATE_DIR}/${project}-${version}.built"

   成功 "${project} ${version} ビルド完了"
}

# ================================================================
# checkinstall
# ================================================================

パッケージ化()
{
    local project="$1"
    local version="$2"
    local package="$3"
    local build="$4"

    local deb

    deb="${PACKAGE_DIR}/${package}_${version}-1_arm64.deb"

    if [[ -f "${deb}" ]] && インストール済み "${package}" "${version}"; then
        echo "    既存パッケージを使用: ${deb}"
        return
    fi

    if インストール済み "${package}" "${version}"; then
        echo "    既にインストール済み: ${package} ${version}"
        return
    fi

    info="SDL3 ${project} ${version}"

    "${SUDO[@]}" checkinstall \
        --default \
        --install=yes \
        --fstrans=no \
        --backup=no \
        --pakdir="${PACKAGE_DIR}" \
        --pkgname="${package}" \
        --pkgversion="${version}" \
        --pkgrelease="1" \
        --pkgarch="arm64" \
        --maintainer="local" \
        --nodoc \
        --deldoc=yes \
        --strip=yes \
        --stripso=yes \
        cmake --install "${build}" --prefix "${PREFIX}"

    success_marker="${STATE_DIR}/${project}-${version}.installed"

    touch "${success_marker}"

   成功 "${package} ${version} インストール完了"
}

# ================================================================
# 各SDLライブラリ
# ================================================================

処理()
{
    local project="$1"
    local repo="$2"
    local package="$3"

    local tag
    local version
    local source
    local build

    echo
    echo "==============================================================="
    echo "${project}"
    echo "==============================================================="

    echo "最新安定版を確認しています..."

    tag="$(最新安定版 "${repo}")"

    [[ -n "${tag}" ]] ||
        失敗 "${project}: 最新安定版を取得できません"

    version="$(バージョン番号 "${tag}")"

    source="${SOURCE_DIR}/${project}-${version}"
    build="${BUILD_DIR}/${project}-${version}"

    echo "バージョン: ${version}"

    # ------------------------------------------------
    # 既にインストール済みなら終了
    # ------------------------------------------------

    if インストール済み "${package}" "${version}"; then
        成功 "${project} ${version} は既にインストール済み"
        return
    fi

    # ------------------------------------------------
    # ダウンロード
    # ------------------------------------------------

    ソース取得 \
        "${project}" \
        "${tag}" \
        "${version}"

    # ------------------------------------------------
    # 展開
    # ------------------------------------------------

    ソース展開 \
        "${project}" \
        "${version}"

    # ------------------------------------------------
    # ビルド
    # ------------------------------------------------

    if ビルド済み "${project}" "${version}"; then
        echo "    既存ビルドを使用"
    else
        CMakeビルド \
            "${project}" \
            "${version}" \
            "${source}" \
            "${build}"
    fi

    # ------------------------------------------------
    # パッケージ化・インストール
    # ------------------------------------------------

    パッケージ化 \
        "${project}" \
        "${version}" \
        "${package}" \
        "${build}"
}

# ================================================================
# 最新版確認
# ================================================================

情報 "SDL3関連の最新安定版を確認します"

SDL_TAG="$(最新安定版 "libsdl-org/SDL")"
SDL_IMAGE_TAG="$(最新安定版 "libsdl-org/SDL_image")"
SDL_TTF_TAG="$(最新安定版 "libsdl-org/SDL_ttf")"
SDL_MIXER_TAG="$(最新安定版 "libsdl-org/SDL_mixer")"
SDL_NET_TAG="$(最新安定版 "libsdl-org/SDL_net")"

SDL_VERSION="$(バージョン番号 "${SDL_TAG}")"
SDL_IMAGE_VERSION="$(バージョン番号 "${SDL_IMAGE_TAG}")"
SDL_TTF_VERSION="$(バージョン番号 "${SDL_TTF_TAG}")"
SDL_MIXER_VERSION="$(バージョン番号 "${SDL_MIXER_TAG}")"
SDL_NET_VERSION="$(バージョン番号 "${SDL_NET_TAG}")"

echo
echo "==============================================================="
echo "取得対象"
echo "==============================================================="
echo "SDL3        : ${SDL_VERSION}"
echo "SDL3_image  : ${SDL_IMAGE_VERSION}"
echo "SDL3_ttf    : ${SDL_TTF_VERSION}"
echo "SDL3_mixer  : ${SDL_MIXER_VERSION}"
echo "SDL3_net    : ${SDL_NET_VERSION}"
echo "==============================================================="

# ================================================================
# SDL3
# ================================================================

処理 \
    "SDL" \
    "libsdl-org/SDL" \
    "libsdl3"

# ================================================================
# SDL3_image
# ================================================================

処理 \
    "SDL_image" \
    "libsdl-org/SDL_image" \
    "libsdl3-image"

# ================================================================
# SDL3_ttf
# ================================================================

処理 \
    "SDL_ttf" \
    "libsdl-org/SDL_ttf" \
    "libsdl3-ttf"

# ================================================================
# SDL3_mixer
# ================================================================

処理 \
    "SDL_mixer" \
    "libsdl-org/SDL_mixer" \
    "libsdl3-mixer"

# ================================================================
# SDL3_net
# ================================================================

処理 \
    "SDL_net" \
    "libsdl-org/SDL_net" \
    "libsdl3-net"

# ================================================================
# ldconfig
# ================================================================

情報 "共有ライブラリキャッシュを更新します"

echo "${PREFIX}/lib" |
    "${SUDO[@]}" tee /etc/ld.so.conf.d/sdl3.conf >/dev/null

"${SUDO[@]}" ldconfig

成功 "ldconfig"

# ================================================================
# pkg-config
# ================================================================

情報 "pkg-configを確認します"

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"

for pc in \
    sdl3 \
    sdl3-image \
    sdl3-ttf \
    sdl3-mixer \
    sdl3-net
do

    pkg-config --exists "${pc}" ||
        失敗 "pkg-configに ${pc} がありません"

    echo "    ${pc}: $(pkg-config --modversion "${pc}")"

    pkg-config --cflags "${pc}" >/dev/null
    pkg-config --libs "${pc}" >/dev/null

done

成功 "pkg-config"

# ================================================================
# 実際のコンパイル・リンク検証
# ================================================================

情報 "全SDL3ライブラリのコンパイル・リンクを検証します"

TEST_CPP="${WORK_ROOT}/test_sdl3.cpp"
TEST_BIN="${WORK_ROOT}/test_sdl3"

cat > "${TEST_CPP}" <<'EOF'
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

成功 "g++コンパイル・リンク"

"${TEST_BIN}"

成功 "テストプログラム実行"

# ================================================================
# dpkg確認
# ================================================================

情報 "dpkg登録状態を確認します"

dpkg-query \
    -W \
    -f='${binary:Package}\t${Version}\t${Status}\n' \
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
echo "ソース:"
echo "  ${SOURCE_DIR}"
echo
echo "ビルド:"
echo "  ${BUILD_DIR}"
echo
echo "Debianパッケージ:"
echo "  ${PACKAGE_DIR}"
echo
echo "次回実行時:"
echo "  同じバージョンならダウンロード・ビルドをスキップします"
echo "  新版が出たライブラリだけ更新します"
echo
echo "コンパイル確認:"
echo
echo '  g++ test_sdl3.cpp -o test_sdl3 $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)'
echo
echo "==============================================================="
