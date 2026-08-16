#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_mixer/SDL_mixer.h>
#include <SDL3_net/SDL_net.h>
#include <iostream>

int main(int argc, char* argv[]) {
    // 1. 各種ライブラリの初期化
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) {
        std::cerr << "SDL3 初期化失敗: " << SDL_GetError() << std::endl;
        return 1;
    }

    // SDL3_image: SDL3ではIMG_Initは不要（自動初期化）、ここではロードテストに代わるダミーチェック
    // SDL3_net: NET_Init を使用
    if (!NET_Init()) {
        std::cerr << "SDL3_net 初期化失敗: " << SDL_GetError() << std::endl;
        SDL_Quit();
        return 1;
    }

    // SDL3_mixer: 新しい引数形式。0(デフォルトデバイス), ポインタを指定
    if (!Mix_OpenAudio(0, nullptr)) {
        std::cerr << "SDL3_mixer 初期化失敗: " << SDL_GetError() << std::endl;
        NET_Quit();
        SDL_Quit();
        return 1;
    }

    if (!TTF_Init()) {
        std::cerr << "SDL3_ttf 初期化失敗: " << SDL_GetError() << std::endl;
        Mix_CloseAudio();
        NET_Quit();
        SDL_Quit();
        return 1;
    }

    std::cout << "--- すべての SDL3 拡張ライブラリの初期化に成功しました ---" << std::endl;

    // 2. ウィンドウとレンダラーの生成
    SDL_Window* window = SDL_CreateWindow("SDL3 Full Test (Japanese IME)", 800, 600, 0);
    if (!window) {
        std::cerr << "ウィンドウ生成失敗: " << SDL_GetError() << std::endl;
        TTF_Quit();
        Mix_CloseAudio();
        NET_Quit();
        SDL_Quit();
        return 1;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(window, nullptr);
    if (!renderer) {
        std::cerr << "レンダラー生成失敗: " << SDL_GetError() << std::endl;
        SDL_DestroyWindow(window);
        TTF_Quit();
        Mix_CloseAudio();
        NET_Quit();
        SDL_Quit();
        return 1;
    }

    // 3. 日本語フォントの読み込みとテキスト表示テスト
    TTF_Font* font = TTF_OpenFont("/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", 28);
    if (!font) {
        font = TTF_OpenFont("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 28);
    }

    SDL_Texture* textTexture = nullptr;
    int textWidth = 0, textHeight = 0;
    if (font) {
        SDL_Color textColor = {255, 255, 255, 255};
        SDL_Surface* textSurface = TTF_RenderText_Blended(font, "SDL3 日本語表示＆入力テスト", 0, textColor);
        if (textSurface) {
            textWidth = textSurface->w;
            textHeight = textSurface->h;
            textTexture = SDL_CreateTextureFromSurface(renderer, textSurface);
            SDL_DestroySurface(textSurface);
        }
    } else {
        std::cout << "警告: 日本語フォントが見つからないため、画面への文字描画をスキップします。" << std::endl;
    }

    // 4. 日本語入力（IME / IBUS）を開始
    SDL_StartTextInput(window);
    std::cout << "\n[IMEテスト] ウィンドウをアクティブにして日本語入力を試してください。" << std::endl;
    std::cout << "ターミナルに入力イベントがダンプされます。\n" << std::endl;

    // 5. メインループ
    bool running = true;
    SDL_Event event;
    while (running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT) {
                running = false;
            } else if (event.type == SDL_EVENT_KEY_DOWN) {
                if (event.key.key == SDLK_ESCAPE) {
                    running = false;
                }
            } else if (event.type == SDL_EVENT_TEXT_INPUT) {
                std::cout << "[IME 確定文字列]: " << event.text.text << std::endl;
            } else if (event.type == SDL_EVENT_TEXT_EDITING) {
                if (SDL_strlen(event.edit.text) > 0) {
                    std::cout << "[IME 変換中...]: " << event.edit.text << " (カーソル位置: " << event.edit.start << ")" << std::endl;
                }
            }
        }

        SDL_SetRenderDrawColor(renderer, 20, 40, 80, 255);
        SDL_RenderClear(renderer);

        if (textTexture) {
            SDL_FRect dstRect = { 50.0f, 50.0f, (float)textWidth, (float)textHeight };
            SDL_RenderTexture(renderer, textTexture, nullptr, &dstRect);
        }

        SDL_RenderPresent(renderer);
        SDL_Delay(16);
    }

    // 6. 後片付け
    SDL_StopTextInput(window);
    if (textTexture) SDL_DestroyTexture(textTexture);
    if (font) TTF_CloseFont(font);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);

    TTF_Quit();
    Mix_CloseAudio();
    NET_Quit();
    SDL_Quit();
    return 0;
}
