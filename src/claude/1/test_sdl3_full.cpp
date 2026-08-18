// test_sdl3_full.cpp
//
// SDL3 環境が以下を満たしていることを確認するためのテストプログラム。
//   1. IME による日本語入力ができること (SDL_TEXTINPUT イベント)
//   2. 指定したフォントで日本語が表示できること (SDL_ttf)
//   3. PNG画像が扱えること (SDL_image)
//   4. MP3が再生できること (SDL_mixer)
//   5. ネット接続できること (SDL_net)
//
// 使い方:
//   ./test_sdl3_full [フォントパス] [PNGパス] [MP3パス] [接続先ホスト]
//   引数省略時のデフォルトは build_test_sdl3.sh 側で用意する。
//
// 注意:
//   SDL3_net のAPIは非同期ソケット中心 (SDLNet_CreateClient / SDLNet_WaitUntilResolved 等)
//   で、ライブラリのマイナーバージョンによって細部のシグネチャが変わることがあります。
//   実機のヘッダ (/usr/include や versions/net/<version>/include/SDL3_net/SDL_net.h) と
//   食い違うコンパイルエラーが出た場合は、その版のヘッダを見てここを合わせてください。

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_image/SDL_image.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_mixer/SDL_mixer.h>
#include <SDL3_net/SDL_net.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

struct TestResult {
    const char *name;
    bool ok;
    std::string detail;
};

static void report(std::vector<TestResult> &results, const char *name, bool ok, const std::string &detail = "") {
    results.push_back({name, ok, detail});
    std::printf("[%s] %s%s%s\n", ok ? "OK" : "NG", name,
                detail.empty() ? "" : " : ", detail.c_str());
}

