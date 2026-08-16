#!/bin/bash
set -e

# 作業ディレクトリの設定
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

# 実システム側に、checkinstallのコピー先となる親ディレクトリを確実に強制作成
sudo mkdir -p /usr/local/lib/pkgconfig
sudo mkdir -p /usr/local/include/SDL3
sudo mkdir -p /usr/local/share/licenses

# GitHubのタグ一覧から、最新の偶数安定版（例: release-3.2.x や v3.2.x）のタグ名を取得する関数
get_stable_tag() {
    local repo=$1
    local tag=""
    
    # 1. release-3.偶数.x 形式を最優先で検索
    tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^release-3\.[02468]\.' | head -n 1)
    
    # 2. 見つからない場合は v3.偶数.x や 3.偶数.x 形式を検索
    if [ -z "$tag" ]; then
        tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | grep -oP '"name": "\K[^"]+' | grep -E '^(v)?3\.[02468]\.' | head -n 1)
    fi
    
    # 3. それでも見つからない場合はエラー終了
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# ダウンロード、ビルド、インストールを行う共通関数
process_library() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} のリリース情報の取得 ---"
    cd "$BUILD_DIR"
    
    local tag=$(get_stable_tag "$repo")
    echo "${name} の最新安定バージョン: ${tag}"
    
    # バージョン名からプレフィックス（release- や v）を削って純粋な数値にする
    local version_num=$(echo "$tag" | sed -E 's/^(release-|preview-|v)//')
    
    local archive_file="${name}-${tag}.tar.gz"
    local extract_dir="${name}-${version_num}"
    
    # すでに展開済みの同バージョンディレクトリが存在する場合はダウンロードをスキップ
    if [ -d "$extract_dir" ]; then
        echo "既に ${extract_dir} が存在するため、ダウンロードをスキップしてビルドへ移行します。"
        cd "$extract_dir"
    else
        local download_url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
        echo "アーカイブをダウンロード中: ${download_url}"
        
        # ネットワーク負荷と速度を考慮し、tar.gzを直接ストリーム展開
        mkdir -p "$extract_dir"
        curl -sL "$download_url" | tar -xzf - --strip-components=1 -C "$extract_dir"
        cd "$extract_dir"
    fi
    
    # ビルドディレクトリの作成と移動
    mkdir -p build && cd build
    
    # CMakeの実行 (Ninjaジェネレータを使用)
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    
    # ラズパイ4Bのメモリ制限を考慮し、確実に2コア制限（-j2）で超高速並列ビルド
    ninja -j2
    
    # checkinstall用のダミー説明ファイルを生成して対話プロンプトを完全回避
    echo "${name} library installed via checkinstall" > description-pak
    
    # checkinstallによるDebianパッケージ化とインストール
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${version_num}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        ninja install
}

echo "=== [2/7] SDL3 本体のインストール ==="
process_library "libsdl-org/SDL" "SDL" "sdl3"
sudo ldconfig

echo "=== [3/7] SDL3_image のインストール ==="
process_library "libsdl-org/SDL_image" "SDL_image" "sdl3-image"

echo "=== [4/7] SDL3_ttf のインストール ==="
process_library "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"

echo "=== [5/7] SDL3_mixer のインストール ==="
process_library "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"

echo "=== [6/7] SDL3_net のインストール ==="
process_library "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

echo "=== [7/7] システム全体の共有ライブラリキャッシュ更新 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 フルセットのインストールが完了しました！"
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
