#!/bin/bash
set -e

# ====================================================================
# 設定項目
# ====================================================================
export CONAN_HOME="$HOME/.conan2"
BUILD_DIR="/tmp/sdl3_conan_build"
NUM_CORES=2

echo "=== 1. 必要となるシステムパッケージ（pipx、IME日本語入力、各種開発用ライブラリ）のインストール ==="
sudo apt update
sudo apt install -y     pipx cmake ninja-build build-essential curl jq libxkbcommon-dev     libibus-1.0-dev libfcitx5-dev libwayland-dev libx11-dev     libasound2-dev libpulse-dev libjack-dev libpipewire-0.3-dev     libgl1-mesa-dev libglu1-mesa-dev libegl1-mesa-dev     libextsound-dev libflac-dev libvorbis-dev libmodplug-dev     libmp3lame-dev libmpg123-dev libopus-dev libopusfile-dev     libfreetype-dev libharfbuzz-dev libjpeg-dev libpng-dev     libtiff-dev libwebp-dev

echo "=== 2. pipx を使用した Conan 2.x のインストールと設定 ==="
if ! command -v conan &> /dev/null; then
    pipx install conan
    # 現在のセッションのPATHにpipxのバイナリパスを追加
    export PATH="$HOME/.local/bin:$PATH"
fi

# Conanプロファイルの初期化（未作成の場合のみ）
if [ ! -f "${CONAN_HOME}/profiles/default" ]; then
    conan profile detect --force
fi

# Ninjaジェネレータの使用と並列ジョブ数（2コア制限）をプロファイルに強制適用
conan profile patch-setting tools.build:compiler.executables={"c": "gcc", "cpp": "g++"} default || true
conan profile conf-add tools.build:jobs=${NUM_CORES} default
conan profile conf-add tools.cmake.cmaketoolchain:generator=Ninja default

echo "=== 3. RAMディスク（/tmp）上でのビルド環境構築 ==="
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Conan定義ファイル（conanfile.txt）の生成
# 最新安定版（2026年時点の対応バージョン）をターゲットに設定
cat << 'EOF' > conanfile.txt
[requires]
sdl/3.2.4
sdl_image/3.0.0
sdl_ttf/3.0.0
sdl_mixer/3.0.0
sdl_net/3.0.0

[generators]
CMakeDeps
CMakeToolchain

[options]
sdl/*:wayland=True
sdl/*:x11=True
EOF

echo "=== 4. Conanによる依存関係の解決と順次ビルド・インストール（2コア制限・Ninja） ==="
# --build=missing により、ローカルにバイナリがないパッケージを順次コンパイル
# 完成成果物は $HOME/.conan2 に保管され、一時的なビルドオブジェクトは順次クリーンアップされます
conan install . --build=missing -pr:b=default -pr:h=default

echo "=== 5. RAMディスク内の一時作業ディレクトリをクリーンアップ ==="
cd /tmp
rm -rf "${BUILD_DIR}"

echo "===================================================================="
echo " すべてのSDL3ライブラリのConanパッケージングが完了しました！"
echo " 利用ツール: pipx + Conan 2.x"
echo " 適用条件: /tmpでのビルド（容量死守）、Ninja高速化、2コア制限、IME日本語入力対応"
echo "===================================================================="
