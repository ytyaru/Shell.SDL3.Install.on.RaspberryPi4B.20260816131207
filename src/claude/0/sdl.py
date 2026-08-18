#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sdl.py
======
SDL3 と拡張ライブラリ (SDL_image / SDL_ttf / SDL_mixer / SDL_net) の
最新安定版を GitHub のソースコードから毎回自動判定してビルド・インストールし、
バージョン管理するための全自動スクリプト。

想定環境: Raspberry Pi 4B (aarch64, Debian, 2コア使用してビルド)

--------------------------------------------------------------------
設計方針 (単一責任の原則に従いクラスを分割):

  Config          : /tmp/build/sdl/.config.json の読み書き。
                    現在の「ビルド先」「配置(インストール)先」パスのみを保持する。
  GitHubRelease   : GitHub API から各リポジトリの最新リリースタグ/バージョンを
                    取得する責務のみを持つ。
  SourceFetcher   : ソースZIPのダウンロードと展開 (インクリメンタル) の責務のみ。
  Builder         : cmake による configure / build / install の責務のみ。
  VersionStore    : installed/*.tsv (版の組合せ記録) と
                    versions/<lib>/<version>/ (実インストール済み実体) の
                    読み書きの責務のみ。
  Activator       : activate.sh の生成、および現シェルへ環境変数を
                    反映するための export 文出力の責務のみ。
  Prompter        : Y/n 確認プロンプト表示の責務のみ。
  Cli             : サブコマンドの解釈と、上記クラスの呼び出しのみを行う
                    (ビジネスロジックは持たない)。
--------------------------------------------------------------------

前提として満たしておきたい事項 (このスクリプトはOSパッケージの自動apt-get導入は
行いません。以下はビルド前にご確認ください):
  - cmake, g++/gcc, make, pkg-config, git は導入済みであること
  - IME (fcitx5 等) を使った日本語入力をテストするなら、X11 または Wayland の
    開発ヘッダ (libx11-dev, libwayland-dev 等) が入っていること
  - 日本語フォント (Noto Sans CJK JP 等) をどこかに置いておくこと
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional


# ============================================================================
# 定数
# ============================================================================

PROG = "sdl.py"

# ビルドルートは常に /tmp/ 配下固定 (要件通り)。変更したい場合はコードを直接修正するか
# `sdl.py move build <path>` を使う。
DEFAULT_BUILD_ROOT = Path("/tmp/build/sdl")
DEFAULT_INSTALL_ROOT = Path("/tmp/install/sdl")

# Config は「ビルドルートは基本移動しない」前提でビルドルート直下に固定して置く。
# (移動先候補が /home/pi/... のように複数考えられる install_root とは違い、
#  build_root の置き場所を覚えておくための場所自体が不定になってしまうため、
#  build_root だけは実質固定パスとして扱い、その配下に設定ファイルを置く)
CONFIG_PATH = DEFAULT_BUILD_ROOT / ".config.json"

# key -> (GitHubリポジトリ名, pkg-config名, 依存するkeyのリスト)
LIBS: Dict[str, Dict[str, object]] = {
    "sdl":   {"repo": "SDL",       "pkgconfig": "sdl3",       "deps": []},
    "image": {"repo": "SDL_image", "pkgconfig": "sdl3-image", "deps": ["sdl"]},
    "ttf":   {"repo": "SDL_ttf",   "pkgconfig": "sdl3-ttf",   "deps": ["sdl"]},
    "mixer": {"repo": "SDL_mixer", "pkgconfig": "sdl3-mixer", "deps": ["sdl"]},
    "net":   {"repo": "SDL_net",   "pkgconfig": "sdl3-net",   "deps": ["sdl"]},
}
# ビルド順序 (依存関係上、本体を必ず先に)
ORDER = ["sdl", "image", "ttf", "mixer", "net"]

GITHUB_API_LATEST = "https://api.github.com/repos/libsdl-org/{repo}/releases/latest"
GITHUB_ZIP_URL = "https://github.com/libsdl-org/{repo}/archive/refs/tags/{tag}.zip"

BUILD_JOBS = 2  # ラズパイ4B(2コア分)を使って高速ビルド


def log(msg: str) -> None:
    print(f"[{PROG}] {msg}")


def err(msg: str) -> None:
    print(f"[{PROG}] エラー: {msg}", file=sys.stderr)


def die(msg: str, code: int = 1) -> None:
    err(msg)
    sys.exit(code)


def run(cmd: List[str], cwd: Optional[Path] = None, env: Optional[dict] = None) -> None:
    log("実行: " + " ".join(cmd))
    result = subprocess.run(cmd, cwd=str(cwd) if cwd else None, env=env)
    if result.returncode != 0:
        die(f"コマンドが失敗しました (終了コード {result.returncode}): {' '.join(cmd)}")


def confirm(question: str, auto: bool) -> bool:
    if auto:
        return True
    ans = input(f"{question} Y/n: ").strip().lower()
    return ans in ("", "y", "yes")


# ============================================================================
# Config: ビルド先/配置先パスの永続化のみを担当
# ============================================================================

class Config:
    def __init__(self) -> None:
        self.build_root: Path = DEFAULT_BUILD_ROOT
        self.install_root: Path = DEFAULT_INSTALL_ROOT
        self._load()

    def _load(self) -> None:
        if CONFIG_PATH.exists():
            try:
                data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
                self.build_root = Path(data.get("build_root", str(DEFAULT_BUILD_ROOT)))
                self.install_root = Path(data.get("install_root", str(DEFAULT_INSTALL_ROOT)))
            except Exception as e:
                err(f"設定ファイルの読込に失敗したためデフォルト値を使用します ({e})")
        else:
            self.save()

    def save(self) -> None:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(
            json.dumps(
                {
                    "build_root": str(self.build_root),
                    "install_root": str(self.install_root),
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )


# ============================================================================
# GitHubRelease: 最新版タグ/バージョン番号の取得のみを担当
# ============================================================================

class GitHubRelease:
    @staticmethod
    def latest_tag(repo_name: str) -> str:
        url = GITHUB_API_LATEST.format(repo=repo_name)
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "sdl-py-manager",
                "Accept": "application/vnd.github+json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.load(resp)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            # 要件: 取得できなければ実装エラーとして中断する
            die(f"実装エラー: GitHubから {repo_name} の最新版情報を取得できませんでした ({e})")
        tag = data.get("tag_name")
        if not tag:
            die(f"実装エラー: {repo_name} のリリース情報に tag_name がありません")
        return tag

    @staticmethod
    def version_from_tag(tag: str) -> str:
        m = re.search(r"(\d+\.\d+\.\d+)", tag)
        if not m:
            die(f"実装エラー: タグ '{tag}' からバージョン番号を抽出できませんでした")
        return m.group(1)

    @classmethod
    def latest_version(cls, repo_name: str) -> "tuple[str, str]":
        """(タグ名, バージョン番号) を返す"""
        tag = cls.latest_tag(repo_name)
        version = cls.version_from_tag(tag)
        return tag, version


# ============================================================================
# SourceFetcher: ソースZIPのダウンロードと展開 (インクリメンタル) のみを担当
# ============================================================================

class SourceFetcher:
    def __init__(self, build_root: Path) -> None:
        self.build_root = build_root

    def fetch(self, key: str, repo_name: str, tag: str, version: str) -> Path:
        lib_dir = self.build_root / key / version
        src_dir = lib_dir / "src"
        fetched_marker = lib_dir / ".fetched_ok"

        if fetched_marker.exists() and src_dir.exists():
            log(f"{key} {version}: ソース取得済みのためダウンロード/展開をスキップします")
            return src_dir

        lib_dir.mkdir(parents=True, exist_ok=True)
        zip_path = lib_dir / f"{repo_name}-{tag}.zip"

        if zip_path.exists() and zip_path.stat().st_size > 0:
            log(f"{key} {version}: ZIP取得済みのためダウンロードをスキップします ({zip_path.name})")
        else:
            url = GITHUB_ZIP_URL.format(repo=repo_name, tag=tag)
            log(f"{key} {version}: ダウンロード中 {url}")
            tmp_zip = zip_path.with_suffix(".zip.part")
            try:
                urllib.request.urlretrieve(url, tmp_zip)
            except Exception as e:
                die(f"実装エラー: {key} のソースZIPダウンロードに失敗しました ({e})")
            tmp_zip.rename(zip_path)

        log(f"{key} {version}: 展開中")
        extract_tmp = lib_dir / "_extract_tmp"
        if extract_tmp.exists():
            shutil.rmtree(extract_tmp)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(extract_tmp)

        # GitHubのソースZIPは "<repo>-<tag相当>" という単一フォルダを含むので中身をsrcへ移す
        children = list(extract_tmp.iterdir())
        if len(children) != 1 or not children[0].is_dir():
            die(f"実装エラー: {key} のZIP展開結果が想定外の構成です ({extract_tmp})")
        if src_dir.exists():
            shutil.rmtree(src_dir)
        shutil.move(str(children[0]), str(src_dir))
        shutil.rmtree(extract_tmp, ignore_errors=True)

        fetched_marker.write_text("ok\n", encoding="utf-8")
        return src_dir


# ============================================================================
# Builder: cmake configure/build/install のみを担当
# ============================================================================

class Builder:
    def __init__(self, jobs: int = BUILD_JOBS) -> None:
        self.jobs = jobs

    @staticmethod
    def _extra_cmake_args(key: str) -> List[str]:
        """各拡張ライブラリ固有のcmakeオプション。
        依存(zlib/libpng/freetype/mp3デコーダ等)は極力vendored(同梱)ビルドにして
        apt導入なしでも自己完結してビルドできるようにする。"""
        if key == "sdl":
            return []
        if key == "image":
            return [
                "-DSDLIMAGE_VENDORED=ON",
                "-DSDLIMAGE_PNG=ON",
            ]
        if key == "ttf":
            return [
                "-DSDLTTF_VENDORED=ON",
            ]
        if key == "mixer":
            return [
                "-DSDLMIXER_VENDORED=ON",
                "-DSDLMIXER_MP3=ON",
            ]
        if key == "net":
            return []
        return []

    def build_and_install(
        self,
        key: str,
        src_dir: Path,
        version: str,
        install_prefix: Path,
        cmake_prefix_paths: List[Path],
    ) -> None:
        build_dir = src_dir.parent / "build"
        install_ok_marker = install_prefix / ".install_ok"

        if install_ok_marker.exists():
            log(f"{key} {version}: ビルド/インストール済みのためスキップします")
            return

        build_dir.mkdir(parents=True, exist_ok=True)
        install_prefix.mkdir(parents=True, exist_ok=True)

        prefix_path_str = ";".join(str(p) for p in cmake_prefix_paths)
        configure_cmd = [
            "cmake",
            "-S", str(src_dir),
            "-B", str(build_dir),
            f"-DCMAKE_INSTALL_PREFIX={install_prefix}",
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_PREFIX_PATH={prefix_path_str}",
            "-DBUILD_SHARED_LIBS=ON",
        ]
        configure_cmd += self._extra_cmake_args(key)

        # 既にbuild_dirにCMakeCache.txtがあればインクリメンタルconfigureになる
        run(configure_cmd)
        run(["cmake", "--build", str(build_dir), "-j", str(self.jobs)])
        run(["cmake", "--install", str(build_dir)])

        install_ok_marker.write_text("ok\n", encoding="utf-8")


# ============================================================================
# VersionStore: installed/*.tsv と versions/<lib>/<version>/ の管理のみを担当
# ============================================================================

class VersionStore:
    def __init__(self, install_root: Path) -> None:
        self.install_root = install_root
        self.installed_dir = install_root / "installed"
        self.versions_dir = install_root / "versions"

    # --- installed/*.tsv (実行時点の最新版の組合せスナップショット) ----------

    def snapshot_files(self) -> List[Path]:
        if not self.installed_dir.exists():
            return []
        return sorted(self.installed_dir.glob("*.tsv"), reverse=True)

    def latest_combo(self) -> Optional[Dict[str, str]]:
        files = self.snapshot_files()
        if not files:
            return None
        return self._read_tsv(files[0])

    def combo_by_name(self, name: str) -> Optional[Dict[str, str]]:
        # name は "2026-08-17-00-00-00" もしくは "2026-08-17-00-00-00.tsv" どちらでも良い
        if not name.endswith(".tsv"):
            name = name + ".tsv"
        p = self.installed_dir / name
        if not p.exists():
            return None
        return self._read_tsv(p)

    @staticmethod
    def _read_tsv(path: Path) -> Dict[str, str]:
        combo: Dict[str, str] = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            key, _, version = line.partition("\t")
            combo[key.strip()] = version.strip()
        return combo

    def write_snapshot(self, combo: Dict[str, str]) -> Path:
        self.installed_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d-%H-%M-%S")
        path = self.installed_dir / f"{stamp}.tsv"
        lines = [f"{key}\t{combo[key]}" for key in ORDER if key in combo]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    # --- versions/<lib>/<version>/ (実インストール実体) ----------------------

    def install_prefix_for(self, key: str, version: str) -> Path:
        return self.versions_dir / key / version

    def installed_versions_for(self, key: str) -> List[str]:
        d = self.versions_dir / key
        if not d.exists():
            return []
        versions = [p.name for p in d.iterdir() if p.is_dir() and (p / ".install_ok").exists()]
        return sorted(versions, key=_version_sort_key, reverse=True)

    def is_version_installed(self, key: str, version: str) -> bool:
        return (self.install_prefix_for(key, version) / ".install_ok").exists()


def _version_sort_key(v: str):
    try:
        return tuple(int(x) for x in v.split("."))
    except ValueError:
        return (0,)


# ============================================================================
# Activator: activate.sh 生成 と 環境変数export出力のみを担当
# ============================================================================

class Activator:
    def __init__(self, store: VersionStore) -> None:
        self.store = store

    def _prefixes(self, combo: Dict[str, str]) -> List[Path]:
        return [self.store.install_prefix_for(key, ver) for key, ver in combo.items()]

    def build_env_fragments(self, combo: Dict[str, str]):
        prefixes = self._prefixes(combo)
        pkgconfig_paths = []
        lib_paths = []
        bin_paths = []
        for p in prefixes:
            # ディストリビューションによって lib/ か lib/<triplet>/ かが分かれるため両方追加する
            for cand in (p / "lib" / "pkgconfig", p / "lib64" / "pkgconfig",
                         p / "lib" / "aarch64-linux-gnu" / "pkgconfig"):
                pkgconfig_paths.append(str(cand))
            for cand in (p / "lib", p / "lib64", p / "lib" / "aarch64-linux-gnu"):
                lib_paths.append(str(cand))
            bin_paths.append(str(p / "bin"))
        cmake_prefix = ";".join(str(p) for p in prefixes)
        return pkgconfig_paths, lib_paths, bin_paths, cmake_prefix

    def render_sh(self, combo: Dict[str, str]) -> str:
        pkgconfig_paths, lib_paths, bin_paths, cmake_prefix = self.build_env_fragments(combo)
        lines = []
        lines.append("#!/bin/sh")
        lines.append("# このファイルは sdl.py により自動生成されます。手動編集しないでください。")
        lines.append("# 使い方: source " + str(self.store.install_root / "activate.sh"))
        lines.append("#")
        lines.append("# 有効化される組合せ:")
        for key in ORDER:
            if key in combo:
                lines.append(f"#   {key}\t{combo[key]}")
        lines.append("")
        lines.append(f'export PKG_CONFIG_PATH="{":".join(pkgconfig_paths)}:$PKG_CONFIG_PATH"')
        lines.append(f'export LD_LIBRARY_PATH="{":".join(lib_paths)}:$LD_LIBRARY_PATH"')
        lines.append(f'export PATH="{":".join(bin_paths)}:$PATH"')
        lines.append(f'export CMAKE_PREFIX_PATH="{cmake_prefix};$CMAKE_PREFIX_PATH"')
        lines.append('export SDL_MANAGER_ACTIVE=1')
        lines.append("")
        return "\n".join(lines)

    def write_activate_sh(self, combo: Dict[str, str]) -> Path:
        path = self.store.install_root / "activate.sh"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.render_sh(combo), encoding="utf-8")
        path.chmod(0o755)
        return path

    def print_export_only(self, combo: Dict[str, str]) -> None:
        """`source <(sdl.py activate)` のように直接シェルへ食わせられるよう
        export文だけを標準出力に流す(ログはstderrへ)。"""
        sys.stdout.write(self.render_sh(combo))


# ============================================================================
# Cli: サブコマンドの解釈のみを担当
# ============================================================================

HELP_MAIN = f"""SDLの最新安定版をローカル内で管理する。
コマンド一覧:
  help [コマンド]  ヘルプを表示する。
  install          インストールする。
  uninstall        アンインストールする。
  clean            最新版以外を削除する。
  move             配置場所を移動する。
  version          バージョンを表示する。
  activate         指定した版を有効化する。
パス一覧:
  ビルド: {{build_root}}/
  配置  : {{install_root}}/
"""

HELP_TOPICS = {
    "install": """概要: SDLの最新安定版をインストールする。
説明: GitHubにあるZipからソースコードをダウンロードしビルドしインストールする。
      ラズパイ4B(4GB)で動作させることを想定している。
用法: sdl.py install
""",
    "uninstall": """概要: SDLをアンインストールする。
説明: インストール済みのファイルを削除する。
      cmake,pkg-config,ldなど関連するファイルや環境変数PATHも削除する。
用法: sdl.py uninstall [auto]
引数:
  auto   付与すると実行するか否か確認せず強制実行する。
""",
    "clean": """概要: 古いインストール済みのファイルを削除する。
説明: 最新版より古い版のファイルを削除する。
用法: sdl.py clean [auto]
引数:
  auto   付与すると実行するか否か確認せず強制実行する。
""",
    "activate": """概要: SDLを有効化する。
説明: インストール済みの任意の版から選んで有効化する。
      cmake,pkg-config,ldなど関連ファイルや環境変数を有効化する。
      例えば以下のようにSDLを参照しビルドできるようになる。
      g++ game.cpp -o game $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)
用法: source <(sdl.py activate [auto] {installed})
      (sdl.py自身をsourceすることはできないため、活性化する場合は上記のように
       プロセス置換で読み込むか、生成される activate.sh を直接 source すること)
引数:
  auto       付与すると実行するか否か確認せず強制実行する。
  installed  指定されなければ最新版を使う。指定されていればその版を使う。
             installed/の日時テキストを入力することで指定する。
""",
    "move": """概要: SDLの場所を変更する。
説明: ビルドやインストール先を指定の場所へ変更する。
      cmake,pkg-config,ldなど関連ファイルも変更する。
用法: sdl.py move [auto] build|install {path}
引数:
  auto     付与すると実行するか否か確認せず強制実行する。
  build    ビルド場所を変更する。
  install  インストール場所を変更する。
  path     この場所に変更する。
""",
    "version": """概要: SDLの版を表示する。
説明: インストールされている、または有効化されている版を表示する。
用法: sdl.py version [installed] [sdl|image|ttf|mixer|net|all|list]
引数:
  installed  付与されなければ有効化されている版を表示する。
             付与されていればインストール済み版を表示する。
  sdl        SDL本体の版のみ表示する。
  image      拡張ライブラリSDL_imageの版のみ表示する。
  ttf        拡張ライブラリSDL_ttfの版のみ表示する。
  mixer      拡張ライブラリSDL_mixerの版のみ表示する。
  net        拡張ライブラリSDL_netの版のみ表示する。
  all        すべてのライブラリの版を表示する。
  list       (installedと併用時のみ) スクロールするTUIで一覧表示する。
""",
}


class Cli:
    def __init__(self) -> None:
        self.config = Config()

    # ------------------------------------------------------------------ help
    def print_main_help(self) -> None:
        print(
            HELP_MAIN.format(
                build_root=self.config.build_root, install_root=self.config.install_root
            )
        )

    def cmd_help(self, args: List[str]) -> None:
        if not args:
            self.print_main_help()
            return
        topic = args[0]
        text = HELP_TOPICS.get(topic)
        if text is None:
            self.print_main_help()
            return
        print(text, end="")

    # --------------------------------------------------------------- install
    def cmd_install(self, args: List[str]) -> None:
        build_root = self.config.build_root
        install_root = self.config.install_root
        store = VersionStore(install_root)
        fetcher = SourceFetcher(build_root)
        builder = Builder(jobs=BUILD_JOBS)

        # 1. 現在の最新組合せ(なければ空)を取得
        current_combo = store.latest_combo() or {}

        # 2. GitHub上の最新版を全リポジトリ分取得 (失敗時はGitHubRelease側でdie)
        latest: Dict[str, "tuple[str, str]"] = {}
        for key in ORDER:
            repo_name = str(LIBS[key]["repo"])
            tag, version = GitHubRelease.latest_version(repo_name)
            latest[key] = (tag, version)
            log(f"{key}: GitHub最新版 = {version} (tag={tag})")

        # 3. 新版があるかどうか判定
        anything_new = any(
            not store.is_version_installed(key, latest[key][1]) for key in ORDER
        )
        if not anything_new:
            log("全ライブラリが既に最新版でインストール済みです。何もしません。")
            return

        # 4. 依存順にビルド。既にv005installed済みのバージョンはBuilder側でスキップされる。
        #    cmake側の依存解決用に、今回インストール先(ORDER全ての最新版prefix)を
        #    あらかじめ CMAKE_PREFIX_PATH として渡す。
        target_combo: Dict[str, str] = {key: latest[key][1] for key in ORDER}
        all_prefixes = [store.install_prefix_for(key, target_combo[key]) for key in ORDER]

        for key in ORDER:
            tag, version = latest[key]
            repo_name = str(LIBS[key]["repo"])
            src_dir = fetcher.fetch(key, repo_name, tag, version)
            install_prefix = store.install_prefix_for(key, version)
            builder.build_and_install(
                key=key,
                src_dir=src_dir,
                version=version,
                install_prefix=install_prefix,
                cmake_prefix_paths=all_prefixes,
            )

        # 5. スナップショットを記録し、activateする
        snapshot_path = store.write_snapshot(target_combo)
        log(f"バージョン組合せを記録しました: {snapshot_path}")

        activator = Activator(store)
        activate_path = activator.write_activate_sh(target_combo)
        log(f"activate.sh を更新しました: {activate_path}")
        log("有効化するには次を実行してください:")
        log(f"  source {activate_path}")

    # ------------------------------------------------------------- uninstall
    def cmd_uninstall(self, args: List[str]) -> None:
        auto = "auto" in args
        install_root = self.config.install_root
        if not install_root.exists():
            log("インストールされていません。")
            return
        if not confirm("SDLをアンインストールします。本当に良いですか？", auto):
            log("中止しました。")
            return
        shutil.rmtree(install_root, ignore_errors=True)
        log(f"削除しました: {install_root}")
        log("シェルの環境変数を元に戻すには、activate前の状態のシェルを開き直してください。")

    # ------------------------------------------------------------------ clean
    def cmd_clean(self, args: List[str]) -> None:
        auto = "auto" in args
        install_root = self.config.install_root
        store = VersionStore(install_root)

        latest_combo = store.latest_combo()
        if latest_combo is None:
            log("インストール履歴がありません。")
            return

        snapshots = store.snapshot_files()
        old_snapshots = snapshots[1:]  # 先頭(最新)以外

        to_delete: Dict[str, List[str]] = {}
        for key in ORDER:
            installed = store.installed_versions_for(key)
            keep = latest_combo.get(key)
            olds = [v for v in installed if v != keep]
            if olds:
                to_delete[key] = olds

        if not old_snapshots and not to_delete:
            log("削除対象はありません。既にクリーンな状態です。")
            return

        print("最新版を残して旧版を全削除します。削除すると以下の版はactivateできなくなります。")
        print("installed/")
        for s in old_snapshots:
            print(f"  {s.name}")
        for key, versions in to_delete.items():
            print(f"{key}:")
            for v in versions:
                print(f"  {v}")

        if not confirm("本当に良いですか？", auto):
            log("中止しました。")
            return

        for s in old_snapshots:
            s.unlink(missing_ok=True)
        for key, versions in to_delete.items():
            for v in versions:
                path = store.install_prefix_for(key, v)
                shutil.rmtree(path, ignore_errors=True)
                log(f"削除しました: {path}")

        log("クリーンが完了しました。")

    # ------------------------------------------------------------------- move
    def cmd_move(self, args: List[str]) -> None:
        auto = "auto" in args
        rest = [a for a in args if a != "auto"]
        if len(rest) != 2 or rest[0] not in ("build", "install"):
            print(HELP_TOPICS["move"], end="")
            return
        target, new_path_str = rest
        new_path = Path(new_path_str)

        current = self.config.build_root if target == "build" else self.config.install_root
        label = "ビルド場所" if target == "build" else "配置場所"

        if new_path.resolve() == current.resolve():
            print(f"{label}が変更されていません。指定された場所は現在の{label}と同じです。")
            print(f"現在の{label}と異なる場所を指定してください。")
            return

        print(f"SDLの{label}を以下のように変更します。")
        print(f"現在: {current}")
        print(f"変更: {new_path}")
        print("変更するとディスク書込が発生します。")
        if target == "install":
            print("変更後はactivateで有効化する必要があります。")
        if not confirm("本当に良いですか？", auto):
            log("中止しました。")
            return

        new_path.parent.mkdir(parents=True, exist_ok=True)
        if current.exists():
            shutil.move(str(current), str(new_path))
        else:
            new_path.mkdir(parents=True, exist_ok=True)

        if target == "build":
            self.config.build_root = new_path
        else:
            self.config.install_root = new_path
        self.config.save()

        log(f"{label}を変更しました: {new_path}")

        if target == "install":
            store = VersionStore(new_path)
            combo = store.latest_combo()
            if combo:
                activator = Activator(store)
                activate_path = activator.write_activate_sh(combo)
                log(f"activate.sh を再生成しました: {activate_path}")
                log(f"有効化するには: source {activate_path}")

    # ---------------------------------------------------------------- version
    def cmd_version(self, args: List[str]) -> None:
        store = VersionStore(self.config.install_root)

        if not args:
            combo = store.latest_combo()
            if not combo or "sdl" not in combo:
                die("インストールされていません。先に `sdl.py install` を実行してください。")
            print(combo["sdl"])
            return

        if args[0] == "installed":
            self._version_installed(store, args[1:])
            return

        target = args[0]
        combo = store.latest_combo()
        if not combo:
            die("インストールされていません。先に `sdl.py install` を実行してください。")

        if target == "all":
            for key in ORDER:
                if key in combo:
                    print(f"{key}\t{combo[key]}")
            return

        if target not in LIBS:
            print(HELP_TOPICS["version"], end="")
            return

        if target not in combo:
            die(f"{target} はインストールされていません。")
        print(combo[target])

    def _version_installed(self, store: VersionStore, args: List[str]) -> None:
        if args and args[0] == "list":
            self._version_installed_list_tui(store)
            return

        if args and args[0] in LIBS:
            key = args[0]
            for v in store.installed_versions_for(key):
                print(v)
            return

        for key in ORDER:
            versions = store.installed_versions_for(key)
            if not versions:
                continue
            print(key)
            for v in versions:
                print(f"  {v}")

    def _version_installed_list_tui(self, store: VersionStore) -> None:
        snapshots = store.snapshot_files()
        latest_combo = store.latest_combo() or {}

        if not snapshots:
            log("installed履歴がありません。")
            return

        # curses が使える対話端末ならスクロールするTUIを、そうでなければ
        # 通常のテキスト一覧にフォールバックする。
        if sys.stdout.isatty() and sys.stdin.isatty():
            try:
                import curses

                def _draw(stdscr):
                    curses.curs_set(0)
                    top = 0
                    height, _ = stdscr.getmaxyx()
                    visible = max(1, height - len(ORDER) - 3)
                    while True:
                        stdscr.erase()
                        for i, s in enumerate(snapshots):
                            if i < top or i >= top + visible:
                                continue
                            row = i - top
                            prefix = "→" if i == 0 else " "
                            stdscr.addstr(row, 0, f"{prefix}{s.stem}")
                        base_row = visible + 1
                        for j, key in enumerate(ORDER):
                            if key in latest_combo:
                                stdscr.addstr(base_row + j, 0, f"{key}\t{latest_combo[key]}")
                        stdscr.addstr(0, max(0, stdscr.getmaxyx()[1] - 20), "j/k:移動 q:終了")
                        stdscr.refresh()
                        ch = stdscr.getch()
                        if ch in (ord("q"), 27):
                            break
                        elif ch in (ord("j"), curses.KEY_DOWN):
                            top = min(max(0, len(snapshots) - visible), top + 1)
                        elif ch in (ord("k"), curses.KEY_UP):
                            top = max(0, top - 1)

                curses.wrapper(_draw)
                return
            except Exception as e:
                err(f"TUI表示に失敗したため通常表示に切り替えます ({e})")

        # フォールバック: 単純なテキスト一覧
        for i, s in enumerate(snapshots):
            prefix = "→" if i == 0 else " "
            print(f"{prefix}{s.stem}")
        for key in ORDER:
            if key in latest_combo:
                print(f"{key}\t{latest_combo[key]}")

    # --------------------------------------------------------------- activate
    def cmd_activate(self, args: List[str]) -> None:
        rest = [a for a in args if a != "auto"]
        store = VersionStore(self.config.install_root)

        if rest:
            combo = store.combo_by_name(rest[0])
            if combo is None:
                die(f"指定された installed の記録が見つかりません: {rest[0]}")
        else:
            combo = store.latest_combo()
            if combo is None:
                die("インストールされていません。先に `sdl.py install` を実行してください。")

        activator = Activator(store)
        activator.write_activate_sh(combo)
        # `source <(sdl.py activate)` で直接読み込めるよう export 文を標準出力へ。
        # 通常実行(source無し)の場合はactivate.shの生成のみが有効。
        activator.print_export_only(combo)


# ============================================================================
# エントリポイント
# ============================================================================

def main(argv: List[str]) -> None:
    cli = Cli()

    if not argv:
        cli.print_main_help()
        return

    cmd, rest = argv[0], argv[1:]

    dispatch = {
        "help": cli.cmd_help,
        "install": cli.cmd_install,
        "uninstall": cli.cmd_uninstall,
        "clean": cli.cmd_clean,
        "move": cli.cmd_move,
        "version": cli.cmd_version,
        "activate": cli.cmd_activate,
    }

    handler = dispatch.get(cmd)
    if handler is None:
        cli.print_main_help()
        return

    handler(rest)


if __name__ == "__main__":
    main(sys.argv[1:])
