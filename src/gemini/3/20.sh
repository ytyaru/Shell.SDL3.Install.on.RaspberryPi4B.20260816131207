#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git pkg-config curl ninja-build \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# GitHubから最新の安定版タグ（偶数マイナーバージョン）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^(v3\.[02468]\.|release-3\.[02468]\.)' | head -n 1)
    if [ -z "$tag" ]; then
        tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^v?3\.' | head -n 1)
    fi
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} のタグ取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# ビルド・dpkg-debによるパッケージ化を実行する共通関数
build_and_install_dpkg() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} の処理を開始 ---"
    cd "$BUILD_DIR"
    
    # 最新安定版タグの取得
    local tag=$(get_latest_stable_tag "$repo")
    # バージョン番号から数字部分(例: 3.4.14)のみを抽出
    local version=$(echo "$tag" | grep -oP '3\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$version" ]; then
        version="3.0.0"
    fi
    
    local folder_name="${name}-${tag}"
    local stage_dir="/tmp/stage_${pkg_name}"
    
    # 1. ダウンロードチェック
    if [ -d "$folder_name" ]; then
        echo "既存のソースコードキャッシュを見つけました。ダウンロードをスキップします: $folder_name"
        cd "$folder_name"
    else
        echo "${name} の最新安定バージョン: ${tag} (${version}) をダウンロード中..."
        curl -L "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" -o "${tag}.tar.gz"
        tar -xzf "${tag}.tar.gz"
        rm "${tag}.tar.gz"
        cd "$folder_name"
    fi
    
    # 2. ビルドチェック
    if [ -f "build/build.ninja" ] && [ -f "build/compile_commands.json" ]; then
        echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        mkdir -p build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        ninja -j2
        cd ..
    fi
    
    # 3. 隔離環境へのステージング
    echo "隔離環境（${stage_dir}）へダミーインストール中..."
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    DESTDIR="$stage_dir" ninja -C build install
    
    # 4. dpkg-deb用のメタデータ（control）作成
    mkdir -p "${stage_dir}/DEBIAN"
    cat << EOF > "${stage_dir}/DEBIAN/control"
Package: ${pkg_name}
Version: ${version}-1
Section: libs
Priority: optional
Architecture: arm64
Maintainer: raspberrypi-user
Provides: ${pkg_name}
Description: ${name} built from source via automated script
EOF
    
    # 5. システム（/usr/local）へファイルを安全に直接マージ配置
    echo "システム（/usr/local）へファイルを安全に配置中..."
    sudo mkdir -p /usr/local
    sudo sh -c "tar -C ${stage_dir}/usr/local -cf - . | tar -C /usr/local -xf -"
    
    # 6. dpkg-debパッケージの作成と、強制上書きによるインストール
    echo "apt管理用パッケージの作成（dpkg-deb）と競合強制上書きインストール中..."
    local deb_file="/tmp/${pkg_name}_${version}-1_arm64.deb"
    dpkg-deb --root-owner-group --build "$stage_dir" "$deb_file"
    sudo dpkg -i --force-overwrite "$deb_file"
    rm -f "$deb_file"
    rm -rf "$stage_dir"
}

echo "=== [2/7] SDL3 本体のインストール ==="
build_and_install_dpkg "libsdl-org/SDL" "SDL" "sdl3"
sudo ldconfig

echo "=== [3/7] SDL3_image のインストール ==="
build_and_install_dpkg "libsdl-org/SDL_image" "SDL_image" "sdl3-image"

echo "=== [4/7] SDL3_ttf のインストール ==="
build_and_install_dpkg "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"

echo "=== [5/7] SDL3_mixer のインストール ==="
build_and_install_dpkg "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"

echo "=== [6/7] SDL3_net のインストール ==="
build_and_install_dpkg "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

echo "=== [7/7] システム全体の共有ライブラリキャッシュ更新 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 フルセットの強制マージインストールが完了しました！"
echo " apt list --installed | grep sdl3 で管理状態を確認できます。"
echo "========================================================"
