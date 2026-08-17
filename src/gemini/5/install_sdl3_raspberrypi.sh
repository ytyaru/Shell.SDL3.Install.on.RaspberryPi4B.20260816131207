#!/bin/bash
# ==============================================================================
# ラズベリーパイ4B (4GB) 向け SDL3 + 拡張ライブラリ 全自動ビルド・インストールスクリプト
# ==============================================================================
# [特徴]
# 1. 2GBのRAMディスク（/tmp/sdl3_build）を作成し、SDカードの摩耗を防ぎつつ高速ビルド
# 2. メモリ不足（OOM）を防ぐため、コンパイル時の使用コア数を「2」に制限
# 3. ibus および fcitx5 開発用ヘッダーを自動検出させ、IME日本語入力を有効化
# 4. vcpkgを使わず、最新安定版のソースコードからラズパイ環境に最適化してビルド
# ==============================================================================

set -euo pipefail

# 1. 各種設定パラメータ
BUILD_DIR="/tmp/sdl3_build"
INSTALL_PREFIX="/usr/local"
CPU_CORES=2

# SDL3 各コンポーネントのバージョン（2026年時点の安定版）
SDL_VER="3.2.0"
SDL_IMAGE_VER="3.0.0"
SDL_TTF_VER="3.1.0"
SDL_MIXER_VER="3.0.0"
SDL_NET_VER="3.0.0"

echo "=============================================================================="
echo " SDL3 全自動ビルドを開始します（ラズパイ4B 4GB向け）"
echo "=============================================================================="

# 2. 必要な依存パッケージのインストール（IME関連、各種メディアデコーダ含む）
echo "--> 依存パッケージのインストール..."
sudo apt-get update
sudo apt-get install -y \
    cmake build-essential ninja-build pkg-config git \
    libasound2-dev libpulse-dev libaudio-dev libjack-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev libdrm-dev \
    libdbus-1-dev libibus-1.0-dev libfcitx5client-dev \
    libfreetype-dev libharfbuzz-dev libfontconfig1-dev \
    libflac-dev libmodplug-dev libvorbis-dev libogg-dev libopus-dev libwavpack-dev \
    libjpeg-dev libpng-dev libtiff-dev libwebp-dev

# 3. RAMディスク（tmpfs）のセットアップ
echo "--> RAMディスク（tmpfs）の作成: ${BUILD_DIR}"
if [ -d "${BUILD_DIR}" ]; then
    echo "既存のビルドディレクトリをクリーンアップします..."
    sudo umount "${BUILD_DIR}" 2>/dev/null || true
    rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"
# 4GBのメモリのうち、ビルド作業用に2GBをtmpfsとして割り当て
sudo mount -t tmpfs -o size=2G tmpfs "${BUILD_DIR}"
sudo chown "$(id -u):$(id -g)" "${BUILD_DIR}"

cd "${BUILD_DIR}"

# --- ビルド共通関数の定義 ---
build_and_install() {
    local name=$1
    local version=$2
    local repo_url=$3
    local extra_cmake_opts=$4

    echo "------------------------------------------------------------------------------"
    echo " ${name} (v${version}) のビルドを開始します"
    echo "------------------------------------------------------------------------------"

    # ソースコードの取得（シャロークローンで最速化）
    git clone --depth 1 --branch "release-${version}" "${repo_url}" "${name}"
    cd "${name}"

    # ビルド設定
    mkdir build && cd build
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
        -DBUILD_SHARED_LIBS=ON \
        ${extra_cmake_opts}

    # 2コア制限でのビルドおよびインストール
    cmake --build . -j${CPU_CORES}
    sudo cmake --install .

    cd "${BUILD_DIR}"
}

# 4. 各コンポーネントの順次ビルド

# SDL3 本体 (IME対応のためにWayland/X11およびIBus/Fcitxを有効化)
build_and_install "SDL" "${SDL_VER}" "https://github.com/libsdl-org/SDL.git" \
    "-DSDL_WAYLAND=ON -DSDL_X11=ON -DSDL_IBUS=ON -DSDL_FCITX=ON"

# システムにインストールしたSDL3を認識させる
sudo ldconfig

# SDL_image (PNG, JPEG, TIFF, WebP 対応)
build_and_install "SDL_image" "${SDL_IMAGE_VER}" "https://github.com/libsdl-org/SDL_image.git" \
    "-DSDLIMAGE_VENDORED=OFF"

# SDL_ttf (FreeType2, HarfBuzz を使用した日本語フォント描画)
build_and_install "SDL_ttf" "${SDL_TTF_VER}" "https://github.com/libsdl-org/SDL_ttf.git" \
    "-DSDLTTF_VENDORED=OFF"

# SDL_mixer (各種オーディオコーデックの有効化)
build_and_install "SDL_mixer" "${SDL_MIXER_VER}" "https://github.com/libsdl-org/SDL_mixer.git" \
    "-DSDLMIXER_VENDORED=OFF"

# SDL_net (ネットワーク拡張)
build_and_install "SDL_net" "${SDL_NET_VER}" "https://github.com/libsdl-org/SDL_net.git" \
    ""

# 5. 後処理
echo "------------------------------------------------------------------------------"
echo "--> 共有ライブラリキャッシュの最終更新..."
sudo ldconfig

echo "--> RAMディスクのアンマウントとクリーンアップ..."
cd /tmp
sudo umount "${BUILD_DIR}"
rm -rf "${BUILD_DIR}"

echo "=============================================================================="
echo " すべての SDL3 コンポーネントのインストールが正常に完了しました！"
echo " インストール先: ${INSTALL_PREFIX}"
echo "=============================================================================="
