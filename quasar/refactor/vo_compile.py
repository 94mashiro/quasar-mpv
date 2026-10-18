#!/usr/bin/env python3
"""快速编译检查：用上次 mpvbuild 真实构建的 vo_avfoundation.m 编译参数，编译 quasar-mpv 里 video/out/ 的全部 *avfoundation*.m，
再把这些 .o 合成一个，列出其中以 avf_/vo_avf 开头却没定义的符号（跨文件断链）。用法：vo_compile.py <quasar-mpv 路径>"""
import glob, json, os, shlex, subprocess, sys, tempfile
q = os.path.abspath(sys.argv[1])
w = glob.glob(os.path.expanduser('~/workspace/build-libmpv-ios/MPVUI/.build/mpvbuild/work/mpv/ios-arm64/*/build'))[0]
e = next(x for x in json.load(open(f'{w}/compile_commands.json')) if x['file'].endswith('vo_avfoundation.m'))
args = shlex.split(e['command'])
out = tempfile.mkdtemp()
base = []
skip = False
for a in args:
    if skip: skip = False; continue
    if a in ('-o', '-MF', '-MQ', '-c'): skip = True; continue
    if a in ('-MD',) or a.endswith('vo_avfoundation.m'): continue
    base.append(a.replace('../source', q))
objs = []
ok = True
for src in sorted(glob.glob(f'{q}/video/out/*avfoundation*.m')):
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
    bad = [s for s in und if s.startswith(('_avf_', '_vo_avf', '_avfoundation_'))]
    print('unresolved internal:', bad or 'none')
    ok &= not bad
sys.exit(0 if ok else 1)
