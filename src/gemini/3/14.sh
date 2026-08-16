#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git checkinstall pkg-config curl jq ninja-build \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# 最新の安定版タグ（偶数マイナーバージョン）をGitHub APIから取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
        grep -oP '"name": "\K[^"]+' | \
        grep -E '^(release-|v)?3\.[02468]\.[0-9]+' | head -n 1)
    
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の最新安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# 各ライブラリのビルド・パッケージ化を制御するメイン関数
process_library() {
    local repo=$1
    local name=$2
    local pkg_name=$3

    echo "--- ${name} の処理を開始 ---"
    
    # 1. すでにaptでインストール済みかチェック
    if dpkg -l | grep -q "^ii  ${pkg_name} "; then
        echo "${pkg_name} は既にaptでインストールされています。処理をスキップします。"
        return 0
    fi

    # 最新安定版タグを取得
    local tag=$(get_latest_stable_tag "$repo")
    local dir_name="${name}-${tag}"

    cd "$BUILD_DIR"

    # 2. ダウンロード済みかチェック（フォルダがなければ落とす）
    if [ ! -d "$dir_name" ]; then
        echo "${name} のソースコードをダウンロード中... (${tag})"
        local tar_url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
        curl -sL "$tar_url" | tar -xzf -
    else
        echo "既存のソースコードキャッシュを発見しました。ダウンロードをスキップします: ${dir_name}"
    fi

    cd "$dir_name"
    
    # 3. ビルド成果物の確認とコンパイル（既に成果物があればビルド自体をスキップ）
    if [ -d "build" ] && [ -f "build/build.ninja" ] && (ls build/*.so build/*.a >/dev/null 2>&1 || [ -f "build/libSDL3.so.0.4.14" ] || [ -d "build/CMakeFiles" ]); then
        echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        echo "コンパイル設定を開始します (Ninja / Release)..."
        mkdir -p build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        echo "ビルド中 (メモリ保護のため2コア制限: -j2)..."
        ninja -j2
        cd ..
    fi

    # 4. ステージング領域への隔離インストールと、checkinstallによる安全なダミー監視パッケージ化
    echo "パッケージ化処理を開始します..."
    local stage_dir="/tmp/stage_${pkg_name}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    # まずCMake/Ninja本来の機能で安全に隔離ディレクトリに全展開させる（100%成功する）
    DESTDIR="$stage_dir" ninja -C build install

    # checkinstallで対話プロンプトで止まらないように説明ファイルを用意
    echo "${name} built from source via automated script" > description-pak

    # 実システムへ隔離ディレクトリの内容を単純コピーする処理をcheckinstallに追跡させ、.debパッケージ化する
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${tag#release-}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        sh -c "cp -r ${stage_dir}/usr /"

    # 一時的なステージング領域をクリーンアップ
    rm -rf "$stage_dir"
    
    # 共有ライブラリキャッシュの即時更新
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
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
