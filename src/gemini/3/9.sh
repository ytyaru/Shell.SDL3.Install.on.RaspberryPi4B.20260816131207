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

# 必要な親階層のディレクトリをあらかじめ実システム側に強制作成
sudo mkdir -p /usr/local/lib/pkgconfig
sudo mkdir -p /usr/local/include

# GitHubから最新の安定版タグ（偶数マイナーバージョン 例: release-3.4.14）を取得する関数
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
    
    # 最新安定版タグの取得
    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"
    
    # バージョン文字列の整形（release-3.4.14 や v3.4.14 から数字部分だけを抽出）
    local version=$(echo "$tag" | grep -oP '3\.[0-9]+\.[0-9]+')
    local dir_name="${name}-${version}"
    
    # 既存の展開済みソースコードディレクトリがあるか確認
    if [ -d "$dir_name" ]; then
        echo "既存のソースコードキャッシュを見つけました。ダウンロードをスキップします: ${dir_name}"
        cd "$dir_name"
    else
        echo "最新安定版ソースコードをTarballでダウンロード中..."
        # tarballのURL（例: https://github.com/libsdl-org/SDL/archive/refs/tags/release-3.4.14.tar.gz）
        local url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
        
        # 一時的なアーカイブ保存をせず、パイプでそのままRAMディスク（/tmp）へストリーム展開
        curl -sL "$url" | tar -xzf -
        cd "$dir_name"
    fi
    
    # ビルドディレクトリの作成
    mkdir -p build && cd build
    
    # CMakeでNinjaジェネレータを指定
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    
    # ラズパイ4Bのメモリ超過を防ぐため、明示的に2コア（-j2）に制限してビルド
    ninja -j2
    
    # checkinstall用のダミー説明ファイルを作成（対話プロンプトでの停止を防止）
    echo "${name} library managed via apt (built from source with SDL3 fullセット)" > description-pak
    
    # checkinstallによるDebianパッケージ化とインストール
    # --fakerootを付与することで、CMake/Ninjaが仮想隔離空間を正しく認識しコピーエラーを完全に防ぎます
    sudo checkinstall -y \
        --fakeroot \
        --pkgname="${pkg_name}" \
        --pkgversion="${version}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc
}

echo "=== [2/7] SDL3 本体のインストール ==="
build_and_install "libsdl-org/SDL" "SDL" "sdl3"

# 各拡張ライブラリが本体のパスをpkg-config等で見つけられるようにキャッシュを更新
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
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
