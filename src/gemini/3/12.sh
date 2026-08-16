#!/bin/bash
set -e

BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake checkinstall pkg-config curl ninja-build \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^(release-|v)?3\.[02468]\.' | head -n 1)
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の安定版タグ取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

process_library() {
    local repo=$1
    local name=$2
    local pkg_name=$3

    echo "--- ${name} の処理を開始 ---"
    cd "$BUILD_DIR"

    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"

    local repo_short="${repo#libsdl-org/}"
    local actual_dir="${repo_short}-${tag}"

    if [ -d "$BUILD_DIR/$actual_dir" ] && [ -f "$BUILD_DIR/$actual_dir/CMakeLists.txt" ]; then
        echo "すでに展開済みのソースコードを発見しました: $actual_dir"
        echo "ダウンロードをスキップし、そのままビルドへ移行します。"
        cd "$BUILD_DIR/$actual_dir"
    else
        echo "新規または未展開のため、アーカイブをダウンロードします..."
        rm -rf "$actual_dir"
        local download_url="https://github.com/\${repo}/archive/refs/tags/\${tag}.tar.gz"
        curl -L "\$download_url" | tar -xzf -
        cd "$actual_dir"
    fi

    mkdir -p build && cd build
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    ninja -j2

    local stage_dir="/tmp/stage_\${pkg_name}"
    rm -rf "\$stage_dir"
    mkdir -p "\$stage_dir"
    
    DESTDIR="\$stage_dir" ninja install

    echo "\${pkg_name} library package managed via checkinstall" > description-pak
    
    sudo checkinstall -y \
        --pkgname="\${pkg_name}" \
        --pkgversion="\${tag#release-}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="\${pkg_name}" \
        --nodoc \
        --fakeroot \
        sh -c "cp -rp \$stage_dir/usr/local/* /usr/local/ 2>/dev/null || true; mkdir -p /usr/local/lib; cp -rp \$stage_dir/usr/local/lib/* /usr/local/lib/ 2>/dev/null || true"

    rm -rf "\$stage_dir"
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
echo " 全ての SDL3 フルセットのインストールが完了しました！"
echo "========================================================"
