#!/bin/bash
set -e

# エラー発生時に詳細を出力
trap 'echo "エラーが発生しました。スクリプトの処理を中断します。ライン: $LINENO"' ERR

# 作業ディレクトリの設定
BUILD_DIR="/tmp/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/7] 必要となる依存パッケージのインストール ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake ninja-build checkinstall pkg-config curl jq \
    libasound2-dev libpulse-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxss-dev libxxf86vm-dev \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
    libdbus-1-dev libibus-1.0-dev libudev-dev libpipewire-0.3-dev \
    libflac-dev libvorbis-dev libmodplug-dev libmp3lame-dev libopus-dev \
    libfreetype6-dev libharfbuzz-dev libfontconfig1-dev

# インストール先ディレクトリの事前作成（checkinstallの仮想パスエラー対策）
sudo mkdir -p /usr/local/lib/pkgconfig
sudo mkdir -p /usr/local/include/SDL3
sudo mkdir -p /usr/local/bin
sudo mkdir -p /usr/local/share/man

# GitHub APIから最新の安定版（偶数マイナー）のRelease Tarball/Zip URLおよびバージョンタグを取得する関数
get_latest_stable_release_info() {
    local repo=$1
    # リリース一覧から「偶数マイナー」かつ「プレリリースでない」最新の安定リリースを抽出
    local release_json=$(curl -s "https://api.github.com/repos/${repo}/releases" | jq -c '[.[] | select(.prerelease==false and (.tag_name | test("^v?3\\.[02468]\\.")))][0]')
    
    if [ -z "$release_json" ] || [ "$release_json" == "null" ]; then
        echo "ERROR: ${repo} の最新安定版リリースの取得に失敗しました。" >&2
        exit 1
    fi
    
    local tag=$(echo "$release_json" | jq -r '.tag_name')
    local url=$(echo "$release_json" | jq -r '.tarball_url')
    
    if [ -z "$tag" ] || [ "$tag" == "null" ] || [ -z "$url" ] || [ "$url" == "null" ]; then
        echo "ERROR: ${repo} のリリースデータ解析に失敗しました。" >&2
        exit 1
    fi
    
    echo "${tag} ${url}"
}

# アーカイブをダウンロード・展開してNinja+checkinstallでビルドする共通関数
download_and_build() {
    local repo=$1
    local name=$2
    local pkg_name=$3
    
    echo "--- ${name} のリリース情報の取得 ---"
    cd "$BUILD_DIR"
    
    # リリース情報（タグとURL）の取得
    local info=$(get_latest_stable_release_info "$repo")
    local tag=$(echo "$info" | cut -d' ' -f1)
    local url=$(echo "$info" | cut -d' ' -f2)
    
    # バージョン番号の整形 (先頭のvやrelease-等を除去)
    local ver_num=$(echo "$tag" | sed -E 's/^[^0-9]*//')
    
    echo "${name} の最新安定バージョン: ${tag}"
    echo "ダウンロードURL: ${url}"
    
    local archive_file="${name}-${tag}.tar.gz"
    local extract_dir="${name}-source"
    
    # 既に該当バージョンのソース展開ディレクトリが存在する場合はダウンロードをスキップ
    if [ -d "$extract_dir" ]; then
        echo "既に対象バージョン ${tag} のソース展開ディレクトリが存在するため、ダウンロードをスキップします。"
        cd "$extract_dir"
    else
        echo "アーカイブをダウンロード中..."
        curl -L -o "$archive_file" "$url"
        
        echo "アーカイブを展開中..."
        mkdir -p "$extract_dir"
        tar -xzf "$archive_file" -C "$extract_dir" --strip-components=1
        rm -f "$archive_file"
        cd "$extract_dir"
    fi
    
    # ビルド設定
    mkdir -p build && cd build
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    
    echo "Ninjaによるビルドを開始 (メモリ保護のため最大2コア制限: -j2)"
    ninja -j2
    
    # checkinstall用のダミー説明ファイル生成
    echo "${name} library compiled from stable release tarball" > description-pak
    
    # checkinstallによるDebianパッケージ化とインストール
    echo "checkinstall を使用して .deb パッケージを作成しインストールします..."
    sudo checkinstall -y \
        --pkgname="${pkg_name}" \
        --pkgversion="${ver_num}" \
        --pkgrelease="1" \
        --pkggroup="libs" \
        --maintainer="raspberrypi-user" \
        --provides="${pkg_name}" \
        --nodoc \
        ninja install
}

echo "=== [2/7] SDL3 本体のインストール ==="
download_and_build "libsdl-org/SDL" "SDL" "sdl3"
sudo ldconfig

echo "=== [3/7] SDL3_image のインストール ==="
download_and_build "libsdl-org/SDL_image" "SDL_image" "sdl3-image"

echo "=== [4/7] SDL3_ttf のインストール ==="
download_and_build "libsdl-org/SDL_ttf" "SDL_ttf" "sdl3-ttf"

echo "=== [5/7] SDL3_mixer のインストール ==="
download_and_build "libsdl-org/SDL_mixer" "SDL_mixer" "sdl3-mixer"

echo "=== [6/7] SDL3_net のインストール ==="
download_and_build "libsdl-org/SDL_net" "SDL_net" "sdl3-net"

echo "=== [7/7] システム全体の共有ライブラリキャッシュ更新 ==="
sudo ldconfig

echo "========================================================"
echo " 全ての SDL3 フルセットのインストールが完了しました！"
echo " 2コア制限のNinjaビルドにより安全に最速で構築されました。"
echo " apt list --installed | grep sdl3 で確認できます。"
echo "========================================================"
