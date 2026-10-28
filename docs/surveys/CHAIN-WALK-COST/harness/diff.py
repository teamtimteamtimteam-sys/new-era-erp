#!/usr/bin/env python3
"""LOCAL ONLY. old walk vs prototype walk: identical rows for every document × seven roles (set of (step,key,id,code,label,href))."""
import json, subprocess, sys
from walk import USERS, CH
from survey import PAGES
db = sys.argv[1]
def psql(sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'], input=sql, capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr[-1500:])
    return r.stdout
reps = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else None
types = json.loads(psql("select json_agg(json_build_object('key',key,'table',table_name,'prefix',prefix)) from document_types"))
calls = []
for route, table, specs in PAGES:
    docs = json.loads(psql(f"select coalesce(json_agg(json_build_object('id',id,'code',code)),'[]') from public.{table}"))
    mine = [t for t in types if t['table'] == table]
    for d in docs:
        me = mine[0] if len(mine) == 1 else next((t for t in mine if (d['code'] or '').startswith(t['prefix'] + '-')), None)
        if not me: continue
        for chain, step in specs:
            at = CH[chain]['steps'].index(step)
            if me['key'] in CH[chain]['def']['steps'][at]['keys']: calls.append((chain, at, me['key'], d['id'], d['code']))
same = diff = 0; bad = []
for role, uid in USERS.items():
    lines = ["BEGIN;", "SET LOCAL ROLE authenticated;", f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
    for i, (chain, at, key, did, code) in enumerate(calls):
        dj = json.dumps(CH[chain]['def']).replace("'", "''")
        for fn in ('document_chain_walk', 'document_chain_walk2'):
            lines.append(f"SELECT '{fn}|{i}|' || coalesce(json_agg(w ORDER BY w.step, w.code, w.id)::text, '[]') FROM public.{fn}('{dj}'::jsonb, {at}, '{key}', '{did}') w;")
    lines.append("ROLLBACK;")
    res = {}
    for l in psql("\n".join(lines)).splitlines():
        if '|' in l and l.startswith('document_chain_walk'):
            fn, i, j = l.split('|', 2); res[(fn, int(i))] = j
    for i, c in enumerate(calls):
        a, b = res[('document_chain_walk', i)], res[('document_chain_walk2', i)]
        if a == b: same += 1
        else: diff += 1; bad.append((role, c[0], c[4], len(json.loads(a)), len(json.loads(b))))
print(f'DIFF|{len(calls)} walks × {len(USERS)} roles: identical {same} · different {diff}')
for x in bad[:20]: print('  DIFFERS', x)
