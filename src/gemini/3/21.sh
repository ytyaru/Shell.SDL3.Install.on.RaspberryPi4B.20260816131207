#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git pkg-config curl jq \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev ninja-build

# GitHubから最新の安定版タグ（偶数マイナーバージョン 例: release-3.2.x, release-3.4.x）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | jq -r '.[].name' | grep -E '^(release-|v)?3\.[02468]\.' | head -n 1)
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の最新安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# ビルド・パッケージ化・インストールを実行する共通関数
process_library() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "=== [処理開始] ${name} ==="
    
    # 既にaptインストール済みかチェック
    if dpkg -l | grep -q " ${pkg_name} "; then
        echo "${pkg_name} は既にシステムにインストールされています。スキップします。"
        return 0
    fi
    
    local tag=$(get_latest_stable_tag "$repo")
    # バージョン番号（数字から始まる形式）のクレンジング抽出
    local version=$(echo "$tag" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$version" ]; then
        version="3.0.0"
    fi
    
    local folder_name="${name}-${tag}"
    local archive_file="${tag}.tar.gz"
    
    cd "$BUILD_DIR"
    
    # 1. ダウンロードと展開（キャッシュチェック）
    if [ -d "$folder_name" ]; then
        echo "既存のソースコードキャッシュを発見しました。ダウンロードをスキップします: $folder_name"
    else
        echo "アーカイブをダウンロード中... (${tag})"
        curl -L -o "$archive_file" "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
        tar -xzf "$archive_file"
        rm "$archive_file"
    fi
    
    cd "$folder_name"
    
    # 2. ビルド（キャッシュチェック）
    if [ -f "build/build.ninja" ] && [ -f "build/lib${name}.a" -o -f "build/lib${name}3.so" -o -f "build/libSDL3.so" ]; then
        echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        echo "CMakeによるビルド構成とコンパイルを開始します（Ninja, 2コア制限）..."
        mkdir -p build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        ninja -j2
        cd ..
    fi
    
    # 3. 隔離ディレクトリ（stage_dir）への擬似インストール
    local stage_dir="/tmp/stage_${pkg_name}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    
    echo "隔離環境（stage_dir）へ一時インストール中..."
    DESTDIR="$stage_dir" ninja -C build install
    
    # 4. dpkg-deb用のメタデータ作成とビルド
    mkdir -p "$stage_dir/DEBIAN"
    cat << EOF > "$stage_dir/DEBIAN/control"
Package: ${pkg_name}
Version: ${version}-1
Section: libs
Priority: optional
Architecture: arm64
Maintainer: raspberrypi-user
Description: SDL3 built from source via automated script
Provides: ${pkg_name}
EOF

    echo "apt管理用パッケージの作成（dpkg-deb）中..."
    local deb_file="/tmp/${pkg_name}_${version}-1_arm64.deb"
    sudo dpkg-deb --build --root-owner-group "$stage_dir" "$deb_file"
    
    echo "システム（/usr/local）へファイルを安全に上書きマージ・強制インストール中..."
    sudo dpkg -i --force-overwrite "$deb_file"
    
    # 一時フォルダのクリーンアップ
    rm -rf "$stage_dir"
    rm -f "$deb_file"
    
    # ライブラリパスを認識させる
    sudo ldconfig
}

echo "=== [2/7] SDL3 本体のインストール ==="
process_library "libsdl-org/SDL" "SDL" "sdl3"

echo "=== [3/7] SDL3_image のインストール ==="
process_library "libsdl-org/SDL_image" "SDL_image" "sdl3-image"

echo "=== [4/7] SDL3_ttf のインストール ==="
process_library "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"

echo "=== [5/7] SDL3_mixer のインストール ==="
process_library "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"

echo "=== [6/7] SDL3_net のインストール ==="
process_library "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

echo "=== [7/7] システム全体の共有ライブラリキャッシュ最終更新 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 フルセットの強制マージインストールが完了しました！"
echo " apt list --installed | grep sdl3 で管理状態を確認できます。"
echo "========================================================"
