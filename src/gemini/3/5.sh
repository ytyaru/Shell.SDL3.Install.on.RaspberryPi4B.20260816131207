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

# インストール先ディレクトリをあらかじめ作成してcheckinstallのエラーを防ぐ
sudo mkdir -p /usr/local/lib/pkgconfig
sudo mkdir -p /usr/local/include
sudo mkdir -p /usr/local/share

# GitHubから最新の安定版タグ（偶数マイナーバージョン 例: release-3.2.0 や release-3.4.0）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=""
    
    # APIからタグ一覧を取得し、release-3.[偶数].x を厳格に抽出して最新のトップを選ぶ
    tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
          grep -oP '"name": "\K[^"]+' | \
          grep -E '^release-3\.[02468]\.' | head -n 1)
          
    # 取得できなかった場合はスクリプトの誤魔化しを行わずエラー終了させる
    if [ -z "$tag" ]; then
        echo "エラー: ${repo} の最新安定版タグがGitHub APIから取得できませんでした。" >&2
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
    
    # 最新安定版タグの厳格な取得
    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"
    
    # ディレクトリが存在する場合は削除せず再利用（キャッシュ・差分取得）
    if [ -d "$name" ]; then
        echo "既存のディレクトリ ${name} を再利用します。fetchを行います。"
        cd "$name"
        git fetch --tags
        git checkout "$tag"
    else
        echo "新規にクローンを行います。"
        git clone --depth 1 --branch "$tag" "https://github.com/${repo}.git" "$name"
        cd "$name"
    fi
    
    # Ninjaビルド用の設定
    mkdir -p build && cd build
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    ninja
    
    # checkinstall用ダミー説明ファイルの生成（対話プロンプト防止）
    echo "${name} package managed via checkinstall" > description-pak
    
    # checkinstallによるDebianパッケージ化とインストール（Ninjaを使用）
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${tag#release-}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        ninja install
}

echo "=== [2/7] SDL3 本体のビルド ==="
build_and_install "libsdl-org/SDL" "SDL" "sdl3"

# ライブラリパスを認識させる
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
