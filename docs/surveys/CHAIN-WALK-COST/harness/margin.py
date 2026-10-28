#!/usr/bin/env python3
"""LOCAL ONLY. inbound_batch_margin(batch) on every Nth inbound batch × seven roles; worst ms per role; refusals by code; optional result hash for equality.
usage: margin.py db every_n"""
import json, subprocess, sys, hashlib
from walk import USERS
db, every = sys.argv[1], int(sys.argv[2])
def psql(sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'], input=sql, capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr[-1500:])
    return r.stdout
ids = [l for l in psql(f"select id from (select id, row_number() over (order by code) rn from inbound_batches) z where rn % {every} = 1").splitlines()]
out = {}
for role, uid in USERS.items():
    lines = ["SET statement_timeout = 0;", """CREATE FUNCTION pg_temp.m(p uuid, OUT ms numeric, OUT h text, OUT err text) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); v jsonb; BEGIN v := public.inbound_batch_margin(p);
  ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1); h := md5(v::text);
EXCEPTION WHEN OTHERS THEN ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1); err := split_part(SQLERRM, '|', 1); END $$;""",
             "BEGIN;", "SET LOCAL ROLE authenticated;", f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
    for i in ids: lines.append(f"SELECT 'M|{i}|' || ms || '|' || coalesce(h,'') || '|' || coalesce(err,'') FROM pg_temp.m('{i}');")
    lines.append("ROLLBACK;")
    rs = [l.split('|') for l in psql("\n".join(lines)).splitlines() if l.startswith('M|')]
    out[role] = {r[1]: {'ms': float(r[2]), 'h': r[3], 'err': r[4]} for r in rs}
    ok = [r for r in out[role].values() if not r['err']]
    errs = sorted({r['err'] for r in out[role].values() if r['err']})
    print(f"{role:10} batches {len(ids)} · worst {max((r['ms'] for r in ok), default=0):.1f} ms · median {sorted(r['ms'] for r in ok)[len(ok)//2] if ok else 0:.1f} · refused {len(out[role]) - len(ok)} {errs}")
json.dump(out, open(f'margin-{db}.json', 'w'))
