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

# 最新の安定版タグ（偶数マイナーバージョン）をGitHub APIから取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^(v3\.[02468]\.|release-3\.[02468]\.)' | head -n 1)
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の安定版タグ情報の取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# 各ライブラリのビルド・パッケージング共通処理
process_sdl_component() {
    local repo=$1
    local name=$2
    local pkg_name=$3

    echo "--- ${name} の処理を開始 ---"
    cd "$BUILD_DIR"

    # aptに既に登録されている場合は、全工程をスキップ
    if dpkg -l | grep -q "^ii  ${pkg_name} "; then
        echo "${pkg_name} は既にインストールされています。スキップします。"
        return 0
    fi

    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"

    local dir_name="${name}-${tag#v}"
    local stage_dir="/tmp/stage_${pkg_name}"

    # ダウンロードスキップ判定
    if [ ! -d "$dir_name" ]; then
        echo "アーカイブをダウンロード中..."
        curl -L -s "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" | tar -xzf -
    else
        echo "既存のソースコードキャッシュを見つけました。ダウンロードをスキップします: ${dir_name}"
    fi

    cd "$dir_name"

    # ビルドスキップ判定（ビルド成果物チェック）
    if [ -d "build" ] && ([ -f "build/libSDL3.so" ] || [ -f "build/libSDL3_image.so" ] || [ -f "build/libSDL3_ttf.so" ] || [ -f "build/libSDL3_mixer.so" ] || [ -f "build/libSDL3_net.so" ]); then
        echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        echo "CMakeによる設定とNinjaビルドを開始します（メモリ超過防止のため2コア制限）..."
        mkdir -p build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        ninja -j2
        cd ..
    fi

    # checkinstall用のダミー説明文を配置
    echo "${name} built from source via automated script" > description-pak

    # 既存のステージングディレクトリをクリーンアップして再作成
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    # CMake/Ninja単独で安全にステージング環境へインストール（checkinstallと競合させない）
    DESTDIR="$stage_dir" ninja -C build install

    # checkinstallを実行。cpの競合を回避するため、tarパイプマージ方式で実環境にマージしつつdebパッケージ化
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${tag#v}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        sh -c "tar -C ${stage_dir}/usr/local -cf - . | tar -C /usr/local -xf -"

    # 後始末
    rm -rf "$stage_dir"
}

echo "=== [2/7] SDL3 本体のインストール ==="
process_sdl_component "libsdl-org/SDL" "SDL" "sdl3"
sudo ldconfig

echo "=== [3/7] SDL3_image のインストール ==="
process_sdl_component "libsdl-org/SDL_image" "SDL_image" "sdl3-image"

echo "=== [4/7] SDL3_ttf のインストール ==="
process_sdl_component "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"

echo "=== [5/7] SDL3_mixer のインストール ==="
process_sdl_component "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"

echo "=== [6/7] SDL3_net のインストール ==="
process_sdl_component "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

echo "=== [7/7] システム全体の共有ライブラリキャッシュ更新 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 フルセットのインストールが完了しました！"
echo " pkg-config コマンドでのコンパイルが可能です。"
echo "========================================================"
