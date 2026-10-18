#!/usr/bin/env python3
"""把 video/out/vo_avfoundation.m 按职责切成多个文件（只搬代码）。用法：split.py <quasar-mpv>
分配表：声明起始行 -> 目标。上方紧挨的注释随声明走。跨文件调用的 static 函数去掉 static、补 avf_ 前缀、在共享头里声明。"""
import re, sys, os, json
Q = sys.argv[1]; SRC = f'{Q}/video/out/vo_avfoundation.m'
L = open(SRC).read().split('\n')          # L[i-1] 是第 i 行
N = len(L)
H, HI, M, SL, BUF, OSD, HDR = 'H', 'HI', 'M', 'SL', 'BUF', 'OSD', 'HDR'
A = {54:H,60:H,77:H,82:H,109:H,133:H,147:M,156:M,238:M,244:M,281:H,283:H,454:M,
     458:HI,463:HI,471:HI,476:HI,493:HI,499:HI,505:HI,510:HI,518:HI,523:HI,
     528:M,540:M,552:M,567:M,574:HI,579:HI,584:HI,589:HI,608:H,610:SL,636:H,665:SL,
     990:M,1002:M,1015:M,1023:M,1045:M,1134:M,1160:M,1183:M,1191:M,1201:M,1261:M,
     1279:OSD,1298:OSD,1322:OSD,1366:OSD,1416:OSD,1422:OSD,1436:OSD,1449:OSD,
     1457:M,1462:M,1518:M,1531:M,1590:M,1631:M,1657:H,
     1659:BUF,1672:BUF,1687:BUF,1692:BUF,1715:BUF,1776:BUF,1825:OSD,1838:BUF,
     1847:BUF,1857:BUF,1873:BUF,1903:BUF,1924:BUF,1981:OSD,1986:OSD,1993:OSD,
     2021:BUF,2032:BUF,2039:BUF,2046:BUF,2074:OSD,2085:OSD,2097:OSD,2132:OSD,2146:OSD,
     2160:BUF,2174:BUF,2195:BUF,2212:BUF,2238:BUF,2265:BUF}
for s in [2370,2430,2458,2496,2534,2643,2661,2678,2695,2714,2736,2771,2829,2882,2942,2958,
          3056,3066,3097,3106,3147,3161,3338,3456]: A[s] = OSD
A[3598] = M
for s in [3641,3650,3715,3724,3749,3787,3819,3827,3935,3960,3968,3989,4024,4055,4065,4089,4168]: A[s] = HDR
for s in [4182,4422,4435,4470,4599,4648]: A[s] = M
A[4662] = OSD; A[4677] = OSD
for s in [4682,4704,4773,4847]: A[s] = M

def is_comment(t):
    t = t.strip()
    return t.startswith('//') or t.startswith('/*') or t.startswith('*') or t.endswith('*/')
starts = []
for s in sorted(A):
    b = s
    while b - 1 > 53 and L[b - 2].strip() and is_comment(L[b - 2]): b -= 1
    starts.append((b, A[s], s))
segs = []
for i, (b, t, s) in enumerate(starts):
    e = (starts[i + 1][0] - 1) if i + 1 < len(starts) else N
    segs.append({'from': b, 'to': e, 'target': t, 'decl': s, 'text': L[b - 1:e]})
assert segs[0]['from'] == 54

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
            exported[g['fn']] = g['fn'] if g['fn'].startswith('avf_') else 'avf_' + g['fn']
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
inc = [l for l in L[16:53]]
hdr_only = {'#include "avfoundation_vivid.h"', '#include "avfoundation_fel.h"'}
H_inc = '\n'.join(l for l in inc if l.strip() not in hdr_only)
out = {}
out['vo_avfoundation_priv.h'] = (lic + '\n\n// Shared by the vo_avfoundation*.m / avfoundation_*.m files: state, options, small\n'
    '// helpers and the functions one file calls in another.\n\n#pragma once\n' + H_inc.rstrip() + '\n'
    + '#include "avfoundation_vivid.h"\n#include "avfoundation_fel.h"\n\n'
    + '\n'.join(g['out'] for g in files[H]).rstrip() + '\n\n' + '\n\n'.join(protos) + '\n')
names = {M: 'vo_avfoundation.m', SL: 'avfoundation_subtitle_layer.m', BUF: 'avfoundation_buffers.m',
         OSD: 'avfoundation_osd.m', HDR: 'avfoundation_hdr.m'}
for t, fn in names.items():
    out[fn] = lic + '\n\n#include "vo_avfoundation_priv.h"\n\n' + '\n'.join(g['out'] for g in files[t]).strip('\n') + '\n'
for fn, s in out.items(): open(f'{Q}/video/out/{fn}', 'w').write(s)
json.dump({'segments': [{k: g[k] for k in ('from', 'to', 'target', 'decl', 'fn')} for g in segs],
           'exported': exported}, open('/tmp/qa-fel/split/plan.json', 'w'), indent=1)
print('exported', len(exported), 'renamed', len(ren)); print(sorted(ren.items()))
print({fn: s.count('\n') for fn, s in out.items()})
