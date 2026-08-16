#!/usr/bin/env bash
#
# Raspberry Pi 4B / Debian系 Linux 用
#
# SDL3 本体と以下の公式 SDL3 拡張ライブラリを
# GitHub の最新 stable release から取得してビルドし、
# checkinstall で Debian パッケージ化してインストールする。
#
# 対象:
#   SDL
#   SDL_image
#   SDL_ttf
#   SDL_mixer
#   SDL_net
#
# 特徴:
#   ・GitHub Releases API から最新版を自動取得
#   ・バージョン番号をスクリプトに固定しない
#   ・aarch64 / ARM64 を確認
#   ・必要なビルド依存関係を apt で導入
#   ・SDL3 本体を最初にビルド
#   ・SDL3 拡張ライブラリを依存順にビルド
#   ・checkinstall により dpkg/apt 管理可能なパッケージを生成
#   ・/usr 配下へインストール
#   ・既存バージョンは dpkg によって更新される
#   ・再実行可能
#
# 実行:
#   chmod +x install-sdl3.sh
#   sudo ./install-sdl3.sh
#

set -Eeuo pipefail

###############################################################################
# 設定
###############################################################################

readonly WORK_ROOT="/usr/local/src/sdl3-build"
readonly PACKAGE_DIR="${WORK_ROOT}/packages"

# Raspberry Pi 4B 4GB なので過剰な並列ビルドを避ける。
# 必要なら:
#   JOBS=1 sudo ./install-sdl3.sh
# のように変更可能。
readonly JOBS="${JOBS:-2}"

readonly GITHUB_API="https://api.github.com/repos"

readonly SDL_REPO="libsdl-org/SDL"
readonly SDL_IMAGE_REPO="libsdl-org/SDL_image"
readonly SDL_TTF_REPO="libsdl-org/SDL_ttf"
readonly SDL_MIXER_REPO="libsdl-org/SDL_mixer"
readonly SDL_NET_REPO="libsdl-org/SDL_net"

###############################################################################
# 表示
###############################################################################

info()
{
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

die()
{
    echo
    echo "エラー: $*" >&2
    exit 1
}

###############################################################################
# 終了時処理
###############################################################################

cleanup_on_error()
{
    echo
    echo "エラーが発生したため処理を中止しました。"
    echo "作業ディレクトリ:"
    echo "  ${WORK_ROOT}"
}

trap cleanup_on_error ERR

###############################################################################
# root確認
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    die "このスクリプトは sudo または root で実行してください。"
fi

###############################################################################
# CPU確認
###############################################################################

info "CPUアーキテクチャを確認"

ARCH="$(dpkg --print-architecture)"

echo "dpkg architecture: ${ARCH}"
echo "uname -m:           $(uname -m)"

if [[ "${ARCH}" != "arm64" ]]; then
    die "このスクリプトは Raspberry Pi の ARM64 / aarch64 環境を対象としています。"
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
    die "uname -m が aarch64 ではありません。"
fi

###############################################################################
# OS確認
###############################################################################

info "OSを確認"

if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-release が存在しません。"
fi

source /etc/os-release

echo "OS:       ${PRETTY_NAME:-不明}"
echo "VERSION:  ${VERSION_ID:-不明}"

###############################################################################
# 必須コマンド
###############################################################################

info "基本ツールをインストール"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    git \
    jq \
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    checkinstall \
    dpkg-dev \
    devscripts \
    file \
    gettext \
    python3 \
    perl

###############################################################################
# SDL3 本体用依存関係
#
# SDL公式 README-linux.md に記載されている Linux の開発依存関係を
# Raspberry Pi / Debian で利用可能なものを中心に導入する。
###############################################################################

info "SDL3 本体のビルド依存関係をインストール"

apt-get install -y \
    libasound2-dev \
    libpulse-dev \
    libaudio-dev \
    libfribidi-dev \
    libjack-dev \
    libsndio-dev \
    libx11-dev \
    libxext-dev \
    libxrandr-dev \
    libxcursor-dev \
    libxfixes-dev \
    libxi-dev \
    libxss-dev \
    libxtst-dev \
    libxkbcommon-dev \
    libdrm-dev \
    libgbm-dev \
    libgl1-mesa-dev \
    libgles2-mesa-dev \
    libegl1-mesa-dev \
    libdbus-1-dev \
    libibus-1.0-dev \
    libudev-dev \
    libthai-dev \
    libusb-1.0-0-dev \
    libwayland-dev \
    wayland-protocols \
    libdecor-0-dev \
    libpipewire-0.3-dev \
    liburing-dev

###############################################################################
# SDL_image 用依存関係
#
# 可能な画像形式をできるだけ有効にする。
###############################################################################

info "SDL3_image のビルド依存関係をインストール"

apt-get install -y \
    zlib1g-dev \
    libpng-dev \
    libjpeg-dev \
    libtiff-dev \
    libwebp-dev \
    libavif-dev \
    libjxl-dev \
    libheif-dev \
    libxml2-dev \
    liblzma-dev \
    libbz2-dev

###############################################################################
# SDL_ttf 用依存関係
###############################################################################

info "SDL3_ttf のビルド依存関係をインストール"

apt-get install -y \
    libfreetype6-dev \
    libharfbuzz-dev \
    libbrotli-dev

###############################################################################
# SDL_mixer 用依存関係
#
# SDL_mixer 3 は複数の音声形式・MIDI・MOD系バックエンドを持つため、
# Debian側で利用可能な開発ライブラリをまとめて導入する。
###############################################################################

info "SDL3_mixer のビルド依存関係をインストール"

apt-get install -y \
    libflac-dev \
    libmpg123-dev \
    libopus-dev \
    libopusfile-dev \
    libogg-dev \
    libvorbis-dev \
    libvorbisfile3 \
    libvorbisidec-dev \
    libfluidsynth-dev \
    libgme-dev \
    libxmp-dev \
    libwavpack-dev \
    libmodplug-dev

###############################################################################
# SDL_net 用
###############################################################################

info "SDL3_net のビルド依存関係を確認"

apt-get install -y \
    zlib1g-dev

###############################################################################
# 作業ディレクトリ
###############################################################################

info "作業ディレクトリを準備"

mkdir -p "${WORK_ROOT}"
mkdir -p "${PACKAGE_DIR}"

cd "${WORK_ROOT}"

###############################################################################
# GitHub APIから最新stable releaseを取得
###############################################################################

get_latest_release_tag()
{
    local repo="$1"
    local tag

    echo "GitHubから最新版を確認: ${repo}" >&2

    tag="$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --retry 5 \
            --retry-delay 2 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "${GITHUB_API}/${repo}/releases/latest" |
        jq -r '.tag_name'
    )"

    if [[ -z "${tag}" || "${tag}" == "null" ]]; then
        die "GitHubからrelease tagを取得できませんでした: ${repo}"
    fi

    printf '%s\n' "${tag}"
}

