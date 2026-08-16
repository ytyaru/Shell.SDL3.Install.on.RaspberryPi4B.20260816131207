#!/bin/bash
set -e

echo "=== [1/4] システムの更新と必須パッケージのインストール ==="
sudo apt update
sudo apt install -y \
    cmake ninja-build build-essential git \
    libwayland-dev libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev \
    libx11-dev libxext-dev libxrandr-dev \
    libasound2-dev libpulse-dev libpipewire-0.3-dev \
    libfreetype-dev libharfbuzz-dev \
    fonts-noto-cjk

# ビルド用ワークスペースの作成
BUILD_DIR="$HOME/sdl3_build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 4GBモデルなので4コア全力で並列ビルド（最速設定）
export CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)

echo "=== [2/4] SDL3 本体のビルドとインストール ==="
if [ ! -d "SDL" ]; then
#    git clone --depth 1 https://github.com
    git clone --depth 1 https://github.com/libsdl-org/SDL.git
fi
cd SDL
mkdir -p build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local ..
ninja
sudo ninja install
cd "$BUILD_DIR"

echo "=== [3/4] SDL3_ttf のビルドとインストール ==="
if [ ! -d "SDL_ttf" ]; then
#    git clone --depth 1 https://github.com
    git clone --depth 1 https://github.com/libsdl-org/SDL_ttf.git
fi
cd SDL_ttf
mkdir -p build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local ..
ninja
sudo ninja install
sudo ldconfig
cd "$BUILD_DIR"

echo "=== [4/4] 日本語表示テストプログラムの生成とコンパイル ==="
cat << 'EOF' > test_japanese.cpp
#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <iostream>

int main(int argc, char* argv[]) {
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        std::cerr << "SDL_Init Error: " << SDL_GetError() << std::endl;
        return 1;
    }
    if (!TTF_Init()) {
        std::cerr << "TTF_Init Error: " << SDL_GetError() << std::endl;
        SDL_Quit();
        return 1;
    }

    SDL_Window* window = SDL_CreateWindow("SDL3 日本語テスト", 640, 480, SDL_WINDOW_RESIZABLE);
    if (!window) {
        std::cerr << "CreateWindow Error: " << SDL_GetError() << std::endl;
        TTF_Quit();
        SDL_Quit();
        return 1;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(window, NULL);
    if (!renderer) {
        std::cerr << "CreateRenderer Error: " << SDL_GetError() << std::endl;
        SDL_DestroyWindow(window);
        TTF_Quit();
        SDL_Quit();
        return 1;
    }

    // Bookworm標準のNotoフォントを指定
    const char* font_path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
    TTF_Font* font = TTF_OpenFont(font_path, 24);
    if (!font) {
        std::cerr << "OpenFont Error: " << SDL_GetError() << " (Path: " << font_path << ")" << std::endl;
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        TTF_Quit();
        SDL_Quit();
        return 1;
    }

    SDL_Color textColor = {255, 255, 255, 255};
    SDL_Surface* surface = TTF_RenderText_Blended(font, "こんにちは！SDL3の世界へ。", 0, textColor);
    SDL_Texture* texture = SDL_CreateTextureFromSurface(renderer, surface);
    SDL_DestroySurface(surface);

    bool keep_running = true;
    SDL_Event event;

    // テキスト入力を明示的に開始（IMEの有効化テスト用）
    SDL_StartTextInput(window);

    while (keep_running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT) {
                keep_running = false;
            }
            // キーボードでIME漢字変換が確定した際に文字列を受け取るイベント
            if (event.type == SDL_EVENT_TEXT_INPUT) {
                std::cout << "入力された文字: " << event.text.text << std::endl;
            }
        }

        SDL_SetRenderDrawColor(renderer, 30, 30, 30, 255);
        SDL_RenderClear(renderer);

        float w, h;
        SDL_GetTextureSize(texture, &w, &h);
        SDL_FRect dstRect = { 50.0f, 200.0f, w, h };
        SDL_RenderTexture(renderer, texture, NULL, &dstRect);

        SDL_RenderPresent(renderer);
        SDL_Delay(16);
    }

    SDL_StopTextInput(window);
    SDL_DestroyTexture(texture);
    TTF_CloseFont(font);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    TTF_Quit();
    SDL_Quit();
    return 0;
}
EOF

# コンパイル
g++ test_japanese.cpp -o test_sdl3 $(pkg-config --cflags --libs sdl3 sdl3-ttf)

echo "========================================="
echo " 4GBモデル向け最速ビルドが完了しました！"
echo " cd $BUILD_DIR && ./test_sdl3"
echo "========================================="
