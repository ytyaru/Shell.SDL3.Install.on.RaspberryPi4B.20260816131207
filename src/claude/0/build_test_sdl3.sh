#!/bin/bash
# build_test_sdl3.sh
#
# sdl.py でインストールしたSDL3(および拡張ライブラリ)を使い、
# test_sdl3_full.cpp をビルド・実行する。
#
# 使い方:
#   ./build_test_sdl3.sh [フォントパス] [接続先ホスト]
#
# 事前に以下のどちらかを行っておくこと:
#   (a) source /tmp/install/sdl/activate.sh          (実体のあるスクリプトから)
#   (b) source <(python3 sdl.py activate)            (sdl.py経由)

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

#FONT_PATH="${1:-/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc}"
FONT_PATH="${1:-$HOME/.fonts/UDEVGothicJPDOC-Regular.ttf}"

NET_HOST="${2:-example.com}"
PNG_PATH="$SCRIPT_DIR/test_image.png"
MP3_PATH="$SCRIPT_DIR/test_sound.mp3"

echo "[build_test_sdl3] pkg-config でSDL3関連が見えているか確認します"
if ! pkg-config --exists sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net; then
    echo "[build_test_sdl3] エラー: sdl3系のpkg-configが見つかりません。" >&2
    echo "  先に次のいずれかを実行してください:" >&2
    echo "    source /tmp/install/sdl/activate.sh" >&2
    echo "    source <(python3 sdl.py activate)" >&2
    exit 1
fi

echo "[build_test_sdl3] 使用するSDL3関連バージョン:"
pkg-config --modversion sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net | \
    paste -d'\t' <(printf 'sdl\nimage\nttf\nmixer\nnet\n') -

# テスト用MP3が無ければ、ffmpegかlameがある場合のみ短い無音MP3を生成する。
# (SDL3標準では音声ファイルを合成できないため、外部エンコーダに頼る)
if [ ! -f "$MP3_PATH" ]; then
    if command -v ffmpeg >/dev/null 2>&1; then
        echo "[build_test_sdl3] ffmpegでテスト用MP3を生成します"
        ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:duration=2" "$MP3_PATH"
    else
        echo "[build_test_sdl3] 警告: ffmpegが見つからないためMP3を自動生成できません。" >&2
        echo "  $MP3_PATH に手動でMP3ファイルを配置してから再実行してください。" >&2
        echo "  (このままでもビルド自体は続行し、MP3再生テストのみNGとして扱われます)" >&2
    fi
fi

echo "[build_test_sdl3] ビルドします"
g++ -std=c++17 test_sdl3_full.cpp -o test_sdl3_full \
    $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)

echo "[build_test_sdl3] 実行します"
echo "  フォント: $FONT_PATH"
echo "  PNG     : $PNG_PATH (無ければ自動生成)"
echo "  MP3     : $MP3_PATH"
echo "  接続先  : $NET_HOST"
./test_sdl3_full "$FONT_PATH" "$PNG_PATH" "$MP3_PATH" "$NET_HOST"