###############################################################################
# GitHub tagからパッケージ用バージョンを作る
#
# 例:
#   release-3.4.14 -> 3.4.14
#   release-4.7.2  -> 4.7.2
###############################################################################

package_version_from_tag()
{
    local tag="$1"
    local version="${tag#release-}"

    # Debianパッケージのバージョンとして扱えない文字を検査。
    if ! dpkg --compare-versions "${version}" ge "0"; then
        die "不正なパッケージバージョンです: ${version}"
    fi

    printf '%s\n' "${version}"
}

###############################################################################
# GitHubからソースを取得
###############################################################################

clone_release()
{
    local repo="$1"
    local tag="$2"
    local name="$3"
    local dest="${WORK_ROOT}/${name}-${tag}"

    if [[ -d "${dest}/.git" ]]; then
        echo "既存のソースを使用: ${dest}"

        cd "${dest}"

        git fetch \
            --depth 1 \
            origin \
            "refs/tags/${tag}:refs/tags/${tag}"

        git checkout --force "${tag}"

        cd "${WORK_ROOT}"
    else
        echo "GitHubから取得: ${repo} ${tag}"

        git clone \
            --depth 1 \
            --branch "${tag}" \
            "https://github.com/${repo}.git" \
            "${dest}"
    fi

    printf '%s\n' "${dest}"
}

###############################################################################
# checkinstallでCMake installをパッケージ化
###############################################################################

checkinstall_cmake_install()
{
    local package_name="$1"
    local package_version="$2"
    local package_summary="$3"
    local build_dir="$4"
    local requires="${5:-}"

    cd "${build_dir}"

    local -a args

    args=(
        --type=debian
        --install=yes
        --fstrans=no
        --backup=no
        --deldoc=yes
        --nodoc
        --pakdir="${PACKAGE_DIR}"
        --pkgname="${package_name}"
        --pkgversion="${package_version}"
        --pkgrelease=1
        --pkglicense="Zlib"
        --maintainer="local"
        --summary="${package_summary}"
    )

    if [[ -n "${requires}" ]]; then
        args+=(--requires="${requires}")
    fi

    echo "checkinstallでパッケージ化・インストール:"
    echo "  ${package_name} ${package_version}"

    checkinstall \
        "${args[@]}" \
        cmake --install .
}

