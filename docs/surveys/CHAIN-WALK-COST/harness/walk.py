#!/usr/bin/env python3
"""Local-only harness: time document_chain_walk / record_trail as a real role holder inside a rolled-back txn.
usage: walk.py <db> <role> walk <chain> <step_id> <key> <doc_id>   |   walk.py <db> <role> trail <subject> <id>
prints: exec ms, rows, top functions by calls/self time (pg_stat_xact_user_functions)."""
import json, subprocess, sys, os
SP = os.path.dirname(os.path.abspath(__file__))
USERS = {'admin': '321f1819-8449-48f7-9ae0-78b2c4b50f35', 'cco': '01ae00e4-306f-4527-8537-10291e4750c7',
         'cfo': '634c00f9-c3a9-4444-9eed-b624cb6a2a93', 'cto': 'e61d99f2-2b95-4059-86f8-5aef8b5cffb5',
         'finance': '476bf8c8-c248-4352-9a75-945bf52ca390', 'gm': '09496449-52a3-4af4-8f3b-7cf16ccc9dc5',
         'warehouse': 'c8116e6c-80db-4a16-be12-24fb6ce6859d'}
CH = json.load(open(os.path.join(SP, 'chains.json')))
if os.environ.get('SEED_USERS'):   # db/seeds/chain-walk-year.sql: md5('cwc-user-<n>')::uuid, n by role code order
    import hashlib, uuid as _u
    USERS = {r: str(_u.UUID(hashlib.md5(f'cwc-user-{i}'.encode()).hexdigest())) for i, r in enumerate(sorted(USERS), 1)}


def call_sql(kind, args):
    if kind == 'walk':
        chain, step_id, key, doc = args
        c = CH[chain]
        step = c['steps'].index(step_id)
        d = json.dumps(c['def']).replace("'", "''")
        return f"SELECT * FROM document_chain_walk('{d}'::jsonb, {step}, '{key}', '{doc}')"
    subj, rid = args
    return f"SELECT * FROM record_trail('{subj}', '{rid}', 20)"


def run(db, role, kind, args, top=12, plan=False):
    uid = USERS[role]
    q = call_sql(kind, args)
    sql = f"""BEGIN;
SELECT set_config('app.chain_walk_budget_ms', '{os.environ.get("BUDGET_MS","")}', true) \\g /dev/null
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {q};
SELECT 'ROWS|' || count(*) FROM ({q}) z;
RESET ROLE;
SELECT 'FN|' || funcname || '|' || calls || '|' || round(total_time::numeric,1) || '|' || round(self_time::numeric,1)
  FROM pg_stat_xact_user_functions ORDER BY self_time DESC LIMIT {top};
ROLLBACK;"""
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        return {'error': r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'psql failed'}
    out = r.stdout
    j = json.loads(out[out.index('['):out.index(']\n') + 1]) if '[' in out else None
    p = j[0] if j else {}
    res = {'exec_ms': round(p.get('Execution Time', -1), 1),
           'shared_hit': p.get('Plan', {}).get('Shared Hit Blocks'),
           'rows': next((int(l[5:]) for l in out.splitlines() if l.startswith('ROWS|')), None),
           'fns': [l[3:] for l in out.splitlines() if l.startswith('FN|')]}
    # pg_stat_xact counts both the EXPLAIN run and the count run → halve calls for readability
    return res


if __name__ == '__main__':
    db, role, kind, *args = sys.argv[1:]
    res = run(db, role, kind, args)
    print(json.dumps(res, ensure_ascii=False, indent=1))
