#!/bin/bash

# エラー発生時にスクリプトを即時終了させる（ただし、個別処理の制御のため局所的に対応）
set -e

# 作業場所のルート設定（削除せず残す）
BASE_WORK_DIR="/tmp/sdl_build"
mkdir -p "$BASE_WORK_DIR"

# 対象のGitHubリポジトリ一覧
# 依存関係（SDL3本体が最優先）を考慮した順序
REPOS=("sdl" "image" "ttf" "mixer" "net")
declare -A REPO_URLS=(
    ["sdl"]="https://github.com/libsdl-org/SDL"
    ["image"]="https://github.com/libsdl-org/SDL_image"
    ["ttf"]="https://github.com/libsdl-org/SDL_ttf"
    ["mixer"]="https://github.com/libsdl-org/SDL_mixer"
    ["net"]="https://github.com/libsdl-org/SDL_net"
)

# ヘルプメッセージの表示関数
show_help() {
    cat << 'EOF'
SDLの最新安定版をインストールする。
GitHubにあるZipからソースコードをダウンロードしてビルドしインストールする。
ラズパイ4B(4GB)で動作させることを想定している。

install    インストールする。
uninstall  アンインストールする。
version    バージョンを表示する。
help       ヘルプを表示する。
EOF
}

# 必要なパッケージ（ビルドツール・各種コーデック）のインストール
install_dependencies() {
    echo "==> ビルドに必要な依存パッケージをインストールしています..."
    sudo apt-get update -y
    sudo apt-get install -y \
        cmake build-essential unzip curl pkg-config \
        libasound2-dev libpulse-dev libaudio-dev libjack-dev \
        libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev \
        libgl1-mesa-dev libglu1-mesa-dev libgles2-mesa-dev libegl1-mesa-dev \
        libdbus-1-dev libibus-1-dev libudev-dev libpipewire-0.3-dev \
        libwayland-dev wayland-protocols libxkbcommon-dev libegl-dev \
        libjpeg-dev libpng-dev libtiff-dev libwebp-dev \
        libfreetype6-dev libfontconfig1-dev \
        libflac-dev libmodplug-dev libvorbis-dev libogg-dev libopus-dev
}

# GitHubから最新の安定版（プレリリースを除く最新タグ）のバージョン値を取得する
get_latest_version() {
    local repo_name=$1
    local url="${REPO_URLS[$repo_name]}"
    # APIのホスト名に変換して最新リリース情報を取得
    local api_url="${url/://github.com\/repos}/releases/latest"
    
    # ネットワークエラー等を考慮し、curlで取得を試みる
    local version
    version=$(curl -s "$api_url" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    # "release-3.4.14" や "prerelease-3.2.0"、"3.4.14" のような形式から数値部分を抽出
    version=$(echo "$version" | sed -E 's/^(release-|prerelease-|v)//')
    
    if [ -z "$version" ]; then
        echo "エラー: $repo_name の最新バージョンを取得できませんでした。" >&2
        exit 1
    fi
    echo "$version"
}

# インストールされている実際のバージョンを取得
get_installed_version() {
    local repo_name=$1
    case "$repo_name" in
        "sdl")
            pkg-config --modversion sdl3 2>/dev/null || echo "未インストール"
            ;;
        "image")
            pkg-config --modversion sdl3-image 2>/dev/null || echo "未インストール"
            ;;
        "ttf")
            pkg-config --modversion sdl3-ttf 2>/dev/null || echo "未インストール"
            ;;
        "mixer")
            pkg-config --modversion sdl3-mixer 2>/dev/null || echo "未インストール"
            ;;
        "net")
            pkg-config --modversion sdl3-net 2>/dev/null || echo "未インストール"
            ;;
    esac
}

