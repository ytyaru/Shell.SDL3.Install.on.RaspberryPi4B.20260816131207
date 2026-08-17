#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json, os, re, shutil, struct, subprocess, sys, time, urllib.request, zipfile
from pathlib import Path

ROOT=Path('/tmp/sdl')
INSTALL=Path('/home/pi/root/sys/env/sdl')
TEST=Path('/tmp/sdl-test')
JOBS='2'
REPOS={'sdl':'SDL','image':'SDL_image','mixer':'SDL_mixer','net':'SDL_net','ttf':'SDL_ttf'}
PC={'sdl':'sdl3','image':'sdl3-image','mixer':'sdl3-mixer','net':'sdl3-net','ttf':'sdl3-ttf'}
STABLE=re.compile(r'^(?:release-)?(\d+)\.(\d+)\.(\d+)$')

def die(s): raise RuntimeError(s)
def log(s): print(s,flush=True)
def run(c,env=None,cwd=None):
    log('$ '+' '.join(map(str,c))); return subprocess.run(c,check=True,env=env,cwd=cwd)
def vt(v): return tuple(map(int,v.split('.')))
def root():
    if os.geteuid()!=0: die('root権限が必要です。sudo sdl.py install で実行してください。')
def gh(url):
    try:
        q=urllib.request.Request(url,headers={'Accept':'application/vnd.github+json','User-Agent':'sdl.py'})
        with urllib.request.urlopen(q,timeout=30) as r: return json.load(r)
    except Exception as e: die(f'GitHubからバージョン値を取得できませんでした。\n{url}\n{e}')
def latest(repo):
    xs=[]
    for r in gh(f'https://api.github.com/repos/libsdl-org/{repo}/releases?per_page=100'):
        if r.get('draft') or r.get('prerelease'): continue
        m=STABLE.fullmatch(r.get('tag_name',''))
        if m: xs.append((tuple(map(int,m.groups())),r['tag_name']))
    if not xs: die(f'{repo}: GitHubから安定版タグを取得できませんでした。')
    v,t=max(xs); return '.'.join(map(str,v)),t

def src(repo,v,tag):
    d=ROOT/'src'/f'{repo}-{v}'; z=ROOT/'zip'/f'{repo}-{v}.zip'; d.parent.mkdir(parents=True,exist_ok=True); z.parent.mkdir(parents=True,exist_ok=True)
    if d.is_dir() and (d/'CMakeLists.txt').exists(): return d
    if not z.exists():
        log(f'{repo} {v}: ZIPを取得します。')
        u=f'https://github.com/libsdl-org/{repo}/archive/refs/tags/{tag}.zip'
        try:
            q=urllib.request.Request(u,headers={'User-Agent':'sdl.py'})
            with urllib.request.urlopen(q,timeout=120) as r:
                with z.open('wb') as zf: shutil.copyfileobj(r,zf)
        except Exception as e: die(f'{repo} {v}: ZIP取得失敗。\n{e}')
    else: log(f'{repo} {v}: 既存ZIPを再利用します。')
    x=ROOT/'extract'/f'{repo}-{v}'; shutil.rmtree(x,ignore_errors=True); x.mkdir(parents=True)
    try:
        with zipfile.ZipFile(z) as f: f.extractall(x)
    except Exception as e: die(f'{repo} {v}: ZIP展開失敗。\n{e}')
    ds=[p for p in x.iterdir() if p.is_dir()]
    if len(ds)!=1: die(f'{repo} {v}: ZIP内ソースを特定できません。')
    shutil.rmtree(d,ignore_errors=True); shutil.move(str(ds[0]),str(d)); return d

