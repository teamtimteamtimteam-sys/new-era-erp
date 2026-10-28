#!/usr/bin/env python3
"""LOCAL ONLY. Same trail, row for row: record_trail fnA on dbA vs fnB on dbB, every chain-page subject × document (or sample) × seven roles
× page sizes. A refusal compares by its named code. usage: tdiff.py dbA fnA dbB fnB [--sample N] [--sizes 5,20,500]"""
import json, subprocess, sys, os
from walk import USERS
from trail_survey import SUBJ
dbA, fnA, dbB, fnB = sys.argv[1:5]
sample = int(sys.argv[sys.argv.index('--sample') + 1]) if '--sample' in sys.argv else None
sizes = [int(x) for x in (sys.argv[sys.argv.index('--sizes') + 1] if '--sizes' in sys.argv else '5,20,500').split(',')]
def psql(db, sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'], input=sql, capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr[-1500:])
    return r.stdout
calls = []
for route, subj, table in SUBJ:
    docs = json.loads(psql(dbA, f"select coalesce(json_agg(id order by code),'[]') from public.{table}"))
    if sample: docs = docs[::max(1, len(docs) // sample)]
    calls += [(subj, d) for d in docs]
def run(db, fn, uid):
    lines = ["""CREATE FUNCTION pg_temp.tr(f text, s text, i text, n int) RETURNS text LANGUAGE plpgsql AS $$ DECLARE v text; BEGIN
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.entry_no, t.seq NULLS LAST, t.occurred_at, t.table_name, t.row_key::text)::text, ''[]'') FROM public.%I($1, $2, $3) t', f) INTO v USING s, i, n;
  RETURN v; EXCEPTION WHEN OTHERS THEN RETURN 'ERR ' || split_part(SQLERRM, '|', 1); END $$;""",
             "BEGIN;", "SET LOCAL ROLE authenticated;", f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
    for i, (subj, d) in enumerate(calls):
        for n in sizes:
            lines.append(f"SELECT 'T|{i}|{n}|' || pg_temp.tr('{fn}', '{subj}', '{d}', {n});")
    lines.append("ROLLBACK;")
    out = {}
    for l in psql(db, "\n".join(lines)).splitlines():
        if l.startswith('T|'):
            _, i, n, v = l.split('|', 3); out[(int(i), int(n))] = v
    return out
same = diff = rows = refused = 0; bad = []
for role, uid in USERS.items():
    a, b = run(dbA, fnA, uid), run(dbB, fnB, uid)
    for k in a:
        if a[k] == b[k]:
            same += 1
            if a[k].startswith('ERR'): refused += 1
            else: rows += len(json.loads(a[k]))
        else: diff += 1; bad.append((role, calls[k[0]], k[1], a[k][:120], b[k][:120]))
    print(f'{role} done', file=sys.stderr)
print(f'TDIFF|{dbA}.{fnA} vs {dbB}.{fnB}: {len(calls)} records × {len(sizes)} page sizes × {len(USERS)} roles = {len(calls)*len(sizes)*len(USERS)} · identical {same} ({rows} rows, {refused} identical named refusals) · different {diff}')
for x in bad[:10]: print('  DIFFERS', x)
