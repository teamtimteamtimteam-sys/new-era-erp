#!/usr/bin/env python3
"""LOCAL ONLY. Same results, row for row: walk A (db A, fn A) vs walk B (db B, fn B) for every chain document (or a sample) × seven roles.
usage: diff2.py <dbA> <fnA> <dbB> <fnB> [--sample N]   env SEED_USERS=1 for the seeded readers, BUDGET_MS to lift the budget.
Compares the full row set (step, key, id, code, label, href) as JSON, ordered."""
import json, subprocess, sys, os
from walk import USERS, CH
from survey import PAGES
dbA, fnA, dbB, fnB = sys.argv[1:5]
sample = int(sys.argv[sys.argv.index('--sample') + 1]) if '--sample' in sys.argv else None
def psql(db, sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'], input=sql, capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr[-1500:])
    return r.stdout
types = json.loads(psql(dbA, "select json_agg(json_build_object('key',key,'table',table_name,'prefix',prefix)) from document_types"))
calls = []
for route, table, specs in PAGES:
    docs = json.loads(psql(dbA, f"select coalesce(json_agg(json_build_object('id',id,'code',code) order by code),'[]') from public.{table}"))
    if sample: docs = docs[::max(1, len(docs) // sample)]
    mine = [t for t in types if t['table'] == table]
    for d in docs:
        me = mine[0] if len(mine) == 1 else next((t for t in mine if (d['code'] or '').startswith(t['prefix'] + '-')), None)
        if not me: continue
        for chain, step in specs:
            at = CH[chain]['steps'].index(step)
            if me['key'] in CH[chain]['def']['steps'][at]['keys']: calls.append((chain, at, me['key'], d['id'], d['code']))
def run(db, fn, uid):
    lines = ["BEGIN;", f"SELECT set_config('app.chain_walk_budget_ms', '{os.environ.get('BUDGET_MS','')}', true) \\g /dev/null",
             "SET LOCAL ROLE authenticated;", f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
    for i, (chain, at, key, did, code) in enumerate(calls):
        dj = json.dumps(CH[chain]['def']).replace("'", "''")
        lines.append(f"SELECT 'W|{i}|' || coalesce(jsonb_agg(to_jsonb(w) ORDER BY w.step, w.code, w.id)::text, '[]') FROM public.{fn}('{dj}'::jsonb, {at}, '{key}', '{did}') w;")
    lines.append("ROLLBACK;")
    return {int(l.split('|', 2)[1]): l.split('|', 2)[2] for l in psql(db, "\n".join(lines)).splitlines() if l.startswith('W|')}
same = diff = rows = 0; bad = []
for role, uid in USERS.items():
    a, b = run(dbA, fnA, uid), run(dbB, fnB, uid)
    for i, c in enumerate(calls):
        if a[i] == b[i]: same += 1; rows += len(json.loads(a[i]))
        else: diff += 1; bad.append((role, c[0], c[4], len(json.loads(a[i])), len(json.loads(b[i]))))
    print(f'{role} done', file=sys.stderr)
print(f'DIFF|{dbA}.{fnA} vs {dbB}.{fnB}: {len(calls)} walks × {len(USERS)} roles = {len(calls)*len(USERS)} · identical {same} ({rows} rows) · different {diff}')
for x in bad[:20]: print('  DIFFERS', x)