def env_for(paths):
    e=os.environ.copy(); e['CMAKE_PREFIX_PATH']=str(INSTALL/'current')+':'+e.get('CMAKE_PREFIX_PATH','')
    pcpaths=[str(INSTALL/'current'/'lib'/'pkgconfig'),str(INSTALL/'current'/'lib'/'aarch64-linux-gnu'/'pkgconfig')]
    libpaths=[str(INSTALL/'current'/'lib'),str(INSTALL/'current'/'lib'/'aarch64-linux-gnu')]
    for p in paths:
        pcpaths += [str(p/'lib'/'pkgconfig'),str(p/'lib'/'aarch64-linux-gnu'/'pkgconfig')]
        libpaths += [str(p/'lib'),str(p/'lib'/'aarch64-linux-gnu')]
    e['PKG_CONFIG_PATH']=':'.join(dict.fromkeys(pcpaths))+':'+e.get('PKG_CONFIG_PATH','')
    e['LD_LIBRARY_PATH']=':'.join(dict.fromkeys(libpaths))+':'+e.get('LD_LIBRARY_PATH','')
    return e

def build(key,repo,v,tag,prefix):
    s=src(repo,v,tag); b=ROOT/'build'/f'{key}-{v}'; b.mkdir(parents=True,exist_ok=True); prefix.mkdir(parents=True,exist_ok=True)
    e=env_for([])
    a=['cmake','-S',str(s),'-B',str(b),'-G','Ninja','-DCMAKE_BUILD_TYPE=Release',f'-DCMAKE_INSTALL_PREFIX={prefix}','-DBUILD_SHARED_LIBS=ON']
    opts={'sdl':['-DSDL_TESTS=OFF','-DSDL_EXAMPLES=OFF','-DSDL_INSTALL_TESTS=OFF'],'image':['-DSDLIMAGE_TESTS=OFF','-DSDLIMAGE_SAMPLES=OFF'],'ttf':['-DSDLTTF_TESTS=OFF','-DSDLTTF_SAMPLES=OFF'],'mixer':['-DSDLMIXER_TESTS=OFF','-DSDLMIXER_SAMPLES=OFF'],'net':['-DSDLNET_TESTS=OFF','-DSDLNET_SAMPLES=OFF']}[key]
    if not (b/'CMakeCache.txt').exists(): run(a+opts,e)
    else: log(f'{key} {v}: 既存CMake設定を再利用します。')
    run(['cmake','--build',str(b),'--parallel',JOBS],e)
    marker=b/'.installed';
    if not marker.exists(): run(['cmake','--install',str(b)],e); marker.write_text('ok\n')
    else: log(f'{key} {v}: 既存インストールを再利用します。')

def versions():
    out={}
    if not INSTALL.exists(): return out
    for k,pkg in PC.items():
        found=[]
        for d in INSTALL.iterdir():
            if not d.is_dir() or not re.fullmatch(r'\d+\.\d+\.\d+',d.name): continue
            if (d/'lib'/'pkgconfig'/f'{pkg}.pc').exists() or (d/'lib'/'aarch64-linux-gnu'/'pkgconfig'/f'{pkg}.pc').exists(): found.append(d.name)
        if found: out[k]=max(found,key=vt)
    return out

