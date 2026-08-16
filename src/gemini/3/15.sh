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

# 最新の安定版タグを取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
        grep -oP '"name": "\K[^"]+' | \
        grep -E '^(release-|v)?3\.[02468]\.[0-9]+' | head -n 1)
    
    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# 処理メイン関数
process_library() {
    local repo=$1
    local name=$2
    local pkg_name=$3

    echo "--- ${name} の処理を開始 ---"
    cd "$BUILD_DIR"

    # タグの取得
    local tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"

    # 展開先ディレクトリ名の決定
    local dir_name="${name}-${tag}"
    if [[ "$tag" != v* && "$tag" != release-* ]]; then
        dir_name="${name}-${tag}"
    fi
    
    # 実際の展開先を特定するための工夫（GitHubのアーカイブ展開時の命名規則に対応）
    # 通常は リポジトリ名-タグ名（先頭のvやrelease-が残るか消えるかはリポジトリによる）
    # 安全のため、まずはダウンロード・展開ロジックを通す
    
    local target_dir=""
    
    # すでに展開済みディレクトリがあるか確認
    if [ -d "${name}-${tag}" ]; then
        target_dir="${name}-${tag}"
    elif [ -d "${name}-${tag#v}" ]; then
        target_dir="${name}-${tag#v}"
    elif [ -d "${name}-${tag#release-}" ]; then
        target_dir="${name}-${tag#release-}"
    elif [ -d "${name}" ]; then
        target_dir="${name}"
    fi

    if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
        echo "既存のソースコードキャッシュを発見しました。ダウンロードをスキップします: $target_dir"
        cd "$target_dir"
    else
        echo "アーカイブをダウンロード中..."
        local url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
        curl -sL "$url" -o "${name}-${tag}.tar.gz"
        tar -xzf "${name}-${tag}.tar.gz"
        rm "${name}-${tag}.tar.gz"
        
        # 展開されたディレクトリ名を取得
        if [ -d "${name}-${tag}" ]; then target_dir="${name}-${tag}"
        elif [ -d "${name}-${tag#v}" ]; then target_dir="${name}-${tag#v}"
        elif [ -d "${name}-${tag#release-}" ]; then target_dir="${name}-${tag#release-}"
        else
            echo "ERROR: 展開されたディレクトリの特定に失敗しました。" >&2
            exit 1
        fi
        cd "$target_dir"
    fi

    # ビルドディレクトリの作成
    mkdir -p build
    
    # すでにビルド（バイナリ生成）が終わっているか判定
    # 主要なライブラリファイル、または ninja のビルド完了ログをチェック
    if [ -f "build/build.ninja" ] && ( ls build/lib${name}*.so* >/dev/null 2>&1 || ls build/libSDL3*.so* >/dev/null 2>&1 || [ -f "build/libSDL3_test.a" ] ); then
        echo "既にビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        echo "ビルド設定を生成中 (Ninja) ..."
        cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        echo "コンパイル開始 (2コア制限) ..."
        ninja -j2
        cd ..
    fi

    # ステージングとcheckinstallによるパッケージ化
    echo "ステージング環境へ擬似インストール中..."
    local stage_dir="/tmp/stage_${pkg_name}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    
    DESTDIR="$stage_dir" ninja -C build install

    echo "checkinstall を使って apt 管理パッケージ (.deb) を作成・インストール中..."
    # 説明ファイルの作成
    echo "${name} built from source via automated script" > description-pak

    # checkinstallにシステムのディレクトリ構造を汚させず、
    # 隔離環境から安全にマージする超単純なコマンドを監視させる。
    # 末尾の「/.」により、既存の /usr/local を再作成しようとせず中身だけを安全にマージします。
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${tag#v}" \
        --pkgversion="${pkgversion#release-}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        sh -c "mkdir -p /usr/local && cp -a ${stage_dir}/usr/local/. /usr/local/"

    # 後片付け
    rm -rf "$stage_dir"
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
echo " pkg-config --cflags --libs sdl3 ... が使用可能です。"
echo "========================================================"
