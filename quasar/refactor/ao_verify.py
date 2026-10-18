#!/usr/bin/env python3
"""ao_avfoundation.m 拆分等价检查（严格，同 verify.py）：对原文件每一段只做预期的变换（目标为 HI 的声明行加 inline；跨文件函数的声明行去 static；
删掉这些函数原来的 static 前置声明；按 plan 改名），结果必须按原顺序逐字出现在目标文件里。
各文件剩下的只能是：许可头、原文件的 include 块（共享头里）、共享头的 include、#pragma once、共享头开头的说明注释、
跨文件函数的声明（与定义的签名逐字一致）。用法：ao_verify.py <拆分前的 ao_avfoundation.m> <quasar-mpv>"""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
orig = open(sys.argv[1]).read().split('\n'); Q = sys.argv[2]
plan = json.load(open(os.path.join(HERE, 'ao_plan.json')))
exp = plan['exported']; ren = {k: v for k, v in exp.items() if k != v}
names = {'H': 'ao_avfoundation_priv.h', 'HI': 'ao_avfoundation_priv.h', 'M': 'ao_avfoundation.m', 'AVP': 'ao_avfoundation_avplayer.m'}
proto_re = re.compile(r'^static .*\b(%s)\s*\(.*\);\s*$' % '|'.join(map(re.escape, exp)))
def renamed(s):
    for k, v in ren.items(): s = re.sub(r'\b%s\b' % re.escape(k), v, s)
    return s
new = {f: open(f'{Q}/audio/out/{f}').read() for f in set(names.values())}
pos = {f: 0 for f in new}; spans = {f: [] for f in new}; protos = []
bad = 0; cover = set()
for g in plan['segments']:
    lines = list(orig[g['from'] - 1:g['to']]); di = g['decl'] - g['from']
    cover.update(range(g['from'], g['to'] + 1))
    if g['target'] == 'HI':
        if not lines[di].startswith('static ') or lines[di].startswith('static inline'): bad += 1; print('HI decl not plain static', g['decl'])
        lines[di] = 'static inline ' + lines[di][7:]
    if g['fn'] in exp:
        if not lines[di].startswith('static '): bad += 1; print('exported decl not static', g['decl'])
        lines[di] = lines[di][7:]
        sig = []
        for l in lines[di:]:
            if l.strip() == '{': break
            if l.rstrip().endswith('{'): sig.append(l.rstrip()[:-1].rstrip()); break
            sig.append(l)
        protos.append(renamed('\n'.join(sig)) + ';')
    lines = [l for l in lines if not proto_re.match(l)]
    seg = renamed('\n'.join(lines)).strip('\n')
    f = names[g['target']]
    i = new[f].find(seg, pos[f]) if seg else pos[f]
    if i < 0: bad += 1; print('MISSING or out of order', g['from'], g['to'], f); continue
    spans[f].append((i, i + len(seg))); pos[f] = i + len(seg)
missing = [i for i in range(43, len(orig) + 1) if i not in cover]
lic = '\n'.join(orig[:16]); inc = '\n'.join(orig[16:42]).strip('\n')
for f, s in new.items():
    # 段与段之间只能是空行
    prev = None
    for a, b in spans[f]:
        if prev is not None and s[prev:a].strip('\n'): bad += 1; print(f, 'text between segments:', repr(s[prev:a][:60]))
        prev = b
    head = lic + ('\n\n// Shared by' if f == 'ao_avfoundation_priv.h' else '\n\n#include "ao_avfoundation_priv.h"\n')
    if not s.startswith(head): bad += 1; print(f, 'unexpected file header')
    for a, b in reversed(spans[f]): s = s[:a] + s[b:]
    s = s.replace(lic, '', 1)
    if f == 'ao_avfoundation_priv.h':
        if inc not in s: bad += 1; print('include block changed')
        s = s.replace(inc, '', 1)
        s = s.replace('// Shared by ao_avfoundation.m and ao_avfoundation_avplayer.m: state, constants, small\n'
                      '// helpers and the functions one file calls in another.', '', 1).replace('#pragma once', '', 1)
        for pr in protos:
            if s.count(pr) != 1: bad += 1; print('declaration missing: ' + pr[:60])
            s = s.replace(pr, '', 1)
    else:
        s = s.replace('#include "ao_avfoundation_priv.h"', '', 1)
    extra = [l for l in s.split('\n') if l.strip()]
    print(f, 'extra lines:', extra[:8] or 'none'); bad += bool(extra)
print('uncovered original lines:', missing[:10] or 'none')
print('RESULT', 'OK' if not bad and not missing else 'FAIL')
