#!/bin/bash
set -e

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git checkinstall pkg-config curl tar \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev ninja-build

# 事前にシステムディレクトリを作成（存在しない場合のための安全策）
sudo mkdir -p /usr/local/bin /usr/local/lib /usr/local/include /usr/local/share /usr/local/lib/pkgconfig

# GitHubから最新の安定版タグ（偶数マイナーバージョン）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/\${repo}/tags" | \
        grep -oP '"name": "\K[^"]+' | \
        grep -E '^(v3\.[02468]\.|release-3\.[02468]\.)' | head -n 1)
    
    if [ -z "$tag" ]; then
        echo "ERROR: \${repo} の最新安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# ビルド・パッケージングを実行する共通関数
build_and_install() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- \${name} の処理を開始 ---"
    
    # 1. 既にaptでインストール済みかチェック
    if dpkg -l | grep -q " \${pkg_name} "; then
        echo "\${pkg_name} は既にaptインストール済みのため、全工程をスキップします。"
        return 0
    fi
    
    cd "$BUILD_DIR"
    
    # 最新安定版タグの取得
    local tag=$(get_latest_stable_tag "$repo")
    echo "\${name} のターゲットバージョン: \${tag}"
    
    # バージョン番号の数字部分のみを抽出 (例: release-3.4.14 -> 3.4.14, v3.2.0 -> 3.2.0)
    local clean_version=$(echo "\${tag}" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "\${clean_version}" ]; then
        echo "ERROR: バージョン番号の抽出に失敗しました (\${tag})" >&2
        exit 1
    fi
    
    local dir_name="\${name}-\${tag}"
    local stage_dir="/tmp/stage_\${pkg_name}"
    
    # 2. ダウンロードチェック
    if [ ! -d "\${dir_name}" ]; then
        echo "アーカイブをダウンロード中..."
        curl -L "https://github.com/\${repo}/archive/refs/tags/\${tag}.tar.gz" | tar -xzf -
    else
        echo "既存のソースコードキャッシュを発見しました。ダウンロードをスキップします: \${dir_name}"
    fi
    
    cd "\${dir_name}"
    
    # 3. ビルドチェック
    if [ -f "build/build.ninja" ] && [ -f "build/lib\${name}.so" -o -f "build/lib\${name}3.so" -o -f "build/libSDL3.so" ]; then
        echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        echo "ビルド設定およびコンパイルを開始します（2コア制限）..."
        rm -rf build
        mkdir build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DSDL_STATIC=OFF
        ninja -j2
        cd ..
    fi
    
    # 4. パッケージ化とインストール
    echo "隔離用ディレクトリに一時インストール（ステージング）します..."
    rm -rf "\${stage_dir}"
    mkdir -p "\${stage_dir}"
    DESTDIR="\${stage_dir}" ninja -C build install
    
    # checkinstall用のダミー説明ファイル作成
    echo "\${name} built from source via automated script" > description-pak
    
    echo "checkinstall を使用して .deb パッケージを作成し、インストールします..."
    # パイプ文字 '|' が引数として誤認されないよう、単一の引数としてシェルスクリプト文字列を渡す
    sudo checkinstall -y \
        --pkgname="\${pkg_name}" \
        --pkgversion="\${clean_version}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="\${pkg_name}" \
        --nodoc \
        sh -c "tar -C \${stage_dir}/usr/local -cf - . | tar -C /usr/local -xf -"
        
    rm -rf "\${stage_dir}"
}

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
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
