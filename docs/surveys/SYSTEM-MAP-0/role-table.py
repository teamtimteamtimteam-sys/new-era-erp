#!/usr/bin/env python3
# SYSTEM-MAP-0 Part 3.2 · 把 role-reach.json(菜单 + 提醒支,本地重建求值)与 decide-matrix.txt(库里的审批门,本地重建求值)并成一张表。只读那两份读数。
import json, collections
R = 'docs/surveys/SYSTEM-MAP-0/readings/'
reach = json.load(open(R + 'role-reach.json'))
roles = ['admin', 'cfo', 'cco', 'cto', 'finance', 'gm', 'warehouse']
dec = collections.OrderedDict()
for l in open(R + 'decide-matrix.txt'):
    if 'DECIDE|' not in l: continue
    p = l.strip().split('DECIDE|', 1)[1].split('|')
    dec.setdefault(p[1], {})[p[0]] = p[2] == 't'
# 一种审批 ↔ 它在 /tools/reminders 上的支(lib/reminders.ts;没有支的写 None)
ARM = {'payment request': 'payment_request_pending', 'credit note': 'invoice_request_pending', 'GST filing': 'gst_filing_pending',
       'manual journal': 'journal_request_pending', 'asset disposal': 'asset_disposal_pending', 'warehouse request': 'warehouse_request_pending',
       'payroll': 'payroll_request_pending', 'terms': 'terms_request_pending', 'receipt price': 'receipt_price_request_pending',
       'shipping release': 'shipping_release_pending', 'expense claim': None, 'PO ': None, 'salary change': 'salary_change_pending',
       'review approval': 'review_submitted', 'leave': 'leave_pending', 'medical claim': 'claim_pending', 'overtime': None,
       'supplier approve': 'supplier_pending_approval', 'NCR': 'ncr_open', 'capture draft': 'capture_draft_pending',
       'work-order': None, 'stocktake post': 'stocktake_open'}
def arm_of(d): return next(v for k, v in ARM.items() if d.startswith(k))
out = ['| role | permission codes | top-level modules open (of 10 incl. Tools, Settings) | second-level menu entries open (of 112 unique) | entries shown 「受限」 | reminder arms visible (of 72) + HR alerts | approval kinds it can decide (of 26 gates; measured) | decides but no reminder arm | reminder arm visible but cannot decide |',
       '|---|---|---|---|---|---|---|---|---|']
for r in roles:
    v = reach[r]
    mods = [m['id'] for m in v['modules'] if m['allowed']]
    closed_mods = [m['id'] for m in v['modules'] if not m['allowed']]
    ent = {}
    for m in v['modules']:
        for e in m['entries']: ent[e['href']] = e['allowed']
    restricted = sorted(h for h, a in ent.items() if not a)
    arms = {x['itemType']: x['allowed'] for x in v['reminders']}
    can = [d for d, x in dec.items() if x[r]]
    no_arm = [d for d in can if arm_of(d) is None]
    blind = sorted({arm_of(d) for d, x in dec.items() if arm_of(d) and arms.get(arm_of(d)) and not any(dec[d2][r] for d2 in dec if arm_of(d2) == arm_of(d))})
    out.append(f"| {r} | {v['permCount']} | {len(mods)}" + (f" (closed: {', '.join(closed_mods)})" if closed_mods else '') +
               f" | {sum(ent.values())} | {len(restricted)}: {' '.join(restricted) if len(restricted) <= 14 else ' '.join(restricted[:14]) + f' … (+{len(restricted) - 14}, list in role-reach.json)'}"
               f" | {sum(arms.values())}" + (' + HR alerts' if v['hrAlerts'] else ' (no HR alerts)') +
               f" | {len(can)}: {'; '.join(c.split(' (')[0] for c in can) if can else '—'} | {'; '.join(c.split(' (')[0] for c in no_arm) or '—'} | {len(blind)}: {' '.join(blind) or '—'} |")
print('\n'.join(out))
