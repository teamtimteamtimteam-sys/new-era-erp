#!/usr/bin/env python3
# SYSTEM-MAP-0 Part 3.3 · lib/modules.ts 每一条 FUNCTIONS 条目 → 它在 2.2/2.3 之下的唯一归属。只读仓库(registry 由 node --experimental-strip-types 从 lib/modules.ts 原样导出)。
# 归属是本脚本里【写明的】映射(BASE + OVERRIDE),每一条 OVERRIDE 都注明它出自 2.2/2.3/2.4 的哪一句;映射不到的条目打 UNMAPPED,不猜。
import json, subprocess, sys
REG = json.loads(subprocess.run(['node', '--experimental-strip-types', '--no-warnings', '-e',
    "import('./lib/modules.ts').then(M=>console.log(JSON.stringify(M.FUNCTIONS)))"], capture_output=True, text=True, check=True).stdout)
# 现模块 → 目标顶层(2.2):运营与库存并成「生产与仓库」;物流并进「销售与物流」;其余同名延续
BASE = {'purchasing': 'purchasing', 'logistics': 'sales_logistics', 'operation': 'production_warehouse', 'inventory': 'production_warehouse',
        'safety': 'safety_compliance', 'sales': 'sales_logistics', 'finance': 'finance', 'hr': 'people', 'tools': 'tools', 'settings': 'settings'}
OVERRIDE = {
    # 2.4(3) 定价只在采购
    '/tools/pricing': ('purchasing', '2.4(3)'), '/tools/pricing/formulas': ('purchasing', '2.4(3)'),
    '/tools/pricing/calculator': ('purchasing', '2.4(3)'), '/tools/pricing/metal-prices': ('purchasing', '2.4(3)'),
    # 2.4(7) 公司执照与仓储安全到安全与合规
    '/purchasing/licences': ('safety_compliance', '2.4(7)'), '/inventory/storage-safety': ('safety_compliance', '2.4(7)'),
    # 2.4(2) 质量独立;2.2 质量:化验、样品、COA、NCR、争议、污染抽检
    '/quality/samples': ('quality', '2.2 Quality'), '/quality/disputes': ('quality', '2.2 Quality'), '/quality/ncr': ('quality', '2.2 Quality'),
    '/quality/coa': ('quality', '2.2 Quality'), '/operation/contamination': ('quality', '2.2 Quality'),
    # 2.4(8) 设备独立;2.2 设备:设备登记、可靠性、仪表与网关、校准、作业类型、备件
    '/operation/equipment': ('equipment', '2.2 Equipment'), '/operation/equipment/reliability': ('equipment', '2.2 Equipment'),
    '/operation/devices': ('equipment', '2.2 Equipment'), '/operation/calibration': ('equipment', '2.2 Equipment'),
    '/operation/operation-types': ('equipment', '2.2 Equipment'),
    # 2.3 九条多属主的唯一归属
    '/inbound': ('production_warehouse', '2.3'), '/inbound/receive': ('production_warehouse', '2.3'), '/output': ('production_warehouse', '2.3'),
    '/operation/weighbridge': ('production_warehouse', '2.3'), '/hr/overtime': ('people', '2.3'), '/sales/commissions': ('sales_logistics', '2.3'),
    '/finance/freight': ('sales_logistics', '2.3 + 2.4(6)'), '/finance/self-approved': ('finance', '2.3'), '/settings/change-history': ('settings', '2.3'),
    # 2.2 我的工作台:我的任务;2.4(11) 提醒页搬到工作台下
    '/tools/tasks': ('workbench', '2.2 My workbench'), '/tools/reminders': ('workbench', '2.4(11)'),
}
NOTES = {
    '/operation/capture/inbox': 'parent=/operation/devices (Equipment) while /operation/capture is "data capture" (Production) — parent follows Equipment unless re-parented',
    '/finance/claims': '2.2 People: "claims (medical and general in one entry, two kinds)" vs 2.2 Finance "existing six groups" — where the general-claims queue sits is not stated',
    '/hr/claims': '2.4(5): one entry, two kinds — today this page lists medical claims only',
    '/operation/calibration': 'today parent=/operation/devices (not a menu row); 2.2 lists calibration as its own Equipment entry',
    '/operation/equipment/reliability': 'today parent=/operation/equipment (not a menu row); 2.2 lists reliability as its own Equipment entry',
    '/settings/pending-values': 'gate module.processing.view; stays Settings (2.2 Settings unchanged)',
}
rows = []
for f in REG:
    old = list(f['modules'])
    if f['href'] in OVERRIDE: new, why = OVERRIDE[f['href']]
    elif len(old) == 1 and old[0] in BASE: new, why = BASE[old[0]], 'module merge' if BASE[old[0]] != old[0] else 'unchanged'
    else: new, why = 'UNMAPPED', ''
    rows.append((f['href'], ','.join(old), new, why, f.get('parent') or '', f.get('group') or '', NOTES.get(f['href'], '')))
SAME = {'purchasing': 'purchasing', 'finance': 'finance', 'tools': 'tools', 'settings': 'settings', 'safety': 'safety_compliance', 'hr': 'people'}
print('href\tmodules_today\ttarget_home\tsource\tparent\tgroup\tnote')
for r in rows: print('\t'.join(r))
def kind(r):
    old = r[1].split(',')
    if r[2] == 'UNMAPPED': return 'unmapped'
    if len(old) > 1: return 'multi->single'
    if SAME.get(old[0]) == r[2]: return 'same home'
    if BASE.get(old[0]) == r[2]: return 'module renamed/merged only'
    return 'relocated'
from collections import Counter
c = Counter(kind(r) for r in rows)
print(f'# SUMMARY {len(rows)} entries: ' + ' · '.join(f'{k} {v}' for k, v in sorted(c.items())), file=sys.stderr)
for k in ('relocated', 'multi->single', 'unmapped'):
    print(f'# {k}: ' + ' '.join(r[0] for r in rows if kind(r) == k), file=sys.stderr)
