#!/bin/bash
# -------------------------------------------------------------------------
# Raspberry Pi 4B (4GB) 向け SDL3 最新安定版フルセット全自動ビルド＆インストールスクリプト
# -------------------------------------------------------------------------
set -e

WORK_DIR="/tmp/sdl3_build"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git checkinstall pkg-config \
    libasound2-dev libpulse-dev libaudio-dev libjack-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxkbcommon-dev \
    libwayland-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev libdrm-dev \
    libdbus-1-dev libibus-1-dev libudev-dev libpipewire-0.3-dev \
    libvulkan-dev libdecor-0-dev \
    libfreetype-dev libharfbuzz-dev libfontconfig1-dev \
    libflac-dev libmodplug-dev libvorbis-dev libogg-dev libopus-dev libmpg123-dev \
    curl jq

get_latest_stable_tag() {
    local repo_url=$1
    curl -s "https://api.github.com/repos/${repo_url}/tags" | jq -r '.[].name' | grep -E '^release-3\.[02468]\.' | head -n 1
}

build_and_install() {
    local repo_name=$1
    local repo_url=$2
    local pkg_name=$(echo "$repo_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    echo "--- ${repo_name} の処理を開始 ---"
    
    local tag=$(get_latest_stable_tag "$repo_url")
    if [ -z "$tag" ] || [ "$tag" == "null" ]; then
        tag=$(curl -s "https://api.github.com/repos/${repo_url}/tags" | jq -r '.[].name' | grep '^release-3\.' | head -n 1)
    fi
    
    echo "最新の安定版タグとして [${tag}] を検出しました。"

    if [ -d "$repo_name" ]; then
        rm -rf "$repo_name"
    fi
    git clone --depth 1 --branch "$tag" "https://github.com/${repo_url}.git" "$repo_name"
    cd "$repo_name"

    mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local

    make -j$(nproc)

    local version_str=$(echo "$tag" | sed 's/^release-//')

    sudo checkinstall -y \
        --pkgname="$pkg_name" \
        --pkgversion="$version_str" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --provides="$pkg_name" \
        --requires="" \
        --maintainer="raspberrypi-user@local" \
        --nodoc \
        make install

    sudo ldconfig
    cd "$WORK_DIR"
    echo "--- ${repo_name} のインストールが完了しました ---"
}

echo "=== [2/7] SDL3 コアのビルドとインストール ==="
build_and_install "SDL" "libsdl-org/SDL"

echo "=== [3/7] SDL_image のビルドとインストール ==="
build_and_install "SDL_image" "libsdl-org/SDL_image"

echo "=== [4/7] SDL_ttf のビルドとインストール ==="
build_and_install "SDL_ttf" "libsdl-org/SDL_ttf"

echo "=== [5/7] SDL_mixer のビルドとインストール ==="
build_and_install "SDL_mixer" "libsdl-org/SDL_mixer"

echo "=== [6/7] SDL_net のビルドとインストール ==="
build_and_install "SDL_net" "libsdl-org/SDL_net"

echo "=== [7/7] 環境設定の最終確認 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 ライブラリのインストールが完了しました！"
echo "========================================================"
