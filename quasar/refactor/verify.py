#!/usr/bin/env python3
"""拆分等价检查：原文件每一段（按 plan.json）只经过改名和 static/inline 调整后，必须原样出现在目标新文件里；
新文件里除这些段以外只允许许可头、include、pragma、注释和函数声明。用法：verify.py <原 vo_avfoundation.m> <quasar-mpv>"""
import json, re, sys
orig = open(sys.argv[1]).read().split('\n'); Q = sys.argv[2]
plan = json.load(open('/tmp/qa-fel/split/plan.json'))
ren = {k: v for k, v in plan['exported'].items() if k != v}
names = {'H': 'vo_avfoundation_priv.h', 'HI': 'vo_avfoundation_priv.h', 'M': 'vo_avfoundation.m',
         'SL': 'avfoundation_subtitle_layer.m', 'BUF': 'avfoundation_buffers.m', 'OSD': 'avfoundation_osd.m', 'HDR': 'avfoundation_hdr.m'}
proto_re = re.compile(r'^static .*\b(%s)\s*\(.*\);\s*$' % '|'.join(map(re.escape, plan['exported'])))
def norm(s):
    s = re.sub(r'\bstatic\s+', '', s); s = re.sub(r'\binline\s+', '', s)
    return s
def renamed(s):
    for k, v in ren.items(): s = re.sub(r'\b%s\b' % re.escape(k), v, s)
    return s
new = {f: open(f'{Q}/video/out/{f}').read() for f in set(names.values())}
rest = dict(new)
bad = 0
cover = set()
for g in plan['segments']:
    lines = [l for l in orig[g['from'] - 1:g['to']] if not proto_re.match(l)]
    cover.update(range(g['from'], g['to'] + 1))
    seg = norm(renamed('\n'.join(lines))).strip('\n')
    f = names[g['target']]
    body = norm(rest[f])
    if seg and seg not in body:
        bad += 1; print('MISSING', g['from'], g['to'], f)
    else:
        i = body.find(seg)
        rest[f] = body[:i] + body[i + len(seg):]
missing = [i for i in range(54, len(orig) + 1) if i not in cover]
print('uncovered original lines:', missing[:10] or 'none')
lic = '\n'.join(orig[:16])
for f, s in rest.items():
    s = s.replace(norm(lic), '')
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    left = [l for l in s.split('\n') if l.strip() and not re.match(r'\s*(#|//|@class)', l)]
    # 函数声明：多行签名合起来以 ; 结尾
    text = '\n'.join(left)
    text = re.sub(r'[^;{}]*?\b(%s)\s*\([^;{}]*\);' % '|'.join(map(re.escape, plan['exported'].values())), '', text, flags=re.S)
    extra = [l for l in text.split('\n') if l.strip()]
    print(f, 'extra lines:', extra[:8] or 'none')
    bad += bool(extra)
print('RESULT', 'OK' if not bad and not missing else 'FAIL')
