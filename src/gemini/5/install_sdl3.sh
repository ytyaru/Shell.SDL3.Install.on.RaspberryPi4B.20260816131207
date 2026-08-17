#!/bin/bash
# Raspberry Pi 4B (4GB) 向け SDL3 / SDL3_image / SDL3_ttf / SDL3_mixer / SDL3_net 自動ビルドスクリプト
# RAMディスク（/tmp/sdl3_build）上で、2コアを使用してビルドを行います。
# IMEによる日本語入力（fcitx5/ibus）に対応するための依存関係も自動インクルードします。

set -e

# エラーハンドリング
error_exit() {
    echo -e "\e[1;31m[エラー] $1\e[0m" >&2
    exit 1
}

echo -e "\e[1;32m[1/5] 依存パッケージのインストールを開始します...\e[0m"
sudo apt-get update || error_exit "パッケージリストの更新に失敗しました。"
sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    ninja-build \
    pkg-config \
    libasound2-dev \
    libpulse-dev \
    libaudio-dev \
    libjack-dev \
    libsndio-dev \
    libx11-dev \
    libxext-dev \
    libxrandr-dev \
    libxcursor-dev \
    libxfixes-dev \
    libxi-dev \
    libxss-dev \
    libxkbcommon-dev \
    libdrm-dev \
    libgbm-dev \
    libwayland-dev \
    wayland-protocols \
    libegl1-mesa-dev \
    libgles2-mesa-dev \
    libgl1-mesa-dev \
    libdbus-1-dev \
    libibus-1.0-dev \
    fcitx5-modules-dev \
    libfcitx5gclient-dev \
    libvulkan-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libharfbuzz-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libwebp-dev \
    libvorbis-dev \
    libogg-dev \
    libflac-dev \
    libopus-dev \
    || error_exit "依存パッケージのインストールに失敗しました。"

# RAMディスク上のビルドディレクトリ設定
BUILD_DIR="/tmp/sdl3_build"
echo -e "\e[1;32m[2/5] RAMディスク上にビルド環境を作成します: ${BUILD_DIR}\e[0m"

if [ -d "$BUILD_DIR" ]; then
    echo "既存のビルドディレクトリを削除します..."
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || error_exit "ビルドディレクトリへの移動に失敗しました。"

# バージョン定義（安定版リリースタグを指定）
SDL3_TAG="main"
SDL3_IMAGE_TAG="main"
SDL3_TTF_TAG="main"
SDL3_MIXER_TAG="main"
SDL3_NET_TAG="main"

# 使用コア数の設定（メモリ不足防止のため2コアに制限）
NUM_CORES=2

echo -e "\e[1;32m[3/5] SDL3 コアライブラリのビルドとインストールを開始します...\e[0m"
git clone --depth 1 --branch ${SDL3_TAG} https://github.com/libsdl-org/SDL.git sdl3
cd sdl3
mkdir build && cd build
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DSDL_F_INPUT_METHOD=ON \
    -DSDL_IBUS=ON \
    -DSDL_FCITX=ON \
    .. || error_exit "SDL3のCMake構成に失敗しました。"
ninja -j${NUM_CORES} || error_exit "SDL3のビルドに失敗しました。"
sudo ninja install || error_exit "SDL3のインストールに失敗しました。"
sudo ldconfig
cd "${BUILD_DIR}"

echo -e "\e[1;32m[4/5] SDL3 サテライトライブラリのビルドを開始します...\e[0m"

# SDL3_image
echo "ビルド中: SDL3_image..."
git clone --depth 1 --branch ${SDL3_IMAGE_TAG} https://github.com/libsdl-org/SDL_image.git sdl3_image
cd sdl3_image && mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local .. || error_exit "SDL3_imageのCMake構成に失敗しました。"
ninja -j${NUM_CORES} || error_exit "SDL3_imageのビルドに失敗しました。"
sudo ninja install || error_exit "SDL3_imageのインストールに失敗しました。"
cd "${BUILD_DIR}"

# SDL3_ttf
echo "ビルド中: SDL3_ttf..."
git clone --depth 1 --branch ${SDL3_TTF_TAG} https://github.com/libsdl-org/SDL_ttf.git sdl3_ttf
cd sdl3_ttf && mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local .. || error_exit "SDL3_ttfのCMake構成に失敗しました。"
ninja -j${NUM_CORES} || error_exit "SDL3_ttfのビルドに失敗しました。"
sudo ninja install || error_exit "SDL3_ttfのインストールに失敗しました。"
cd "${BUILD_DIR}"

# SDL3_mixer
echo "ビルド中: SDL3_mixer..."
git clone --depth 1 --branch ${SDL3_MIXER_TAG} https://github.com/libsdl-org/SDL_mixer.git sdl3_mixer
cd sdl3_mixer && mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local .. || error_exit "SDL3_mixerのCMake構成に失敗しました。"
ninja -j${NUM_CORES} || error_exit "SDL3_mixerのビルドに失敗しました。"
sudo ninja install || error_exit "SDL3_mixerのインストールに失敗しました。"
cd "${BUILD_DIR}"

# SDL3_net
echo "ビルド中: SDL3_net..."
git clone --depth 1 --branch ${SDL3_NET_TAG} https://github.com/libsdl-org/SDL_net.git sdl3_net
cd sdl3_net && mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local .. || error_exit "SDL3_netのCMake構成に失敗しました。"
ninja -j${NUM_CORES} || error_exit "SDL3_netのビルドに失敗しました。"
sudo ninja install || error_exit "SDL3_netのインストールに失敗しました。"

sudo ldconfig

echo -e "\e[1;32m[5/5] 全ての SDL3 ライブラリのビルドとインストールが正常に完了しました！\e[0m"
echo "RAMディスク上の作業ファイルをクリーンアップしています..."
rm -rf "${BUILD_DIR}"
echo "クリーンアップ完了。システムでSDL3が利用可能になりました。"
