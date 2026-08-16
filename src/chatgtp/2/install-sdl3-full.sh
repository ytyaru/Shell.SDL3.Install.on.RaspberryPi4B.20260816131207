#!/bin/bash
set -e

echo "=== [1/2] システムの更新と必須依存パッケージの確認・導入 ==="
# aptは既にインストール済みのパッケージは自動でスキップします
sudo apt update
sudo apt install -y \
    cmake ninja-build build-essential git pkg-config \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev \
    libx11-dev libxext-dev libxrandr-dev \
    libasound2-dev libpulse-dev libpipewire-0.3-dev \
    libfreetype-dev libharfbuzz-dev fonts-noto-cjk \
    libpng-dev libjpeg-dev libwebp-dev \
    libmodplug-dev libvorbis-dev libflac-dev libopus-dev

# RAMディスク配下にビルド用ワークスペースを作成
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 4GBモデル向け：4コア並列ビルド設定
export CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)

# --- ビルド＆インストール用共通関数 ---
build_sdl_lib() {
    local lib_name=$1
    local repo_url=$2
    local pkg_name=$3

    echo "--------------------------------------------------"
    if pkg-config --exists "$pkg_name"; then
        echo "✅ $lib_name はすでにインストールされているため、ビルドをスキップします。"
    else
        echo "⚙️ $lib_name が見つかりません。ビルドを開始します..."
        cd "$BUILD_DIR"
        
        # すでにフォルダがある場合は一度消して最新を落とす（/tmpなので安全）
        if [ -d "$lib_name" ]; then rm -rf "$lib_name"; fi
        
        git clone --depth 1 "$repo_url"
        cd "$lib_name"
        mkdir -p build && cd build
        cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local ..
        ninja
        sudo ninja install
        echo "🎉 $lib_name のインストールが完了しました。"
    fi
    pkg-config --modversion "$pkg_name"
}

echo "=== [2/2] 各種SDL3ライブラリのチェックと自動ビルド ==="

# 1. SDL3 本体
build_sdl_lib "SDL" "https://github.com/libsdl-org/SDL" "sdl3"

# 2. SDL3_image
build_sdl_lib "SDL_image" "https://github.com/libsdl-org/SDL_image" "sdl3-image"

# 3. SDL3_ttf
build_sdl_lib "SDL_ttf" "https://github.com/libsdl-org/SDL_ttf" "sdl3-ttf"

# 4. SDL3_mixer
build_sdl_lib "SDL_mixer" "https://github.com/libsdl-org/SDL_mixer" "sdl3-mixer"

# 5. SDL3_net
build_sdl_lib "SDL_net" "https://github.com/libsdl-org/SDL_net" "sdl3-net"

# システムのライブラリキャッシュを更新
sudo ldconfig

echo "========================================="
echo "  すべての処理が正常に完了しました！"
echo "  存在しなかったライブラリのみが追加されています。"
echo "========================================="

