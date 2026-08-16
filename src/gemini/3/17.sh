#!/bin/bash
set -e

# ==============================================================================
# ラズパイ4B(4GB)用 SDL3フルセット全自動インストールスクリプト
# ==============================================================================

BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake ninja-build checkinstall pkg-config curl \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# 最新の安定版タグ（偶数マイナーバージョン 例: release-3.2.0 や release-3.4.14）を取得する関数
get_latest_stable_tag() {
    local repo=$1
    local tag
    tag=$(curl -s "https://api.github.com/repos/${repo}/tags" | \
          grep -oP '"name": "\K[^"]+' | \
          grep -E '^(release-|v)?3\.[02468]\.' | head -n 1)

    if [ -z "$tag" ]; then
        echo "ERROR: ${repo} の最新安定版タグの取得に失敗しました。" >&2
        exit 1
    fi
    echo "$tag"
}

# 各ライブラリのビルド・パッケージングを処理する共通関数
process_library() {
    local repo=$1
    local name=$2
    local pkg_name=$3

    echo "--- ${name} の処理を開始 ---"
    
    # 既にaptに登録されている場合は丸ごとスキップ
    if dpkg -l | grep -q "^ii  ${pkg_name} "; then
        echo "すでに ${pkg_name} はシステムにインストールされているため、完全にスキップします。"
        return 0
    fi

    local tag
    tag=$(get_latest_stable_tag "$repo")
    echo "${name} のターゲットバージョン: ${tag}"

    # dpkg用のバージョン名クレンジング（先頭が必ず数字になるようにする）
    # 例: release-3.4.14 -> 3.4.14, v3.2.0 -> 3.2.0
    local cleaned_version
    cleaned_version=$(echo "$tag" | grep -oP '\d+\.\d+\.\d+.*')
    if [ -z "$cleaned_version" ]; then
        echo "ERROR: バージョン番号の数字部分を抽出できませんでした (${tag})" >&2
        exit 1
    fi
    echo "dpkg用クレンジング済みバージョン: ${cleaned_version}"

    local src_dir="${name}-${tag}"
    cd "$BUILD_DIR"

    # ダウンロードフェーズのキャッシュ判定
    if [ -d "$src_dir" ]; then
        echo "既存のソースコードキャッシュを見つけました。ダウンロードをスキップします: ${src_dir}"
    else
        echo "アーカイブの取得を開始します..."
        # ネットワーク帯域を節約するため、tar.gzをパイプで直接ストリーム展開
        curl -sL "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" | tar -xzf -
        # 解凍されると通常「リポジトリ名-タグ名」というフォルダになる
        # 一部のリポジトリ名やフォルダ名の揺れを吸収するため、直近作成されたフォルダにリネーム
        local real_dir
        real_dir=$(ls -td */ | head -n 1 | sed 's|/||')
        if [ "$real_dir" != "$src_dir" ]; then
            mv "$real_dir" "$src_dir"
        fi
    fi

    cd "$src_dir"

    # ビルド（コンパイル）フェーズのキャッシュ判定
    if [ -d "build" ] && [ -f "build/build.ninja" ] && (ls build/lib${name}*.so* >/dev/null 2>&1 || ls build/lib${name}*.a >/dev/null 2>&1 || ls build/libSDL3*.so* >/dev/null 2>&1); then
        echo "すでにビルド成果物が存在するため、コンパイル（ビルド）をスキップします。"
    else
        echo "ビルド設定およびコンパイルを開始します..."
        mkdir -p build && cd build
        cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
        
        # メモリ超過（RAM溢れ）によるラズパイ4Bのハングアップを防ぐため「-j2（2コア）」を厳格指定
        ninja -j2
        cd ..
    fi

    # checkinstall 隔離パッケージ化フェーズ
    echo "checkinstall用ステージング環境の構築..."
    local stage_dir="/tmp/stage_${pkg_name}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    # 1. まず独立した隔離用フォルダ(DESTDIR)に完璧にインストールさせる
    # これにより、checkinstallの古いフックバグ(CMakeとの衝突)を100%回避する
    DESTDIR="$stage_dir" ninja -C build install

    # checkinstall用のダミー説明ファイルを生成（プロンプト停止を防ぐ）
    echo "${name} built from source via automated script" > description-pak

    # 2. 隔離フォルダの中身をシステムルートへ透過的にマージ（同期）する
    # cpコマンドのディレクトリ存在エラーを防ぐため、tarストリームパイプマージを採用
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${cleaned_version}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        tar -C "${stage_dir}/usr/local" -cf - . \| tar -C /usr/local -xf -

    # ステージング環境のゴミ掃除
    rm -rf "$stage_dir"
    echo "--- ${name} のインストールおよびパッケージ化完了 ---"
}

echo "=== [2/7] SDL3 本体のインストール ==="
process_library "libsdl-org/SDL" "SDL" "sdl3"

# 後続の拡張ライブラリが本体のパスを参照できるようキャッシュ更新
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
echo " 2回目以降の実行はすべて自動で高速スキップされます。"
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
