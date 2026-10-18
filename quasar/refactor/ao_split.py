#!/usr/bin/env python3
"""把 audio/out/ao_avfoundation.m 按职责切成两个文件（只搬代码，压缩音频 AVPlayer 旁路单独成文件）。用法：ao_split.py <quasar-mpv>
分配表：声明起始行 -> 目标。上方紧挨的注释随声明走。跨文件调用的 static 函数去掉 static、补 ao_avf_ 前缀、在共享头里声明。"""
import re, sys, os, json
HERE = os.path.dirname(os.path.abspath(__file__))
Q = sys.argv[1]; SRC = f'{Q}/audio/out/ao_avfoundation.m'
L = open(SRC).read().split('\n')          # L[i-1] 是第 i 行
N = len(L)
H, HI, M, AVP = 'H', 'HI', 'M', 'AVP'
A = {43:H,50:H,59:H,154:HI,163:H,195:M,197:M,199:HI,205:M,210:HI,216:HI,785:M,849:M,941:M,984:M,1011:M,
     1065:M,1148:M,1173:AVP,1231:M,1491:M,1534:M}
for s_ in [225,241,262,276,315,376,487,503,573,608,637,705,744]: A[s_] = AVP

def is_comment(t):
    t = t.strip()
    return t.startswith('//') or t.startswith('/*') or t.startswith('*') or t.endswith('*/')
starts = []
for s in sorted(A):
    b = s
    while b - 1 > 42 and L[b - 2].strip() and is_comment(L[b - 2]): b -= 1
    starts.append((b, A[s], s))
segs = []
for i, (b, t, s) in enumerate(starts):
    e = (starts[i + 1][0] - 1) if i + 1 < len(starts) else N
    segs.append({'from': b, 'to': e, 'target': t, 'decl': s, 'text': L[b - 1:e]})
assert segs[0]['from'] == 43

# 每段定义的函数名（声明行里第一个 "名字(" ）
fn_re = re.compile(r'^static\s+(?:inline\s+)?[^=;(]*?\b([A-Za-z_]\w*)\s*\(')
for g in segs:
    m = fn_re.match(L[g['decl'] - 1]) if L[g['decl'] - 1].startswith('static') else None
    g['fn'] = m.group(1) if m and not L[g['decl'] - 1].rstrip().endswith(';') else None
files = {}
def where(t): return {HI: H}.get(t, t)
for g in segs: files.setdefault(where(g['target']), []).append(g)
def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    return re.sub(r'//[^\n]*', ' ', s)
text_of = lambda t: strip_comments('\n'.join('\n'.join(g['text']) for g in files[t]))
# 跨文件调用的函数：定义在 X 的 .m，名字出现在别的文件里
exported = {}
for t, gs in files.items():
    if t == H: continue
    for g in gs:
        if not g['fn']: continue
        pat = re.compile(r'\b%s\s*\(' % re.escape(g['fn']))
        if any(pat.search(text_of(o)) for o in files if o != t):
            exported[g['fn']] = 'ao_avf_' + g['fn']
ren = {k: v for k, v in exported.items() if k != v}
def apply_ren(s):
    for k, v in ren.items(): s = re.sub(r'\b%s\b' % re.escape(k), v, s)
    return s
protos = []
for t, gs in files.items():
    for g in gs:
        lines = list(g['text'])
        di = g['decl'] - g['from']
        if g['target'] == HI:
            lines[di] = lines[di].replace('static ', 'static inline ', 1)
        if g['fn'] in exported:
            lines[di] = lines[di].replace('static ', '', 1)
            sig = []
            for l in lines[di:]:
                if l.strip() == '{' : break
                if l.rstrip().endswith('{'): sig.append(l.rstrip()[:-1].rstrip()); break
                sig.append(l)
            protos.append(apply_ren('\n'.join(sig)) + ';')
        # 原文里的 static 前置声明：函数改成跨文件后删掉（头里有声明）
        lines = [l for l in lines if not (re.match(r'^static .*\b(%s)\s*\(.*\);\s*$' % '|'.join(map(re.escape, exported)), l) if exported else False)]
        g['out'] = apply_ren('\n'.join(lines))
lic = '\n'.join(L[0:16])
inc = [l for l in L[16:42]]
H_inc = '\n'.join(inc)
out = {}
out['ao_avfoundation_priv.h'] = (lic + '\n\n// Shared by ao_avfoundation.m and ao_avfoundation_avplayer.m: state, constants, small\n'
    '// helpers and the functions one file calls in another.\n\n#pragma once\n' + H_inc.rstrip() + '\n'
    + '\n'
    + '\n'.join(g['out'] for g in files[H]).rstrip() + '\n\n' + '\n\n'.join(protos) + '\n')
names = {M: 'ao_avfoundation.m', AVP: 'ao_avfoundation_avplayer.m'}
for t, fn in names.items():
    out[fn] = lic + '\n\n#include "ao_avfoundation_priv.h"\n\n' + '\n'.join(g['out'] for g in files[t]).strip('\n') + '\n'
for fn, s in out.items(): open(f'{Q}/audio/out/{fn}', 'w').write(s)
json.dump({'segments': [{k: g[k] for k in ('from', 'to', 'target', 'decl', 'fn')} for g in segs],
           'exported': exported}, open(os.path.join(HERE, 'ao_plan.json'), 'w'), indent=1)
print('exported', len(exported), 'renamed', len(ren)); print(sorted(ren.items()))
print({fn: s.count('\n') for fn, s in out.items()})