###############################################################################
# SDL3 本体
###############################################################################

info "SDL3 本体を取得"

SDL_TAG="$(get_latest_release_tag "${SDL_REPO}")"
SDL_VERSION="$(package_version_from_tag "${SDL_TAG}")"

echo "SDL3 tag:     ${SDL_TAG}"
echo "SDL3 version: ${SDL_VERSION}"

SDL_SRC="$(clone_release "${SDL_REPO}" "${SDL_TAG}" "SDL")"

rm -rf "${SDL_SRC}/build"

cmake \
    -S "${SDL_SRC}" \
    -B "${SDL_SRC}/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=ON \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF

cmake \
    --build "${SDL_SRC}/build" \
    --parallel "${JOBS}"

checkinstall_cmake_install \
    "libsdl3" \
    "${SDL_VERSION}" \
    "SDL3 shared and static development library" \
    "${SDL_SRC}/build"

###############################################################################
# SDL_image
###############################################################################

info "SDL3_image を取得"

SDL_IMAGE_TAG="$(get_latest_release_tag "${SDL_IMAGE_REPO}")"
SDL_IMAGE_VERSION="$(package_version_from_tag "${SDL_IMAGE_TAG}")"

echo "SDL3_image tag:     ${SDL_IMAGE_TAG}"
echo "SDL3_image version: ${SDL_IMAGE_VERSION}"

SDL_IMAGE_SRC="$(
    clone_release \
        "${SDL_IMAGE_REPO}" \
        "${SDL_IMAGE_TAG}" \
        "SDL_image"
)"

rm -rf "${SDL_IMAGE_SRC}/build"

cmake \
    -S "${SDL_IMAGE_SRC}" \
    -B "${SDL_IMAGE_SRC}/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    -DBUILD_SHARED_LIBS=ON \
    -DSDLIMAGE_INSTALL=ON \
    -DSDLIMAGE_TESTS=OFF \
    -DSDLIMAGE_EXAMPLES=OFF \
    -DSDLIMAGE_STRICT=ON

cmake \
    --build "${SDL_IMAGE_SRC}/build" \
    --parallel "${JOBS}"

checkinstall_cmake_install \
    "libsdl3-image" \
    "${SDL_IMAGE_VERSION}" \
    "SDL3 image loading library" \
    "${SDL_IMAGE_SRC}/build" \
    "libsdl3 (>= ${SDL_VERSION})"

###############################################################################
# SDL_ttf
###############################################################################

info "SDL3_ttf を取得"

SDL_TTF_TAG="$(get_latest_release_tag "${SDL_TTF_REPO}")"
SDL_TTF_VERSION="$(package_version_from_tag "${SDL_TTF_TAG}")"

echo "SDL3_ttf tag:     ${SDL_TTF_TAG}"
echo "SDL3_ttf version: ${SDL_TTF_VERSION}"

SDL_TTF_SRC="$(
    clone_release \
        "${SDL_TTF_REPO}" \
        "${SDL_TTF_TAG}" \
        "SDL_ttf"
)"

rm -rf "${SDL_TTF_SRC}/build"

cmake \
    -S "${SDL_TTF_SRC}" \
    -B "${SDL_TTF_SRC}/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    -DBUILD_SHARED_LIBS=ON \
    -DSDLTTF_INSTALL=ON \
    -DSDLTTF_TESTS=OFF \
    -DSDLTTF_SAMPLES=OFF

cmake \
    --build "${SDL_TTF_SRC}/build" \
    --parallel "${JOBS}"

checkinstall_cmake_install \
    "libsdl3-ttf" \
    "${SDL_TTF_VERSION}" \
    "SDL3 TrueType font rendering library" \
    "${SDL_TTF_SRC}/build" \
    "libsdl3 (>= ${SDL_VERSION})"

###############################################################################
# SDL_mixer
###############################################################################

info "SDL3_mixer を取得"

SDL_MIXER_TAG="$(get_latest_release_tag "${SDL_MIXER_REPO}")"
SDL_MIXER_VERSION="$(package_version_from_tag "${SDL_MIXER_TAG}")"

echo "SDL3_mixer tag:     ${SDL_MIXER_TAG}"
echo "SDL3_mixer version: ${SDL_MIXER_VERSION}"

SDL_MIXER_SRC="$(
    clone_release \
        "${SDL_MIXER_REPO}" \
        "${SDL_MIXER_TAG}" \
        "SDL_mixer"
)"

rm -rf "${SDL_MIXER_SRC}/build"