def current():
    if not INSTALL.exists(): die('SDL3がインストールされていません。')
    vs=[d for d in INSTALL.iterdir() if d.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+',d.name)]
    if not vs: die('SDL3がインストールされていません。')
    d=max(vs,key=lambda x:vt(x.name)); c=INSTALL/'current'; t=INSTALL/'.current.tmp'; t.unlink(missing_ok=True); t.symlink_to(d.name); t.replace(c)

def system_config():
    v=versions(); paths=[]
    for k in ['image','mixer','net','ttf']:
        if k in v: paths.append(INSTALL/v[k])
    c=INSTALL/'current'
    pcs=[c/'lib'/'pkgconfig',c/'lib'/'aarch64-linux-gnu'/'pkgconfig']+[x for p in paths for x in (p/'lib'/'pkgconfig',p/'lib'/'aarch64-linux-gnu'/'pkgconfig')]
    libs=[c/'lib',c/'lib'/'aarch64-linux-gnu']+[x for p in paths for x in (p/'lib',p/'lib'/'aarch64-linux-gnu')]
    Path('/etc/profile.d/sdl3.sh').write_text('# sdl.py 管理\nexport SDL3_ROOT="'+str(c)+'"\nexport PKG_CONFIG_PATH="'+':'.join(map(str,pcs))+'${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"\nexport CMAKE_PREFIX_PATH="'+str(c)+'${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"\n')
    Path('/etc/ld.so.conf.d/sdl3.conf').write_text('\n'.join(map(str,libs))+'\n'); run(['ldconfig'])

def install():
    root(); ROOT.mkdir(parents=True,exist_ok=True); INSTALL.mkdir(parents=True,exist_ok=True)
    if shutil.which('cmake') is None or shutil.which('ninja') is None or shutil.which('g++') is None or shutil.which('pkg-config') is None:
        run(['apt-get','update']); run(['apt-get','install','-y','build-essential','cmake','ninja-build','pkg-config','unzip','ffmpeg','libx11-dev','libxext-dev','libxrandr-dev','libxinerama-dev','libxcursor-dev','libxi-dev','libxfixes-dev','libwayland-dev','wayland-protocols','libdrm-dev','libgbm-dev','libudev-dev','libasound2-dev','libpulse-dev','libfreetype6-dev','libharfbuzz-dev','libpng-dev','libjpeg-dev','libwebp-dev','libtiff-dev','libflac-dev','libvorbis-dev','libogg-dev','libmpg123-dev'])
    got={k:latest(r) for k,r in REPOS.items()}
    for k,(v,t) in got.items(): log(f'最新安定版 {k}: {v} ({t})')
    # 本体を先に入れてcurrentを更新する。拡張は常にcurrentのSDLを参照してビルドする。
    v,t=got['sdl']; build('sdl','SDL',v,t,INSTALL/v); current(); system_config()
    for k in ['image','ttf','mixer','net']:
        v,t=got[k]; build(k,REPOS[k],v,t,INSTALL/v)
    current(); system_config()
    e=env_for([INSTALL/versions()[k] for k in ['image','ttf','mixer','net'] if k in versions()])
    for p in PC.values(): run(['pkg-config','--modversion',p],e)
    write_test(); run_test(e)
    (ROOT/'state.json').write_text(json.dumps({'installed':versions(),'checked':got,'time':time.time()},ensure_ascii=False,indent=2))

def write_test():
    TEST.mkdir(parents=True,exist_ok=True); A=TEST/'assets'; A.mkdir(exist_ok=True)
    font=next((Path(x) for x in ['/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc','/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'] if Path(x).exists()),None)
    if font: shutil.copy2(font,A/font.name)
    w=h=64; raw=b''.join(b'\x00'+bytes([30,120,220,255])*w for _ in range(h))
    def ch(n,d): return struct.pack('>I',len(d))+n+d+struct.pack('>I',__import__('zlib').crc32(n+d)&0xffffffff)
    import zlib; (A/'test.png').write_bytes(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+ch(b'IDAT',zlib.compress(raw))+ch(b'IEND',b''))
    if not (A/'test.mp3').exists(): run(['ffmpeg','-y','-loglevel','error','-f','lavfi','-i','sine=frequency=440:duration=2','-codec:a','libmp3lame','-q:a','7',str(A/'test.mp3')])
    (TEST/'test_sdl3_full.cpp').write_text(r'''#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_image/SDL_image.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_mixer/SDL_mixer.h>
#include <SDL3_net/SDL_net.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
int main(){
 if(!SDL_Init(SDL_INIT_VIDEO|SDL_INIT_AUDIO)){std::puts(SDL_GetError());return 1;}
 SDL_Window*w=SDL_CreateWindow("SDL3 日本語機能確認",900,600,0); SDL_Renderer*r=SDL_CreateRenderer(w,nullptr);
 if(!w||!r){std::puts(SDL_GetError());return 1;}
 SDL_StartTextInput(w); std::puts("OK: IME入力受付開始。日本語入力イベントを5秒間待ちます。");
 const char*f=std::getenv("SDL_TEST_FONT"); if(!f)f="assets/DejaVuSans.ttf";
 if(TTF_Init()){TTF_Font*font=TTF_OpenFont(f,32); if(font){SDL_Surface*s=TTF_RenderText_Blended(font,u8"日本語表示確認：SDL3 + SDL_ttf",0,{255,255,255,255}); if(s){std::puts("OK: 指定フォントで日本語描画");SDL_DestroySurface(s);}else std::puts(TTF_GetError());TTF_CloseFont(font);}else std::puts(TTF_GetError());TTF_Quit();}
 SDL_Surface*i=IMG_Load("assets/test.png"); if(i){std::puts("OK: PNG読み込み");SDL_DestroySurface(i);}else std::puts(IMG_GetError());
 if(MIX_Init()){MIX_Mixer*m=MIX_CreateMixerDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,nullptr);if(m){MIX_Audio*a=MIX_LoadAudio(m,"assets/test.mp3",false);if(a){std::puts("OK: MP3デコード/ロード");MIX_DestroyAudio(a);}else std::puts(SDL_GetError());MIX_DestroyMixer(m);}else std::puts(SDL_GetError());MIX_Quit();}
 if(NET_Init()){NET_Address*a=NET_ResolveHostname("example.com");if(a){if(NET_WaitUntilResolved(a,5000)==NET_SUCCESS)std::puts("OK: ネット接続/DNS名前解決");else std::puts(SDL_GetError());NET_UnrefAddress(a);}else std::puts(SDL_GetError());NET_Quit();}
 Uint64 end=SDL_GetTicks()+5000; while(SDL_GetTicks()<end){SDL_Event e;while(SDL_PollEvent(&e)){if(e.type==SDL_EVENT_TEXT_INPUT)std::printf("IME TEXT_INPUT: %s\n",e.text.text);if(e.type==SDL_EVENT_TEXT_EDITING)std::printf("IME TEXT_EDITING: %s\n",e.edit.text);}SDL_Delay(10);} SDL_DestroyRenderer(r);SDL_DestroyWindow(w);SDL_Quit();return 0;}
''',encoding='utf-8')
    (TEST/'build_test.sh').write_text(r'''#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
P=/home/pi/root/sys/env/sdl/current
source /etc/profile.d/sdl3.sh
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export SDL_TEST_FONT="${SDL_TEST_FONT:-assets/DejaVuSans.ttf}"
g++ test_sdl3_full.cpp -o test_sdl3_full $(pkg-config --cflags --libs sdl3 sdl3-image sdl3-ttf sdl3-mixer sdl3-net)
./test_sdl3_full
''',encoding='utf-8'); (TEST/'build_test.sh').chmod(0o755)

def run_test(e):
    run(['bash',str(TEST/'build_test.sh')],e,TEST)

def uninstall():
    root()
    if INSTALL.exists():
        for d in list(INSTALL.iterdir()):
            if d.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+',d.name): shutil.rmtree(d)
        c=INSTALL/'current'; c.unlink(missing_ok=True)
    for p in [Path('/etc/profile.d/sdl3.sh'),Path('/etc/ld.so.conf.d/sdl3.conf')]: p.unlink(missing_ok=True)
    run(['ldconfig']); log('/tmp/sdl と /tmp/sdl-test は削除していません。')

def help_():
    print('SDLの最新安定版をインストールする。\nGitHubにあるZipからソースコードをダウンロードしてビルドしインストールする。\nラズパイ4B(4GB)で動作させることを想定している。\n  install    インストールする。\n  uninstall  アンインストールする。\n  version    バージョンを表示する。\n  help       ヘルプを表示する。')
def main():
    a=sys.argv[1:]
    if not a or a[0]=='help': help_(); return 0
    if a[0]=='install' and len(a)==1: install(); return 0
    if a[0]=='uninstall' and len(a)==1: uninstall(); return 0
    if a[0]=='version':
        v=versions(); key=a[1] if len(a)>1 else 'sdl'
        if key=='all':
            for k in ['sdl','image','mixer','net','ttf']: print(f'{k}\t{v[k]}')
        elif key in PC and key in v: print(v[key])
        else: help_()
        return 0
    help_(); return 0
try: raise SystemExit(main())
except KeyboardInterrupt: print('\n中断しました。作業データは保持しています。',file=sys.stderr); raise SystemExit(130)
except Exception as e: print(f'\nエラー: {e}',file=sys.stderr); raise SystemExit(1)
