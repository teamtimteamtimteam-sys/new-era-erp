#!/usr/bin/env python3
"""LOCAL ONLY. Q1 proof: for every table whose policies this cut changed, what each of the seven roles can READ is the same, row for row,
before (dbA) and after (dbB). Per (table, role): count + md5 of the sorted md5s of every visible row over the columns authenticated may
SELECT (column-level grants respected); a refusal compares by SQLSTATE. usage: polread.py dbA dbB  (env SEED_USERS=1 for seeded readers)"""
import json, subprocess, sys
from walk import USERS
dbA, dbB = sys.argv[1:3]


def psql(db, sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr[-1500:])
    return r.stdout


# tables touched = public tables whose policy text differs between the two databases
def pols(db):
    return {tuple(l.split('|', 1)) for l in psql(db, "SELECT tablename || '|' || md5(string_agg(policyname || coalesce(qual,'') || coalesce(with_check,''), ',' ORDER BY policyname)) FROM pg_policies WHERE schemaname='public' GROUP BY tablename").splitlines()}
a, b = dict(pols(dbA)), dict(pols(dbB))
touched = sorted(t for t in b if a.get(t) != b.get(t))
cols = json.loads(psql(dbB, """SELECT json_object_agg(c.relname, (SELECT coalesce(json_agg(quote_ident(at.attname) ORDER BY at.attnum), '[]')
         FROM pg_attribute at WHERE at.attrelid = c.oid AND at.attnum > 0 AND NOT at.attisdropped
          AND has_column_privilege('authenticated', c.oid, at.attnum, 'SELECT')))
  FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND c.relname = ANY (%s)""" %
                        ("ARRAY[" + ",".join("'%s'" % t for t in touched) + "]::name[]")))


def run(db, uid):
    lines = ["""CREATE FUNCTION pg_temp.h(q text) RETURNS text LANGUAGE plpgsql AS $$ DECLARE v text; BEGIN
  EXECUTE q INTO v; RETURN v; EXCEPTION WHEN OTHERS THEN RETURN 'ERR ' || SQLSTATE; END $$;""",
             "BEGIN;", "SET LOCAL ROLE authenticated;",
             f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
    for t in touched:
        cl = cols.get(t) or []
        if not cl:
            q = f"SELECT 'nocols ' || count(*) FROM public.{t}"
        else:
            q = (f"SELECT count(*) || ' ' || md5(coalesce(string_agg(h, '' ORDER BY h), '')) FROM "
                 f"(SELECT md5(ROW({', '.join(cl)})::text) AS h FROM public.{t}) z")
        lines.append(f"SELECT 'P|{t}|' || pg_temp.h('{q.replace(chr(39), chr(39) * 2)}');")
    lines.append("ROLLBACK;")
    return {l.split('|', 2)[1]: l.split('|', 2)[2] for l in psql(db, "\n".join(lines)).splitlines() if l.startswith('P|')}


same = diff = rows = errs = 0
bad = []
for role, uid in USERS.items():
    ra, rb = run(dbA, uid), run(dbB, uid)
    for t in touched:
        if ra.get(t) == rb.get(t):
            same += 1
            if ra[t].startswith('ERR'):
                errs += 1
            else:
                rows += int(ra[t].split(' ')[0] if not ra[t].startswith('nocols') else ra[t].split(' ')[1])
        else:
            diff += 1
            bad.append((role, t, ra.get(t), rb.get(t)))
    print(f'{role} done', file=sys.stderr)
print(f'POLREAD|{dbA} vs {dbB}: {len(touched)} tables with changed policies × {len(USERS)} roles = {len(touched) * len(USERS)} · identical {same} '
      f'({rows} visible rows hashed, {errs} identical refusals) · different {diff}')
for x in bad[:20]:
    print('  DIFFERS', x)