cmake \
    -S "${SDL_MIXER_SRC}" \
    -B "${SDL_MIXER_SRC}/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    -DBUILD_SHARED_LIBS=ON \
    -DSDLMIXER_INSTALL=ON \
    -DSDLMIXER_TESTS=OFF \
    -DSDLMIXER_EXAMPLES=OFF \
    -DSDLMIXER_STRICT=ON \
    -DSDLMIXER_DEPS_SHARED=ON \
    -DSDLMIXER_FLAC=ON \
    -DSDLMIXER_MP3=ON \
    -DSDLMIXER_MP3_MPG123=ON \
    -DSDLMIXER_MIDI=ON \
    -DSDLMIXER_MIDI_FLUIDSYNTH=ON \
    -DSDLMIXER_MIDI_TIMIDITY=ON \
    -DSDLMIXER_OPUS=ON \
    -DSDLMIXER_VORBIS_STB=ON \
    -DSDLMIXER_VORBIS_VORBISFILE=ON \
    -DSDLMIXER_MOD_XMP=ON \
    -DSDLMIXER_WAVPACK=ON \
    -DSDLMIXER_GME=ON

cmake \
    --build "${SDL_MIXER_SRC}/build" \
    --parallel "${JOBS}"

checkinstall_cmake_install \
    "libsdl3-mixer" \
    "${SDL_MIXER_VERSION}" \
    "SDL3 audio mixer library" \
    "${SDL_MIXER_SRC}/build" \
    "libsdl3 (>= ${SDL_VERSION})"

###############################################################################
# SDL_net
###############################################################################

info "SDL3_net を取得"

SDL_NET_TAG="$(get_latest_release_tag "${SDL_NET_REPO}")"
SDL_NET_VERSION="$(package_version_from_tag "${SDL_NET_TAG}")"

echo "SDL3_net tag:     ${SDL_NET_TAG}"
echo "SDL3_net version: ${SDL_NET_VERSION}"

SDL_NET_SRC="$(
    clone_release \
        "${SDL_NET_REPO}" \
        "${SDL_NET_TAG}" \
        "SDL_net"
)"

rm -rf "${SDL_NET_SRC}/build"

cmake \
    -S "${SDL_NET_SRC}" \
    -B "${SDL_NET_SRC}/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    -DBUILD_SHARED_LIBS=ON \
    -DSDLNET_INSTALL=ON \
    -DSDLNET_TESTS=OFF \
    -DSDLNET_EXAMPLES=OFF

cmake \
    --build "${SDL_NET_SRC}/build" \
    --parallel "${JOBS}"

checkinstall_cmake_install \
    "libsdl3-net" \
    "${SDL_NET_VERSION}" \
    "SDL3 networking library" \
    "${SDL_NET_SRC}/build" \
    "libsdl3 (>= ${SDL_VERSION})"

###############################################################################
# 動的ライブラリキャッシュ更新
###############################################################################

info "動的ライブラリキャッシュを更新"

ldconfig

###############################################################################
# インストール確認
###############################################################################

info "インストールされたSDL3パッケージを確認"

dpkg-query \
    -W \
    -f='${Package}\t${Version}\t${Architecture}\n' \
    libsdl3 \
    libsdl3-image \
    libsdl3-ttf \
    libsdl3-mixer \
    libsdl3-net

###############################################################################
# pkg-config確認
###############################################################################

info "pkg-configを確認"

echo
echo "SDL3:"
pkg-config --modversion sdl3 || true

echo
echo "SDL3_image:"
pkg-config --modversion sdl3_image || true

echo
echo "SDL3_ttf:"
pkg-config --modversion sdl3_ttf || true

echo
echo "SDL3_mixer:"
pkg-config --modversion sdl3_mixer || true

echo
echo "SDL3_net:"
pkg-config --modversion sdl3_net || true

###############################################################################
# パッケージ一覧
###############################################################################

info "生成されたDebianパッケージ"

find "${PACKAGE_DIR}" \
    -maxdepth 1 \
    -type f \
    -name '*.deb' \
    -printf '%f\n' |
sort -V

###############################################################################
# 完了
###############################################################################

info "SDL3一式のインストールが完了しました"

echo "インストール済みパッケージ:"
echo
dpkg-query \
    -W \
    -f='  ${Package} ${Version} ${Architecture}\n' \
    libsdl3 \
    libsdl3-image \
    libsdl3-ttf \
    libsdl3-mixer \
    libsdl3-net

echo
echo "生成されたDebianパッケージ:"
echo "  ${PACKAGE_DIR}"

echo
echo "今後最新版へ更新する場合:"
echo "  sudo ./install-sdl3.sh"

echo
echo "現在のSDL3パッケージのバージョン確認:"
echo "  dpkg-query -W 'libsdl3*'"

echo
echo "完了しました。"
