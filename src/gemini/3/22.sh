#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/3] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git pkg-config curl ninja-build \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# 最新の安定版タグ（偶数マイナー）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag
    tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^(v3\.[02468]\.|release-3\.[02468]\.)' | head -n 1)
    if [ -z "$tag" ]; then
        tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | head -n 1)
    fi
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} のタグ取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# ダウンロード・ビルド・公式インストールの実行関数
install_standard() {
    local repo=$1
    local name=$2
    
    echo "--- ${name} の処理を開始 ---"
    cd "$BUILD_DIR"
    
    local tag
    tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"
    
    local dir_name="${name}-${tag}"
    
    # 1. ダウンロード判定
    if [ ! -d "$dir_name" ]; then
        echo "アーカイブをダウンロード中..."
        curl -L -s "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" | tar -xzf -
        # GitHubのデフォルト展開名（リポジトリ名-タグ名からプレフィックスを除く等）に対応
        local actual_dir
        actual_dir=$(ls -d * | grep -i "${name}" | grep "${tag#v}" || true)
        if [ -n "$actual_dir" ] && [ "$actual_dir" != "$dir_name" ]; then
            mv "$actual_dir" "$dir_name"
        fi
    else
        echo "既存のソースコードキャッシュを発見しました。ダウンロードをスキップします: $dir_name"
    fi
    
    cd "$dir_name"
    
    # 2. ビルド・インストール判定
    if [ -d "build" ] && [ -f "build/build.ninja" ]; then
        echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        mkdir -p build
        cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        ninja -C build -j2
    fi
    
    echo "公式手順に準拠したシステムへのインストールを実行中..."
    sudo ninja -C build install
}

echo "=== [2/3] 各ライブラリの公式標準インストールを実行 ==="
install_standard "libsdl-org/SDL" "SDL"
sudo ldconfig

install_standard "libsdl-org/SDL_image" "SDL_image"
install_standard "libsdl-org/SDL_ttf" "SDL_ttf"
install_standard "libsdl-org/SDL_mixer" "SDL_mixer"
install_standard "libsdl-org/SDL_net" "SDL_net"

echo "=== [3/3] 共有ライブラリキャッシュの最終更新 ==="
sudo ldconfig

echo "========================================================"
echo " 公式標準手順（/usr/local直下）でのインストールが完了しました！"
echo " g++でのコンパイルをお試しください。"
echo "========================================================"
