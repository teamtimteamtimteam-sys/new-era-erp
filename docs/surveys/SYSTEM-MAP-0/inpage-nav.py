#!/usr/bin/env python3
# SYSTEM-MAP-0 Part 3.3 · 搬家条目的【页内导航】与面包屑:只读仓库。
# ① 每一条搬家 / 多属主条目:仓库里哪些【别的】文件以字面量链到它(href 字面量或模板,'/x' 后面接 ' " ` ? / # 之一);
#    其中落在【旧模块的概览页 / 子导航 / 工具下拉】里的,就是"页内导航与新家相矛盾"的候选。
# ② 每一条搬家条目自己的页面文件夹(page.tsx + 同目录组件,不下钻 [id]):有没有链回【旧模块的落地页】或印旧模块名(t('nav.<旧>'))。
# 量法与它的盲区写在输出头:只认字面量;由变量拼出来的 href(例如 `${base}/x`)看不见 —— 用 '覆盖' 那一行自证扫到了多少文件。
import csv, os, re, sys
ROOT = '.'
moves = [r for r in csv.DictReader(open('docs/surveys/SYSTEM-MAP-0/readings/menu-moves.tsv'), delimiter='\t')]
SAME = {'purchasing': 'purchasing', 'finance': 'finance', 'tools': 'tools', 'settings': 'settings', 'safety': 'safety_compliance', 'hr': 'people'}
def moving(r):
    old = r['modules_today'].split(',')
    return len(old) > 1 or SAME.get(old[0]) != r['target_home'] and not (old[0] in ('operation', 'inventory') and r['target_home'] == 'production_warehouse') and not (old[0] in ('logistics', 'sales') and r['target_home'] == 'sales_logistics')
targets = [r for r in moves if moving(r)]
files = []
for d, _, fs in os.walk('app'):
    for f in fs:
        if f.endswith(('.tsx', '.ts')): files.append(os.path.join(d, f))
files += [os.path.join('lib', f) for f in os.listdir('lib') if f.endswith('.ts')]
src = {f: open(f, encoding='utf8').read() for f in files}
print(f'# 覆盖:扫了 {len(src)} 个文件(app/**/*.ts[x] + lib/*.ts);搬家 / 多属主条目 {len(targets)} 条')
LANDING = {'operation': '/operation', 'inventory': '/inventory', 'tools': '/tools', 'purchasing': '/purchasing', 'logistics': '/logistics', 'finance': '/finance', 'hr': '/hr', 'sales': '/sales', 'settings': '/settings'}
OV_HINT = re.compile(r'^app/(purchasing|logistics|operation|sales|finance|inventory|hr|tools|settings)/[^/\[]+\.tsx$|^app/components/nav/|Subnav')
for r in targets:
    href = r['href']
    pat = re.compile(re.escape(href) + r"(?=['\"`?#/]|\$\{)")
    own_dir = 'app' + href
    hits = []
    for f, s in src.items():
        if f.startswith(own_dir + '/') or f == 'lib/modules.ts': continue
        n = len(pat.findall(s))
        if n:
            lines = [i + 1 for i, l in enumerate(s.split('\n')) if pat.search(l)]
            hits.append((f, lines))
    ov = [(f, l) for f, l in hits if OV_HINT.search(f)]
    print(f"\nENTRY|{href}|{r['modules_today']} -> {r['target_home']}|linked from {len(hits)} other files")
    for f, l in ov: print(f"  NAV-CONTEXT|{f}:{','.join(map(str, l[:6]))}")
    # ② 自己的页面文件夹(含 [id] 等下级,但不进入另一条注册表条目自己的文件夹)链回旧模块落地页 / 印旧模块名
    others = {'app' + x['href'] for x in moves if x['href'] != href}
    own_files = sorted(f for f in src if f.startswith(own_dir + '/') and f.endswith('.tsx')
                       and not any(f.startswith(o + '/') and len(o) > len(own_dir) for o in others))
    if own_files:
        for p in own_files:
            s = src[p]
            for old in r['modules_today'].split(','):
                land = LANDING.get(old)
                for i, line in enumerate(s.split('\n')):
                    if line.strip().startswith('//'): continue
                    if land and re.search(r"href=\{?['\"`]" + re.escape(land) + r"['\"`]", line) or re.search(r"t\(['\"]nav\." + old + r"['\"]\)", line):
                        print(f"  BACK-TO-OLD|{p}:{i + 1}|{line.strip()[:140]}")
