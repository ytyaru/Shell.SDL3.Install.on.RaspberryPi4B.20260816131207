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

# 実システム側に親ディレクトリ群を強制作成（checkinstallの隔離環境エラー対策）
sudo mkdir -p /usr/local/lib/pkgconfig /usr/local/include /usr/local/share

# GitHubから最新の安定版タグ（release-3.偶数.x 等）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
        grep -oP '"name": "\K[^"]+' | \
        grep -E '^(release-3\.[02468]\.|v3\.[02468]\.)' | head -n 1)
    
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の最新安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# 各フェーズ（ダウンロード・ビルド・インストール）を管理・スキップする共通関数
process_sdl_component() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "========================================="
    echo "--- ${name} の処理を開始 ---"
    echo "========================================="
    
    # 1. 既にaptインストール済みかチェック
    if dpkg -l | grep -q "^ii  ${pkg_name} "; then
        echo "${pkg_name} は既にaptシステムにインストールされています。完全にスキップします。"
        return 0
    fi
    
    # 最新の安定タグを取得
    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"
    
    local target_dir="${name}-${tag}"
    cd "$BUILD_DIR"
    
    # 2. ダウンロードフェーズの制御
    if [ -d "$target_dir" ]; then
        echo "既存のソースコードキャッシュを発見しました。ダウンロードをスキップします: ${target_dir}"
    else
        echo "最新安定版アーカイブをダウンロード中..."
        # tar.gzを直接ストリーム展開（古いルーター環境のネットワーク・RAMディスク負荷を最小限に）
        curl -L -s "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" | tar -xzf -
    fi
    
    cd "$target_dir"
    
    # 3. ビルドフェーズの制御
    local need_build=true
    if [ -d "build" ] && [ -f "build/build.ninja" ]; then
        # すでにビルド完了（.aや.soが存在）しているか簡易確認
        if find build -name "*.a" -o -name "*.so*" | grep -q .; then
            echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
            need_build=false
        fi
    fi
    
    if [ "$need_build" = true ]; then
        mkdir -p build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        # RAM4GBが枯渇してハングアップするのを厳格に防ぐため、2コア(-j2)に固定
        ninja -j2
        cd ..
    fi
    
    # 4. ステージングとcheckinstallフェーズ
    echo "checkinstall用の仮インストール環境（ステージング）を作成します..."
    local stage_dir="/tmp/sdl3_stage_${pkg_name}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    
    # CMake/Ninjaを妨害せず完璧にダミー領域にインストールさせる
    DESTDIR="$stage_dir" ninja -C build install
    
    # checkinstall用の自動説明ファイルを流し込む
    echo "${name} library compiled from stable source tag ${tag}" > description-pak
    
    # ステージングのパス構成を維持したまま.debパッケージ化しインストール
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${tag#release-}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        ninja -C build install
        
    echo "${name} のパッケージ化とインストールが完了しました。"
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
echo " 既にコンパイルが完了していたフェーズは全てスキップされました。"
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
