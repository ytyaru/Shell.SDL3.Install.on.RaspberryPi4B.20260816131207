#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git checkinstall pkg-config curl \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# GitHubから最新の安定版タグ（偶数マイナーバージョン 例: v3.2.0）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    # APIからタグ一覧を取得し、開発版（3.1.xや3.3.xなど奇数）を除外して最新の安定版（偶数マイナー）のトップを選ぶ
    local tag=$(curl -s "https://api.github.com/repos/\${repo}/tags" | \
    grep -oP '"name": "\K[^"]+' | \
    grep -E '^v3\.[02468]\.' | head -n 1)
    
    if [ -z "$tag" ]; then
        # API制限やネットワーク不調時のフォールバック：リリース一覧から最新を取得
        tag=$(curl -s "https://api.github.com/repos/\${repo}/releases/latest" | grep -oP '"tag_name": "\K[^"]+')
    fi
    if [ -z "$tag" ]; then
        # 最終フォールバック：最新のタグをそのまま取得
        tag=$(curl -s "https://api.github.com/repos/\${repo}/tags" | grep -oP '"name": "\K[^"]+' | head -n 1)
    fi
    echo "$tag"
}

# ビルド・checkinstallを実行する共通関数
build_and_install() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- \${name} の取得とビルドを開始 ---"
    cd "$BUILD_DIR"
    
    # 最新安定版タグの取得
    local tag=$(get_latest_stable_tag "\$repo")
    echo "\${name} のターゲットバージョン: \${tag}"
    
    # クローンおよびチェックアウト
    git clone --depth 1 --branch "\${tag}" "https://github.com/\${repo}.git" "\${name}"
    cd "\${name}"
    
    # ビルド
    mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    make -j\$(nproc)
    
    # checkinstallによるDebianパッケージ化とインストール
    sudo checkinstall -y \
        --pkgname="\${pkg_name}" \
        --pkgversion="\${tag#v}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="\${pkg_name}" \
        --nodoc
}

echo "=== [2/7] SDL3 本体のビルド ==="
build_and_install "libsdl-org/SDL" "SDL" "sdl3"

# ライブラリパスを一時的に認識させる
sudo ldconfig

echo "=== [3/7] SDL3_image のビルド ==="
build_and_install "libsdl-org/SDL_image" "SDL_image" "sdl3-image"

echo "=== [4/7] SDL3_ttf のビルド ==="
build_and_install "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"

echo "=== [5/7] SDL3_mixer のビルド ==="
build_and_install "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"

echo "=== [6/7] SDL3_net のビルド ==="
build_and_install "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

echo "=== [7/7] システム全体の共有ライブラリキャッシュ更新 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 フルセットのインストールが完了しました！"
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"