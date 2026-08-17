#!/bin/bash
set -e

# 作業場所のルート設定
BASE_DIR=".com/tmp"
WORK_DIR="${BASE_DIR}/sdl3_build"
mkdir -p "${WORK_DIR}"

# GitHubリポジトリURLの動的構築 (Geminiドメイン破綻対策)
make_repo_url() {
    local base="https://github.com"
    local user="libsdl-org"
    echo "${base}/${user}/$1"
}

# 依存パッケージの一覧
DEPENDENCIES=(
    cmake build-essential libasound2-dev libpulse-dev libaudio-dev libjack-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev \
    libxss-dev libxkbcommon-dev libwayland-dev libegl1-mesa-dev libgl1-mesa-dev \
    libgles2-mesa-dev libdbus-1-dev libibus-1.0-dev libfcitx5-dev libudev-dev \
    libpipewire-0.3-dev libsndio-dev libsamplerate0-dev libvulkan-dev \
    libpng-dev libjpeg-dev libwebp-dev libtiff5-dev \
    libfontconfig1-dev libfreetype6-dev \
    libmodplug-dev libvorbis-dev libogg-dev libflac-dev libmpg123-dev libopus-dev
)

# ヘルプ表示関数
show_help() {
    echo "SDLの最新安定版をインストールする。"
    echo "GitHubにあるZipからソースコードをダウンロードしてビルドしインストールする。"
    echo "ラズパイ4B(4GB)で動作させることを想定している。"
    echo ""
    echo "install    インストールする。"
    echo "uninstall  アンインストールする。"
    echo "version    バージョンを表示する。"
    echo "help       ヘルプを表示する。"
}

# 依存ライブラリのインストール
install_dependencies() {
    echo "=== 依存ライブラリをインストールしています ==="
    sudo apt-get update
    sudo apt-get install -y "${DEPENDENCIES[@]}"
}

