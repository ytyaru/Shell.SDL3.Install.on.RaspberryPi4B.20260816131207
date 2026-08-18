Good, sdl.py compiles and runs. Now let's write the test project (C++ source + build script) that verifies IME input, Japanese font rendering, PNG display, MP3 playback, and network connectivity.Files ready. Copying to outputs and presenting them.`sdl.py`・`test_sdl3_full.cpp`・`build_test_sdl3.sh` を作成しました。`sdl.py`は構文チェック済み(`python3 -m py_compile`)、ヘルプ表示も動作確認済みです。ただしこの作業環境にはネットワーク接続もラズパイ実機もないため、実際のダウンロード・ビルド・実行までは確認できていません。以下、仕様上あいまいだった点で判断した内容と、実機で試す際の注意点です。

**判断した点(仕様に揺れがあった箇所)**
- `installed/`配下のファイル拡張子: ツリー図では`.md`、記録例では`.tsv`と表記が割れていたため、内容がTSV形式である`.tsv`を採用しました。`.md`にしたい場合は`VersionStore`クラスの`.tsv`という文字列を置換すれば済みます。
- `source sdl.py activate`という用法: Pythonスクリプトを直接`source`することはできないため、`source <(sdl.py activate)`(プロセス置換)、または生成される`activate.sh`を直接`source`する形にしました。
- 依存ライブラリ(zlib/libpng/freetype/MP3デコーダ等)は`apt`を使わず自己完結でビルドできるよう、各拡張ライブラリの`VENDORED`オプションを有効にしています。

**実機で試す前に確認してほしいこと**
- `cmake` `g++` `pkg-config` が導入済みであること
- IME入力を試すには、システム側にfcitx5等のIMEと、X11/Wayland開発ヘッダが入っている必要があります(スクリプトはapt導入を行いません)
- テスト用MP3は自動生成できないため、`ffmpeg`があれば`build_test_sdl3.sh`が自動生成しますが、無ければ`test_sound.mp3`を手動で用意してください
- `SDL3_net`は非同期API中心でバージョンによりシグネチャが変わりやすいため、実際のヘッダと食い違うコンパイルエラーが出た場合は`test_sdl3_full.cpp`のネット部分を該当ヘッダに合わせて調整してください

実機で`sdl.py install`を実行してエラーが出た場合は、そのログを共有してもらえれば修正版を作ります。
