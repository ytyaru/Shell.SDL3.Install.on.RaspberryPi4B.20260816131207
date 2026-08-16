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

# 最新の安定版タグ（偶数マイナー系列）を確実に取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
        grep -oP '"name": "\K[^"]+' | \
        grep -E '^(v3\.[02468]\.|release-3\.[02468]\.)' | head -n 1)
    
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の最新安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# ビルド・ステージングインストール・パッケージ化の共通関数
build_and_install() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} の処理を開始 ---"
    cd "$BUILD_DIR"
    
    # ターゲットバージョンの特定
    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"
    
    local dir_name="${name}-${tag#v}"
    dir_name="${dir_name#release-}"
    
    # すでにソースコードが展開されているかチェック、なければダウンロード
    if [ -d "$dir_name" ]; then
        echo "既存のソースコードキャッシュを発見しました。ダウンロードをスキップします: ${dir_name}"
        cd "$dir_name"
    else
        echo "アーカイブをダウンロード中..."
        curl -L -s "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" -o "${name}.tar.gz"
        tar -xf "${name}.tar.gz"
        rm "${name}.tar.gz"
        cd "$dir_name"
    fi
    
    # ビルドディレクトリの作成とCMakeの実行
    mkdir -p build && cd build
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    
    # ラズパイ4Bのメモリ枯渇を防ぐため、ご指定通り「2コア指定(-j2)」でNinjaビルド
    ninja -j2
    
    # checkinstallの仮想ルート環境バグを回避する決定的な解決策（ステージング方式）
    local stage_dir="/tmp/sdl3_stage_${pkg_name}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    
    # 一度安全な隔離環境に完全にインストールさせる（CMake本来の挙動を邪魔しない）
    DESTDIR="$stage_dir" ninja install
    
    # パッケージの簡易説明ファイルを自動生成（対話プロンプトでの停止を完全に回避）
    echo "${name} compiled from source on Raspberry Pi 4B" > description-pak
    
    # ステージング環境に構築されたファイル群を対象に、安全にcheckinstallを実行して.deb化
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${tag#v}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        --specfile=no \
        ninja -C . install DESTDIR="$stage_dir"
        
    # 後始末
    rm -rf "$stage_dir"
}

# 隔離環境からのインストール時に必要になるターゲット階層を実システム側に強制生成
sudo mkdir -p /usr/local/lib/pkgconfig /usr/local/include

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
echo " ご指定のpkg-configを用いたg++コマンドでコンパイル可能です。"
echo "========================================================"
