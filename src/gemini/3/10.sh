#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake ninja-build checkinstall pkg-config curl \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# 実システム側に各種インストール先ディレクトリの親階層を強制作成
sudo mkdir -p /usr/local/lib/pkgconfig /usr/local/include /usr/local/share

# GitHubから最新の安定版タグ（偶数マイナーバージョン）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
        grep -oP '"name": "\K[^"]+' | \
        grep -E '^(release-|v)?3\.[02468]\.' | head -n 1)
    
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の最新安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# ビルド・checkinstallを実行する共通関数
build_and_install() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} の処理を開始 ---"
    cd "$BUILD_DIR"
    
    local tag=$(get_latest_stable_tag "$repo")
    # バージョン文字列の整形（release-3.4.14 や v3.4.14 から 3.4.14 を抽出）
    local version=$(echo "$tag" | grep -oP '3\.[0-9]+\.[0-9]+')
    local dir_name="${name}-${version}"
    
    echo "${name} のターゲットバージョン: ${tag} (Version: ${version})"
    
    if [ -d "$dir_name" ]; then
        echo "既存のソースコードキャッシュを見つけました。ダウンロードをスキップします: ${dir_name}"
        cd "$dir_name"
    else
        echo "アーカイブをダウンロード中..."
        curl -L -s "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" -o "${name}-${tag}.tar.gz"
        tar -xzf "${name}-${tag}.tar.gz"
        rm "${name}-${tag}.tar.gz"
        cd "$dir_name"
    fi
    
    # ビルド設定と実行（2コア制限）
    mkdir -p build && cd build
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    ninja -j2
    
    # checkinstall用のダミー説明ファイル
    echo "${name} built from source stable tag ${tag}" > description-pak
    
    # checkinstallによるDebianパッケージ化とインストール
    # cmake --install ターゲットを直接 checkinstall に引き渡す
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${version}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        ninja install
}

echo "=== [2/7] SDL3 本体のインストール ==="
build_and_install "libsdl-org/SDL" "SDL" "sdl3"

sudo ldconfig

echo "=== [3/7] SDL3_image のインストール ==="
build_and_install "libsdl-org/SDL_image" "SDL_image" "sdl3-image"

echo "=== [4/7] SDL3_ttf のインストール ==="
build_and_install "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"

echo "=== [5/7] SDL3_mixer のインストール ==="
build_and_install "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"

echo "=== [6/7] SDL3_net のインストール ==="
build_and_install "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

echo "=== [7/7] システム全体の共有ライブラリキャッシュ更新 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 フルセットのインストールが完了しました！"
echo "========================================================"