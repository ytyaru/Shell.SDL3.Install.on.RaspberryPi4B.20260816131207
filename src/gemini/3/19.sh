#!/bin/bash
set -e

# 作業場所の設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git pkg-config curl dpkg-dev ninja-build \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# 最新の安定版タグ（偶数マイナー）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^(v3\.[02468]\.|release-3\.[02468]\.)' | head -n 1)
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の安定版タグの自動取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# パッケージをダミービルドしてapt登録（dpkg-deb直接生成アプローチ）する関数
process_library() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} の処理を開始 ---"
    
    # すでにインストール済み（apt）なら完全スキップ
    if dpkg -l | grep -q " ${pkg_name} "; then
        echo "既に ${pkg_name} は apt インストール済みのため、全体をスキップします。"
        return 0
    fi
    
    local tag=$(get_latest_stable_tag "$repo")
    # バージョン名から数字だけを抽出（dpkg命名規則用）
    local clean_version=$(echo "$tag" | grep -oP '\d+\.\d+\.\d+')
    if [ -z "$clean_version" ]; then
        clean_version="3.0.0"
    fi
    
    local folder_name="${name}-${tag}"
    local src_dir="${BUILD_DIR}/${folder_name}"
    
    # 1. ダウンロードのスキップ判定
    if [ -d "$src_dir" ]; then
        echo "既存のソースコードを発見しました。ダウンロードをスキップします: ${folder_name}"
        cd "$src_dir"
    else
        echo "アーカイブをダウンロード中... (${tag})"
        curl -L "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" | tar -xzf -
        cd "$src_dir"
    fi
    
    # 2. ビルドのスキップ判定
    if [ -f "build/build.ninja" ] && [ -d "build" ]; then
        echo "既にビルド構成が存在します。再生成をスキップします。"
        cd build
    else
        mkdir -p build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    fi
    
    # 2コア制限による超高速・安全ビルド
    echo "2コア並列でコンパイルを開始します..."
    ninja -j2
    
    # 3. checkinstallのクラッシュを完全に回避するdpkg-debダイレクト方式
    echo "安全なステージング環境へインストール中..."
    local stage_dir="/tmp/stage_${pkg_name}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    DESTDIR="$stage_dir" ninja install
    
    # 実際のシステムへtar同期（上書き/マージ衝突エラーを100%回避）
    echo "システム（/usr/local）へファイルを安全に配置中..."
    sudo mkdir -p /usr/local
    sudo sh -c "tar -C ${stage_dir}/usr/local -cf - . | tar -C /usr/local -xf -"
    
    # dpkg用のDEBIANコントロールファイルを完全手動生成
    echo "apt管理用パッケージの作成（dpkg-deb）中..."
    mkdir -p "${stage_dir}/DEBIAN"
    cat << EOF > "${stage_dir}/DEBIAN/control"
Package: ${pkg_name}
Version: ${clean_version}-1
Section: libs
Priority: optional
Architecture: arm64
Maintainer: raspberrypi-user
Description: ${name} built from source via automated stable script.
Provides: ${pkg_name}
EOF
    
    # 本物のdebパッケージを生成して登録
    dpkg-deb --build "$stage_dir" "/tmp/${pkg_name}_${clean_version}-1_arm64.deb"
    sudo dpkg -i "/tmp/${pkg_name}_${clean_version}-1_arm64.deb"
    
    # クリーンアップ
    rm -rf "$stage_dir"
    echo "--- ${name} のインストールおよび apt 管理登録が完了しました ---"
}

# 各コンポーネントを順番に処理
process_library "libsdl-org/SDL" "SDL" "sdl3"
sudo ldconfig

process_library "libsdl-org/SDL_image" "SDL_image" "sdl3-image"
process_library "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"
process_library "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"
process_library "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

sudo ldconfig

echo "========================================================"
echo " [完了] すべての SDL3 フルセットの apt 登録が完了しました！"
echo " 今後は以下のコマンドで完全にコンパイルできます："
echo " g++ test_sdl3.cpp -o test_sdl3 \$(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)"
echo "========================================================"
