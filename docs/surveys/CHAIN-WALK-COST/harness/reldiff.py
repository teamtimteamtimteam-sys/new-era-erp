#!/usr/bin/env python3
"""LOCAL ONLY. The other readers of what this cut changed, before (dbA) vs after (dbB), seven roles:
  search_related(key,id) and search_related_rows(key,id,target,100) for every chain document and every non-empty target group
  (document_relation_arm_ids now delegates to document_relation_arm_pairs), document_detail_hrefs(key, all ids of that key)
  (now the set implementation), change_log_rows (latest 200 operations + per-table first page — it reads the trail helpers).
usage: reldiff.py dbA dbB [--sample N]"""
import json, subprocess, sys
from walk import USERS
from survey import PAGES
dbA, dbB = sys.argv[1:3]
sample = int(sys.argv[sys.argv.index('--sample') + 1]) if '--sample' in sys.argv else None


def psql(db, sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'], input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr[-1500:])
    return r.stdout


types = json.loads(psql(dbA, "select json_agg(json_build_object('key',key,'table',table_name,'prefix',prefix)) from document_types"))
docs = []   # (key, id)
for route, table, specs in PAGES:
    rows = json.loads(psql(dbA, f"select coalesce(json_agg(json_build_object('id',id,'code',code) order by code),'[]') from public.{table}"))
    if sample:
        rows = rows[::max(1, len(rows) // sample)]
    mine = [t for t in types if t['table'] == table]
    for d in rows:
        me = mine[0] if len(mine) == 1 else next((t for t in mine if (d['code'] or '').startswith(t['prefix'] + '-')), None)
        if me and (me['key'], d['id']) not in docs:
            docs.append((me['key'], d['id']))
by_key = {}
for k, i in docs:
    by_key.setdefault(k, []).append(i)
WRAP = """CREATE FUNCTION pg_temp.j(q text) RETURNS text LANGUAGE plpgsql AS $$ DECLARE v text; BEGIN
  EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(z))::text, ''[]'') FROM (' || q || ') z' INTO v; RETURN v;
  EXCEPTION WHEN OTHERS THEN RETURN 'ERR ' || SQLSTATE || ' ' || split_part(SQLERRM, '|', 1); END $$;"""


def lit(q):
    return q.replace("'", "''")


def run(db, uid, queries):
    lines = [WRAP, "BEGIN;", "SET LOCAL ROLE authenticated;",
             f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
    for n, q in enumerate(queries):
        lines.append(f"SELECT 'Q|{n}|' || pg_temp.j('{lit(q)}');")
    lines.append("ROLLBACK;")
    return {int(l.split('|', 2)[1]): l.split('|', 2)[2] for l in psql(db, "\n".join(lines)).splitlines() if l.startswith('Q|')}


tables = ['purchase_orders', 'inbound_batches', 'payments', 'payment_requests', 'journal_entries', 'output_batches', 'sales_orders', 'leave_requests']
stats = {}
bad = []
for role, uid in USERS.items():
    # 1 · counts per group (search_related) — and from them, every non-empty group's rows
    q1 = [f"SELECT * FROM search_related('{k}', '{i}') ORDER BY target_key, target_table" for k, i in docs]
    a1, b1 = run(dbA, uid, q1), run(dbB, uid, q1)
    q2 = []
    for n, (k, i) in enumerate(docs):
        if not a1[n].startswith('ERR'):
            for g in json.loads(a1[n]):
                if g.get('n'):
                    q2.append(f"SELECT * FROM search_related_rows('{k}', '{i}', '{g['target_key']}', 100, NULL) ORDER BY code DESC, id")
    a2, b2 = run(dbA, uid, q2), run(dbB, uid, q2)
    q3 = [f"SELECT * FROM document_detail_hrefs('{k}', ARRAY[{', '.join(repr(x) for x in ids)}]::uuid[])" for k, ids in by_key.items()]
    a3, b3 = run(dbA, uid, q3), run(dbB, uid, q3)
    q4 = ["SELECT seq, table_name, row_key, op, changed_columns, old, new, row_restricted, actor, belongs_to, refs FROM change_log_rows(p_limit => 200) ORDER BY seq DESC"] + \
         [f"SELECT seq, table_name, row_key, op, changed_columns, old, new, row_restricted, actor, belongs_to, refs FROM change_log_rows(p_table => '{t}', p_limit => 50) ORDER BY seq DESC" for t in tables]
    a4, b4 = run(dbA, uid, q4), run(dbB, uid, q4)
    for name, qs, a, b in (('search_related', q1, a1, b1), ('search_related_rows', q2, a2, b2), ('document_detail_hrefs', q3, a3, b3), ('change_log_rows', q4, a4, b4)):
        s = stats.setdefault(name, [0, 0, 0, 0])
        for n in range(len(qs)):
            if a[n] == b[n]:
                s[0] += 1
                if a[n].startswith('ERR'):
                    s[3] += 1
                else:
                    s[2] += len(json.loads(a[n]))
            else:
                s[1] += 1
                bad.append((role, name, qs[n][:120], a[n][:150], b[n][:150]))
    print(f'{role} done', file=sys.stderr)
for name, (same, diff, rows, errs) in stats.items():
    print(f'RELDIFF|{dbA} vs {dbB} · {name}: identical {same} ({rows} rows, {errs} identical refusals) · different {diff}')
for x in bad[:12]:
    print('  DIFFERS', x)