int main(int argc, char *argv[]) {
    const char *font_path = argc > 1 ? argv[1] : "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
//    const char *font_path = argc > 1 ? argv[1] : "/home/pi/.fonts/UDEVGothicJPDOC-Regular.ttf";
    const char *png_path  = argc > 2 ? argv[2] : "test_image.png";
    const char *mp3_path  = argc > 3 ? argv[3] : "test_sound.mp3";
    const char *net_host  = argc > 4 ? argv[4] : "example.com";

    std::vector<TestResult> results;

    // ---------------------------------------------------------------- SDL初期化
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) {
        std::fprintf(stderr, "SDL_Init 失敗: %s\n", SDL_GetError());
        return 1;
    }
    report(results, "SDL_Init", true);

    SDL_Window *window = SDL_CreateWindow("SDL3 全機能確認テスト", 800, 600, 0);
    SDL_Renderer *renderer = window ? SDL_CreateRenderer(window, nullptr) : nullptr;
    report(results, "SDL_CreateWindow/Renderer", window && renderer,
           window ? "" : SDL_GetError());

    // ---------------------------------------------------- 1. IME(日本語テキスト入力)
    // 実際のIME確定文字が入力されたかは対話操作が必要なため、ここでは
    //   - SDL_StartTextInput が成功すること
    //   - IMEに関連するヒント(SDL_HINT_IME_*)が設定できること
    // を「有効化できること」の確認とする。手動確認したい場合は本プログラムを
    // 対話実行し、ウィンドウにフォーカスした状態で日本語入力してSDL_TEXTINPUT
    // イベントが届くかログで確認すること(下のイベントループ参照)。
    bool text_input_started = window && SDL_StartTextInput(window);
    report(results, "IME/SDL_StartTextInput", text_input_started,
           text_input_started ? "" : SDL_GetError());

    // ---------------------------------------------------------- 2. SDL_ttf 日本語表示
    bool ttf_ok = TTF_Init();
    report(results, "TTF_Init", ttf_ok, ttf_ok ? "" : SDL_GetError());

    TTF_Font *font = nullptr;
    if (ttf_ok) {
        font = TTF_OpenFont(font_path, 32);
        report(results, "TTF_OpenFont", font != nullptr,
                font ? font_path : (std::string("フォントを開けません: ") + font_path));
    }

    SDL_Texture *text_texture = nullptr;
    if (font) {
        SDL_Color white{255, 255, 255, 255};
        const char *msg = "日本語表示テスト こんにちは";
        SDL_Surface *surf = TTF_RenderText_Blended(font, msg, std::strlen(msg), white);
        bool render_ok = surf != nullptr;
        report(results, "TTF_RenderText_Blended(日本語)", render_ok,
               render_ok ? "" : SDL_GetError());
        if (surf) {
            text_texture = SDL_CreateTextureFromSurface(renderer, surf);
            SDL_DestroySurface(surf);
        }
    }

    // ---------------------------------------------------------------- 3. PNG読込
    bool img_ok = true; // SDL3_image はSDL3_ttfと違い明示Init不要(バージョンによる)
    SDL_Surface *png_surf = IMG_Load(png_path);
    if (!png_surf) {
        // テスト用PNGが無ければその場で1枚生成してから再読込する
        SDL_Surface *gen = SDL_CreateSurface(64, 64, SDL_PIXELFORMAT_RGBA32);
        if (gen) {
            SDL_FillSurfaceRect(gen, nullptr, SDL_MapSurfaceRGBA(gen, 255, 0, 0, 255));
            IMG_SavePNG(gen, png_path);
            SDL_DestroySurface(gen);
            png_surf = IMG_Load(png_path);
        }
    }
    report(results, "IMG_Load(PNG)", png_surf != nullptr,
           png_surf ? png_path : SDL_GetError());
    SDL_Texture *png_texture = nullptr;
    if (png_surf) {
        png_texture = SDL_CreateTextureFromSurface(renderer, png_surf);
        SDL_DestroySurface(png_surf);
    }

    // ---------------------------------------------------------------- 4. MP3再生
    bool mixer_ok = Mix_OpenAudio(0, nullptr);
    report(results, "Mix_OpenAudio", mixer_ok, mixer_ok ? "" : SDL_GetError());

    bool mp3_played = false;
    if (mixer_ok) {
        Mix_Music *music = Mix_LoadMUS(mp3_path);
        if (!music) {
            report(results, "Mix_LoadMUS(MP3)", false,
                   std::string(mp3_path) + " を読み込めません(先に用意してください): " + SDL_GetError());
        } else {
            mp3_played = Mix_PlayMusic(music, 1);
            report(results, "Mix_PlayMusic(MP3)", mp3_played, mp3_played ? "" : SDL_GetError());
            SDL_Delay(1500); // 再生確認のため少し待つ
            Mix_HaltMusic();
            Mix_FreeMusic(music);
        }
    }

    // -------------------------------------------------------------- 5. ネット接続
    bool net_ok = SDLNet_Init();
    report(results, "SDLNet_Init", net_ok, net_ok ? "" : SDL_GetError());

    if (net_ok) {
        SDLNet_Address *addr = SDLNet_ResolveHostname(net_host);
        int wait_status = addr ? SDLNet_WaitUntilResolved(addr, 5000) : -1;
        bool resolved = addr && wait_status == 1;
        report(results, "SDLNet_ResolveHostname", resolved,
               resolved ? net_host : (std::string(net_host) + " を解決できません"));

        if (resolved) {
            SDLNet_StreamSocket *sock = SDLNet_CreateClient(addr, 80);
            bool connected = false;
            if (sock) {
                for (int i = 0; i < 50 && !connected; ++i) {
                    int cstat = SDLNet_GetConnectionStatus(sock);
                    if (cstat == 1) { connected = true; break; }
                    if (cstat < 0) break;
                    SDL_Delay(100);
                }
            }
            report(results, "SDLNet_CreateClient(TCP接続)", connected,
                   connected ? "" : "接続確立できませんでした");
            if (sock) SDLNet_DestroyStreamSocket(sock);
        }
        if (addr) SDLNet_UnrefAddress(addr);
    }

    // ------------------------------------------------------------- 簡易描画/イベント
    // ウィンドウを数フレーム描画して閉じる(CI等の非対話実行を想定し自動終了させる)。
    // 対話的にIME確定文字入力を目視確認したい場合は環境変数 SDL_TEST_INTERACTIVE=1 を
    // 設定して実行すると、ウィンドウを閉じるかESCキーが押されるまでループし続ける。
    bool interactive = SDL_getenv("SDL_TEST_INTERACTIVE") != nullptr;
    Uint64 start = SDL_GetTicks();
    bool quit = false;
    while (!quit) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_EVENT_QUIT) quit = true;
            if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_ESCAPE) quit = true;
            if (e.type == SDL_EVENT_TEXT_INPUT) {
                std::printf("[IME] TEXT_INPUT を受信しました: %s\n", e.text.text);
            }
        }
        SDL_SetRenderDrawColor(renderer, 20, 20, 30, 255);
        SDL_RenderClear(renderer);
        if (text_texture) {
            SDL_FRect dst{20, 20, 400, 50};
            SDL_RenderTexture(renderer, text_texture, nullptr, &dst);
        }
        if (png_texture) {
            SDL_FRect dst{20, 100, 64, 64};
            SDL_RenderTexture(renderer, png_texture, nullptr, &dst);
        }
        SDL_RenderPresent(renderer);

        if (!interactive && SDL_GetTicks() - start > 1000) quit = true;
    }

    // --------------------------------------------------------------------- 後片付け
    if (text_texture) SDL_DestroyTexture(text_texture);
    if (png_texture) SDL_DestroyTexture(png_texture);
    if (font) TTF_CloseFont(font);
    if (ttf_ok) TTF_Quit();
    if (mixer_ok) Mix_CloseAudio();
    if (net_ok) SDLNet_Quit();
    if (renderer) SDL_DestroyRenderer(renderer);
    if (window) SDL_DestroyWindow(window);
    SDL_Quit();

    // --------------------------------------------------------------------- 結果表示
    std::printf("\n===== テスト結果まとめ =====\n");
    bool all_ok = true;
    for (auto &r : results) {
        std::printf("  [%s] %s\n", r.ok ? "OK" : "NG", r.name);
        if (!r.ok) all_ok = false;
    }
    std::printf("=============================\n");
    return all_ok ? 0 : 1;
}
