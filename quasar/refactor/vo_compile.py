#!/usr/bin/env python3
"""快速编译检查：用上次 mpvbuild 真实构建的编译参数，编译 quasar-mpv 里 video/out/*avfoundation*.m（vo，默认）或 audio/out/ao_avfoundation*.m（ao），
再把这些 .o 合成一个，列出其中以 avf_/ao_avf_ 等开头却没定义的符号（跨文件断链）。用法：vo_compile.py <quasar-mpv 路径> [vo|ao]"""
import glob, json, os, shlex, subprocess, sys, tempfile
q = os.path.abspath(sys.argv[1])
dirs = glob.glob(os.path.expanduser('~/workspace/build-libmpv-ios/MPVUI/.build/mpvbuild/work/mpv/ios-arm64/*/build'))
if not dirs: sys.exit('没有 mpvbuild 的 iOS 构建目录：先在 quasar-app 跑一次 iosApp/tool/build_libmpv.sh')
w = max(dirs, key=os.path.getmtime)  # 最近一次构建的参数
which = sys.argv[2] if len(sys.argv) > 2 else 'vo'
ref, pat = {'vo': ('vo_avfoundation.m', 'video/out/*avfoundation*.m'), 'ao': ('ao_avfoundation.m', 'audio/out/ao_avfoundation*.m')}[which]
e = next(x for x in json.load(open(f'{w}/compile_commands.json')) if x['file'].endswith('/' + ref))
args = shlex.split(e['command'])
out = tempfile.mkdtemp()
base = []
skip = False
for a in args:
    if skip: skip = False; continue
    if a in ('-o', '-MF', '-MQ', '-c'): skip = True; continue
    if a in ('-MD',) or a.endswith('/' + ref): continue
    base.append(a.replace('../source', q))
objs = []
ok = True
for src in sorted(glob.glob(f'{q}/{pat}')):
    o = f'{out}/{os.path.basename(src)}.o'
    r = subprocess.run(base + ['-c', src, '-o', o], cwd=w, capture_output=True, text=True)
    errs = [l for l in r.stderr.splitlines() if 'error' in l or 'warning' in l]
    print(f"{'ok ' if r.returncode == 0 else 'ERR'} {os.path.relpath(src, q)} ({len(errs)} diag)")
    for l in (errs if os.environ.get("FULL") else errs[:15]): print('   ', l.replace(q + '/', ''))
    ok &= r.returncode == 0
    objs.append(o)
if ok:
    subprocess.run(['ld', '-r', '-arch', 'arm64', '-o', f'{out}/all.o'] + objs, check=True, capture_output=True)
    und = subprocess.run(['nm', '-u', f'{out}/all.o'], capture_output=True, text=True).stdout.split()
    bad = [s for s in und if s.startswith(('_avf_', '_vo_avf', '_avfoundation_', '_ao_avf_'))]
    print('unresolved internal:', bad or 'none')
    ok &= not bad
sys.exit(0 if ok else 1)
