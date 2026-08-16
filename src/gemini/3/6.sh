#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git checkinstall pkg-config curl ninja-build \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# 事前に必要なインストール先ディレクトリ群を作成し、checkinstall時のCMake仮想パスエラーを防ぐ
sudo mkdir -p /usr/local/lib/pkgconfig
sudo mkdir -p /usr/local/include
sudo mkdir -p /usr/local/bin
sudo mkdir -p /usr/local/share

# GitHubから最新の安定版タグを取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
                 grep -oP '"name": "\K[^"]+' | \
                 grep -E '^(v3\.[02468]\.|release-3\.[02468]\.|preview-3\.[02468]\.)' | head -n 1)
    
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の安定版タグが取得できませんでした。" >&2
        exit 1
    fi
    echo "$tag"
}

# ビルド・checkinstallを実行する共通関数
build_and_install() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} の取得とビルドを開始 ---"
    cd "$BUILD_DIR"
    
    # 最新安定版タグの取得
    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} の最新安定ターゲットバージョン: ${tag}"
    
    # 既存リポジトリがあれば再利用して差分取得、なければ新規クローン
    if [ -d "$name" ]; then
        echo "既存のリポジトリキャッシュを発見しました。再利用して同期します。"
        cd "$name"
        git fetch --tags
        git checkout "$tag"
    else
        git clone --depth 1 --branch "$tag" "https://github.com/${repo}.git" "$name"
        cd "$name"
    fi
    
    # ビルド設定（Ninjaを使用）
    mkdir -p build && cd build
    cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    
    # メモリ枯渇を防止するため指定通り最大2コア(-j2)で並列ビルド
    ninja -j2
    
    # checkinstall用説明ファイルの作成（プロンプト停止対策）
    echo "Automated installation of ${pkg_name} ${tag} compiled via Ninja" > description-pak
    
    # checkinstallによるDebianパッケージ化とインストール
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${tag#v}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        ninja install
}

echo "=== [2/7] SDL3 本体のビルド ==="
build_and_install "libsdl-org/SDL" "SDL" "sdl3"

# 後続ライブラリのビルドでCMakeが最新のSDL3を確実に検出できるように共有ライブラリとキャッシュを更新
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
echo " 全ての SDL3 フルセットのインストールが正常に完了しました！"
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
