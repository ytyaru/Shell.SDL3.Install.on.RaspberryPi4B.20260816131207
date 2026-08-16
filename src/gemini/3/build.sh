#!/bin/bash
set -e

# スクリプト自身の配置ディレクトリへ強制移動
cd "$(dirname "$0")"

echo "=== [1/2] SDL3 テストプログラムのビルドを開始 ==="

# g++によるコンパイルの実行
g++ test_sdl3_full.cpp -o test_sdl3_full $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)

echo "=== [2/2] ビルドが正常に成功しました ==="
echo "次のコマンドで実行してください: ./test_sdl3_full"
