#!/bin/bash
# ==============================================================================
# Raspberry Pi 4B (4GB) 用 SDL3 + 拡張ライブラリ 全自動ビルド・インストールスクリプト
# ==============================================================================
# [特徴]
# 1. 最新安定版 (stable) のソースコードをGitHubから自動取得してビルドします。
# 2. IME日本語入力に対応するため、Fcitx5 / IBus 開発用パッケージを事前に導入します。
# 3. /tmp (2GB RAMディスク) 上にビルド用の一時ワークスペースを作成します。
# 4. メモリ不足によるフリーズを防ぐため、コンパイル時の使用コア数を「2コア」に制限します。
# 5. vcpkgを使わず、Linuxの標準的な共有ライブラリ(ldconfig管理)として正確に配置・管理します。
# ==============================================================================

set -euo pipefail

# カラー定義
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0;3m' # No Color
YELLOW='\033[1;33m'

log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

error_log() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

# 1. 動作環境チェック
log "1. 動作環境の確認中..."
if [ "$EUID" -ne 0 ]; then
    error_log "このスクリプトは sudo または root 権限で実行する必要があります。"
    echo "実行例: sudo bash $0"
    exit 1
fi

# /tmp の空き容量チェック
TMP_FREE_KB=$(df /tmp | awk 'NR==2 {print $4}')
TMP_FREE_GB=$((TMP_FREE_KB / 1024 / 1024))
if [ "$TMP_FREE_GB" -lt 1 ]; then
    echo -e "${YELLOW}[WARNING] /tmp の空き容量が少なく、ビルド中に容量不足になる可能性があります (${TMP_FREE_GB}GB 空き)。${NC}"
    echo "必要に応じて、一時的に /tmp のサイズを拡張するか、通常のディレクトリでの実行を検討してください。"
fi

# 2. 依存パッケージのインストール (IME対応、オーディオ、画像、フォント、ビルドツール)
log "2. システムパッケージの更新および依存ライブラリのインストール..."
apt-get update -y

apt-get install -y \
    build-essential \
    cmake \
    git \
    ninja-build \
    pkg-config \
    libasound2-dev \
    libpulse-dev \
    libaudio-dev \
    libjack-dev \
    libsndio-dev \
    libx11-dev \
    libxext-dev \
    libxrandr-dev \
    libxcursor-dev \
    libxfixes-dev \
    libxi-dev \
    libxss-dev \
    libxkbcommon-dev \
    libdrm-dev \
    libgbm-dev \
    libudev-dev \
    libdbus-1-dev \
    libvulkan-dev \
    libegl1-mesa-dev \
    libgl1-mesa-dev \
    libgles2-mesa-dev \
    libwayland-dev \
    wayland-protocols \
    libdecor-0-dev \
    libpipewire-0.3-dev \
    libfcitx5client-dev \
    libibus-1.0-dev \
    libpng-dev \
    libjpeg-dev \
    libtiff-dev \
    libwebp-dev \
    libfreetype-dev \
    libharfbuzz-dev \
    libfluidsandbox-dev \
    libmikmod-dev \
    libmodplug-dev \
    libvorbis-dev \
    libflac-dev \
    libopus-dev \
    libmpg123-dev

# 3. ビルド環境のセットアップ (/tmp)
WORK_DIR="/tmp/sdl3_build_workspace"
log "3. ビルド用ワークスペースの作成: ${WORK_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 使用コア数の制限 (メモリ不足対策として2コアを指定)
CPU_CORES=2
log "コンパイル並列数: ${CPU_CORES} コアに制限します。"

# 各コンポーネントのGitリポジトリURL
SDL_CORE_URL="https://github.com/libsdl-org/SDL.git"
SDL_IMAGE_URL="https://github.com/libsdl-org/SDL_image.git"
SDL_TTF_URL="https://github.com/libsdl-org/SDL_ttf.git"
SDL_MIXER_URL="https://github.com/libsdl-org/SDL_mixer.git"
SDL_NET_URL="https://github.com/libsdl-org/SDL_net.git"

# 最新安定リリースタグを取得してクローン・ビルド・インストールする関数
build_and_install() {
    local repo_url=$1
    local name=$2
    local extra_cmake_opts=${3:-""}

    log "--------------------------------------------------"
    log "${name} の最新安定版タグを取得中..."
    log "--------------------------------------------------"
    
    # クローン先ディレクトリ
    local clone_dir="${WORK_DIR}/${name}"
    git clone "${repo_url}" "${clone_dir}"
    cd "${clone_dir}"

    # 最新の安定リリースタグ (プレリリース/RC/previewを除外) を検索
    # SDL3はリリースモデルが確立される過程にあるため、無ければ最新タグ、それも無ければmainを使用
    local latest_tag=$(git tag -l | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
    
    if [ -z "${latest_tag}" ]; then
        # 3.0.0などのプレリリース期対応を含めたフォールバック検索
        latest_tag=$(git tag -l | grep -E 'release-|v[0-9]' | sort -V | tail -n 1 || true)
    fi

    if [ -n "${latest_tag}" ]; then
        log "対象バージョンタグ: ${latest_tag} をチェックアウトします。"
        git checkout "${latest_tag}"
    else
        log "安定版タグが見つからないため、デフォルトブランチの最新コミットを使用します。"
    fi

    # ビルドとインストール
    mkdir -p build && cd build
    cmake .. -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        ${extra_cmake_opts}

    log "${name} をビルド中 (2コア制限)..."
    ninja -j ${CPU_CORES}
    
    log "${name} をインストール中..."
    ninja install
}

# 4. 各コンポーネントの順次ビルド
# IME対応(Fcitx5/IBus)はSDL本体のCMake自動検出に含まれます
build_and_install "${SDL_CORE_URL}" "SDL3" "-DSDL_ENABLE_IME=ON"
build_and_install "${SDL_IMAGE_URL}" "SDL3_image" "-DSDLIMAGE_VENDORED=OFF"
build_and_install "${SDL_TTF_URL}" "SDL3_ttf" "-DSDLTTF_VENDORED=OFF"
build_and_install "${SDL_MIXER_URL}" "SDL3_mixer" "-DSDLMIXER_VENDORED=OFF"
build_and_install "${SDL_NET_URL}" "SDL3_net" ""

# 5. 共有ライブラリキャッシュの更新
log "5. 共有ライブラリ・システムの更新 (ldconfig)..."
ldconfig

# 6. 後片付け
log "6. 一時ビルドファイルのクリーンアップ..."
rm -rf "${WORK_DIR}"

log "=================================================="
log " SDL3 および拡張ライブラリのインストールが完了しました！"
log "=================================================="
log "インストール先: /usr/local/lib / /usr/local/include/SDL3"
log "バージョン確認例: pkg-config --modversion sdl3"
log "=================================================="
