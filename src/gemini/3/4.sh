#!/bin/bash
set -e

# エラー発生時に詳細を出力
trap 'echo "エラーが発生したため、スクリプトの実行を停止しました。行番号: $LINENO"' ERR

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
rm -rf "$BUILD_DIR"
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

# GitHubから最新の安定版タグ（release-3.偶数.x または preview-3.偶数.x）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag_list
    
    # APIからタグ一覧を取得
    tag_list=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+')
    
    if [ -z "$tag_list" ]; then
        echo "エラー: ${repo} のタグ一覧をGitHub APIから取得できませんでした。" >&2
        return 1
    fi

    # release-3.x.x または preview-3.x.x から、マイナーバージョンが偶数のものを抽出して最新の1つを取得
    # 例: release-3.2.0, release-3.4.12 などの偶数系を優先
    local stable_tag
    stable_tag=$(echo "$tag_list" | grep -E '^(release|preview)-3\.[0-2468]\.' | head -n 1)
    
    # もし上記形式がなければ、プレフィックスなしの v3.偶数.x も探す
    if [ -z "$stable_tag" ]; then
        stable_tag=$(echo "$tag_list" | grep -E '^v3\.[0-2468]\.' | head -n 1)
    fi

    # それでも見つからない場合はエラー
    if [ -z "$stable_tag" ]; then
        echo "エラー: ${repo} の安定版タグ（マイナーバージョンが偶数）が見つかりませんでした。" >&2
        return 1
    fi
    
    echo "$stable_tag"
}

# ビルド・checkinstallを実行する共通関数
build_and_install() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} の取得とビルドを開始 ---"
    cd "$BUILD_DIR"
    
    # 最新安定版タグの取得（失敗した場合は即座にエラー終了）
    local tag
    tag=$(get_latest_stable_tag "$repo") || exit 1
    echo "${name} のターゲットバージョン: ${tag}"
    
    # クローンおよびチェックアウト
    rm -rf "$name"
    git clone --depth 1 --branch "$tag" "https://github.com/${repo}.git" "$name"
    cd "$name"
    
    # checkinstall用のダミー説明ファイルを生成（対話プロンプトでの停止を回避）
    echo "${name} library built from source using SDL3 automated script" > description-pak
    
    # ビルド
    mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    make -j$(nproc)
    
    # バージョン文字列から数字部分のみを抽出（例: release-3.4.10 -> 3.4.10）
    local version_num
    version_num=$(echo "${tag}" | grep -oP '3\.[0-9]+\.[0-9]+(-[^ ]+)?' || echo "3.0.0")
    
    # checkinstallによるDebianパッケージ化とインストール
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${version_num}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc
}

echo "=== [2/7] SDL3 本体のビルド ==="
build_and_install "libsdl-org/SDL" "SDL" "sdl3"

# ライブラリパスを認識させるために更新
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