# 最新の安定版タグ（リリースバージョン）を取得する関数
get_latest_version() {
    local repo_name=$1
    local repo_url=$(make_repo_url "${repo_name}")
    # tagsページから最新のリリースバージョンを取得 (例: release-3.2.0 や release-2.30.0 など、または v3.2.0、SDL3では preview-3.1.x や release-3.x.x)
    # SDL3系は最新が3.x系。安定版は偶数マイナー(またはプレビュー版を除外)
    # ここでは、GitHubのAPI or curlでtagsから最新のプレビューを含まない安定版を取得
    local version=$(curl -sL "${repo_url}/tags" | grep -oE 'release-[0-9]+\.[0-9]+\.[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | sed -E 's/(release-|v)//')
    if [ -z "$version" ]; then
        # 取得に失敗した場合のフォールバック(一般的な最新安定版プレースホルダ)
        if [ "$repo_name" = "SDL" ]; then version="3.4.14"; fi
        if [ "$repo_name" = "SDL_image" ]; then version="3.4.4"; fi
        if [ "$repo_name" = "SDL_mixer" ]; then version="3.2.4"; fi
        if [ "$repo_name" = "SDL_net" ]; then version="3.2.0"; fi
        if [ "$repo_name" = "SDL_ttf" ]; then version="3.2.2"; fi
    fi
    echo "$version"
}

# パッケージのビルド・インストール（共通処理：単一責任）
build_and_install_package() {
    local repo_name=$1
    local version=$2
    local zip_file="${WORK_DIR}/${repo_name}-${version}.zip"
    local extract_dir="${WORK_DIR}/${repo_name}-release-${version}"
    
    if [ "$repo_name" = "SDL" ]; then
        extract_dir="${WORK_DIR}/${repo_name}-release-${version}"
    fi

    echo "=== ${repo_name} (Ver: ${version}) の処理中 ==="

    # 1. ダウンロードのスキップ判定
    if [ ! -f "${zip_file}" ]; then
        local repo_url=$(make_repo_url "${repo_name}")
        local download_url="${repo_url}/archive/refs/tags/release-${version}.zip"
        echo "ダウンロード中: ${download_url}"
        curl -L "${download_url}" -o "${zip_file}" || {
            # リトライ：release- がつかないタグパターンの場合
            download_url="${repo_url}/archive/refs/tags/v${version}.zip"
            curl -L "${download_url}" -o "${zip_file}"
        }
    else
        echo "ZIPファイルは既に存在します。ダウンロードをスキップします。"
    fi

    # 2. 展開のスキップ判定
    if [ ! -d "${extract_dir}" ]; then
        echo "展開中: ${zip_file}"
        unzip -q "${zip_file}" -d "${WORK_DIR}" || {
            # 展開先ディレクトリ名が想定と異なるケースへの対応
            local base_zip_name=$(basename "${zip_file}" .zip)
            extract_dir="${WORK_DIR}/${base_zip_name}"
        }
    else
        echo "ソースコードは既に展開されています。"
    fi

    # 実際の展開先ディレクトリの自動検出
    local real_dir=$(find "${WORK_DIR}" -maxdepth 1 -type d -name "${repo_name}-*" | head -n 1)
    if [ -d "${real_dir}" ]; then
        extract_dir="${real_dir}"
    fi

    # 3. ビルドとインストール
    local build_dir="${extract_dir}/build"
    if [ -f "${build_dir}/Makefile" ] || [ -f "${build_dir}/build.ninja" ]; then
        if [ -f "${build_dir}/install_manifest.txt" ]; then
            echo "既にビルドおよびインストールが完了しているため、ビルドをスキップします。"
            return 0
        fi
    fi

    mkdir -p "${build_dir}"
    cd "${build_dir}"
    echo "CMake 設定中..."
    cmake .. -DCMAKE_BUILD_TYPE=Release -DSDL_STATIC=OFF

    echo "ビルド中 (2コア使用)..."
    make -j2

    echo "インストール中..."
    sudo make install
    sudo ldconfig
}

# パッケージのアンインストール処理
uninstall_package() {
    local repo_name=$1
    # インストールしたディレクトリが残っていれば Makefile から uninstall、無ければ pkg-config からファイルを追う
    local real_dir=$(find "${WORK_DIR}" -maxdepth 1 -type d -name "${repo_name}-*" | head -n 1 || echo "")
    if [ -d "${real_dir}/build" ]; then
        cd "${real_dir}/build"
        echo "${repo_name} をアンインストールしています..."
        sudo make uninstall || true
    else
        echo "${repo_name} のビルドディレクトリが見つかりません。手動、または個別削除を試みます。"
    fi
}

# バージョン取得関数（インストール済み）
get_installed_version() {
    local pkg_name=$1
    pkg-config --modversion "${pkg_name}" 2>/dev/null || echo "未インストール"
}

# コマンド判定
case "$1" in
    install)
        install_dependencies
        
        # 毎回実行時にGitHubから最新安定版バージョンを取得
        SDL_VER=$(get_latest_version "SDL")
        IMAGE_VER=$(get_latest_version "SDL_image")
        TTF_VER=$(get_latest_version "SDL_ttf")
        MIXER_VER=$(get_latest_version "SDL_mixer")
        NET_VER=$(get_latest_version "SDL_net")

        # 順序：SDL3本体が最初、その後に拡張ライブラリ
        build_and_install_package "SDL" "${SDL_VER}"
        build_and_install_package "SDL_image" "${IMAGE_VER}"
        build_and_install_package "SDL_ttf" "${TTF_VER}"
        build_and_install_package "SDL_mixer" "${MIXER_VER}"
        build_and_install_package "SDL_net" "${NET_VER}"
        
        echo "=== 全ての SDL3 パッケージのインストールが完了しました ==="
        ;;
        
    uninstall)
        uninstall_package "SDL_net"
        uninstall_package "SDL_mixer"
        uninstall_package "SDL_ttf"
        uninstall_package "SDL_image"
        uninstall_package "SDL"
        echo "=== 全ての SDL3 パッケージのアンインストールが完了しました ==="
        ;;
        
    version)
        case "$2" in
            image) get_installed_version "sdl3-image" ;;
            mixer) get_installed_version "sdl3-mixer" ;;
            net)   get_installed_version "sdl3-net" ;;
            ttf)   get_installed_version "sdl3-ttf" ;;
            all)
                echo -e "sdl\t$(get_installed_version 'sdl3')"
                echo -e "image\t$(get_installed_version 'sdl3-image')"
                echo -e "mixer\t$(get_installed_version 'sdl3-mixer')"
                echo -e "net\t$(get_installed_version 'sdl3-net')"
                echo -e "ttf\t$(get_installed_version 'sdl3-ttf')"
                ;;
            *)
                if [ -z "$2" ]; then
                    get_installed_version "sdl3"
                else
                    show_help
                fi
                ;;
        esac
        ;;
        
    help|"")
        show_help
        ;;
        
    *)
        show_help
        ;;
esac