# メイン処理：インストール
do_install() {
    install_dependencies

    for repo in "${REPOS[@]}"; do
        echo "--------------------------------------------------"
        echo "==> [$repo] 処理を開始します..."
        
        # 毎回GitHubから最新バージョンを取得
        local version
        version=$(get_latest_version "$repo")
        echo "最新安定バージョン: $version"

        local repo_url="${REPO_URLS[$repo]}"
        local zip_file="${BASE_WORK_DIR}/${repo}-${version}.zip"
        # 各リポジトリの展開後の想定ディレクトリ構造（例: SDL-release-3.4.14 または SDL_image-release-3.4.4 など）
        # GitHubのArchive ZIPを展開すると「リポジトリ名-release-バージョン」形式、もしくは「リポジトリ名-バージョン」になる
        local extract_dir="${BASE_WORK_DIR}/${repo_url##*/}-release-${version}"
        # 万が一release-が付かないタグ名の場合のフォールバック
        local extract_dir_alt="${BASE_WORK_DIR}/${repo_url##*/}-${version}"
        
        # 1. ZIPのダウンロード（既に存在すればスキップ）
        if [ ! -f "$zip_file" ]; then
            local download_url="${repo_url}/archive/refs/tags/release-${version}.zip"
            echo "ダウンロード中: $download_url"
            # release- が付いていないタグの場合もあるため、404なら通常のバージョン名でフォールバック試行
            if ! curl -L -f -o "$zip_file" "$download_url"; then
                download_url="${repo_url}/archive/refs/tags/${version}.zip"
                echo "フォールバックダウンロード中: $download_url"
                curl -L -f -o "$zip_file" "$download_url"
            fi
        else
            echo "ZIPファイルは既に存在します（ダウンロードをスキップ）: $zip_file"
        fi

        # 2. 展開（展開先ディレクトリがなければ展開）
        local target_dir="$extract_dir"
        if [ ! -d "$extract_dir" ] && [ ! -d "$extract_dir_alt" ]; then
            echo "ZIPを展開しています..."
            unzip -q "$zip_file" -d "$BASE_WORK_DIR"
        fi
        
        if [ -d "$extract_dir_alt" ] && [ ! -d "$extract_dir" ]; then
            target_dir="$extract_dir_alt"
        fi

        # 3. ビルドとインストール（作業用buildディレクトリを保持）
        local build_dir="${target_dir}/build_dir"
        mkdir -p "$build_dir"
        cd "$build_dir"

        echo "CMakeの構成を設定しています..."
        # ラズパイ4の4GB環境向けに最適なオプション
        cmake .. -DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=ON -DSDL_STATIC=ON

        echo "コンパイル中 (4コア並列実行)..."
        make -j4

        echo "システムへインストールしています..."
        sudo make install
        
        echo "[$repo] のインストールが完了しました。"
    done

    # 共有ライブラリのキャッシュを更新
    sudo ldconfig
    echo "--------------------------------------------------"
    echo "すべてのSDL3コンポーネントの全自動インストールが完了しました。"
}

# メイン処理：アンインストール
do_uninstall() {
    # 依存関係の下流（サテライト側）から順にアンインストールする
    local reverse_repos=("net" "mixer" "ttf" "image" "sdl")
    
    for repo in "${reverse_repos[@]}"; do
        echo "==> [$repo] アンインストールを試みています..."
        local version
        # 最後にインストールしようとした形跡のあるディレクトリを検索して uninstall を実行
        local repo_url="${REPO_URLS[$repo]}"
        local target_pattern="${BASE_WORK_DIR}/${repo_url##*/}-*"
        
        # 展開されたビルドディレクトリが存在すれば、そこから `make uninstall`
        local uninstalled=false
        for dir in $target_pattern; do
            if [ -d "$dir/build_dir" ]; then
                cd "$dir/build_dir"
                if [ -f Makefile ]; then
                    echo "ディレクトリ $dir/build_dir からアンインストールを実行します。"
                    sudo make uninstall || true
                    uninstalled=true
                fi
            fi
        done
        
        if [ "$uninstalled" = false ]; then
            echo "警告: $repo のビルドディレクトリからアンインストールが実行できませんでした。手動削除が必要です。"
        fi
    done
    
    # 共有ライブラリキャッシュの更新
    sudo ldconfig
    echo "アンインストール処理を終了しました。"
}

# メイン処理：バージョン表示
do_version() {
    local target=${1:-"sdl"}
    
    if [ "$target" = "all" ]; then
        printf "sdl\t%s\n" "$(get_installed_version sdl)"
        printf "image\t%s\n" "$(get_installed_version image)"
        printf "mixer\t%s\n" "$(get_installed_version mixer)"
        printf "net\t%s\n" "$(get_installed_version net)"
        printf "ttf\t%s\n" "$(get_installed_version ttf)"
    else
        get_installed_version "$target"
    fi
}

# サブコマンドの分岐制御
COMMAND=$1
shift || true

case "$COMMAND" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    version)
        do_version "$1"
        ;;
    help|"")
        show_help
        ;;
    *)
        # 想定外のコマンドはすべてヘルプを表示
        show_help
        ;;
esac
