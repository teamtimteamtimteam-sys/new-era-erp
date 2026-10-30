#!/usr/bin/env python3
# GOLIVE-2 · row 13 · "results identical to today for every role" (Tim Q2) — row-for-row comparison on the local year seed (top reshaped like live).
#   BEFORE = a rebuild of HEAD (8ae2ce2) mirrors (db gl2ref): the page's own loop over change_log_rows (app/settings/change-history/page.tsx:108-141:
#            operations in blocks of 200, rows in pages of 100, p_before / p_row_before keysets) and the dictionaries page's per-value count(*);
#   AFTER  = a rebuild of the working tree (db gl2): one change_log_page call / one dictionary_usage_counts call.
#   Each case, as each of the seven seed readers (SET LOCAL ROLE authenticated + claims, rolled back): the rows as jsonb ordered by seq → md5,
#   or the refusal's SQLSTATE + first token of the message. Local only — never pointed at live.
import json, subprocess, sys
AFTER_DB = sys.argv[2] if len(sys.argv) > 2 else 'gl2'
SOCK = dict(h='/tmp/gl2s', p='55450')
ROLES = {'admin': '7f89668d-5f83-dd1e-214a-0b451e4b09df', 'cco': '1e3ec493-02d8-f158-5f86-6a263e99716e', 'cfo': 'b432a308-6cb1-a8c7-f8d1-72922bdd66cc',
         'cto': 'edc53ce2-4dda-9db2-9bac-f4bd74a60497', 'finance': '125e16f8-62d8-a6e7-b497-71ffab034c8a', 'gm': '505497e7-155d-52fc-f0ef-bcde6f64bc48',
         'warehouse': '1c2ccd77-5325-693d-56b5-3c1a26eb77ce'}

def psql(db, sql):
    r = subprocess.run(['psql', '-h', SOCK['h'], '-p', SOCK['p'], '-U', 'postgres', '-d', db, '-XAt', '-v', 'ON_ERROR_STOP=1', '-f', '-'],
                       input=sql, text=True, capture_output=True)
    out = [l[4:] for l in r.stdout.splitlines() + r.stderr.splitlines() if 'CMP|' in l for l in [l[l.index('CMP|'):]]]
    if r.returncode != 0 and not out:
        sys.exit(f'psql failed on {db}: {r.stderr[-400:]}')
    return out

def wrap(uid, body):
    return f"""BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null
DO $c$
DECLARE v_txt text;
BEGIN
{body}
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'CMP|refused % %', SQLSTATE, split_part(SQLERRM, '|', 1);
END $c$;
ROLLBACK;
"""

# a record id and an actor that the seed really has
probe = psql('gl2ref', "SELECT 'CMP|' || (SELECT row_key->>'id' FROM change_log WHERE table_name = 'inbound_batches' ORDER BY seq DESC LIMIT 1) || '|' || (SELECT actor_account FROM change_log WHERE actor_account IS NOT NULL GROUP BY 1 ORDER BY count(*) DESC LIMIT 1);")[0].split('|')
REC, ACT = probe[0], probe[1]
CASES = [  # name, show, keyOnly, sql args (named, shared by both readers)
    ('show20', 20, False, ''),
    ('show500', 500, False, ''),
    ('key-only20', 20, True, ''),
    ('area-finance40', 40, False, "p_tables => ARRAY['journal_entries','journal_lines','payments','payment_allocations']"),
    ('type-inbound20', 20, False, "p_table => 'inbound_batches'"),
    ('record20', 20, False, f"p_record_ids => ARRAY['{REC}']"),
    ('who20', 20, False, f"p_actor => '{ACT}'::uuid"),
    ('dates20', 20, False, "p_from => '2025-02-01', p_to => '2025-02-03'"),
    ('system20', 20, False, "p_no_session => true"),
]

def before_body(show, key, args):
    a = (args + ', ') if args else ''
    target = min(show * 5, 1000) if key else show + 1
    return f"""    CREATE TEMP TABLE cmp_rows ON COMMIT DROP AS SELECT x.* FROM change_log_rows() x WHERE false;
    DECLARE v_target int := {target}; v_read int := 0; v_before bigint; v_rowbefore bigint; v_want int; v_part int; v_tops int; v_mx bigint;
    BEGIN
        WHILE v_read < v_target LOOP
            v_want := LEAST(200, v_target - v_read);
            CREATE TEMP TABLE IF NOT EXISTS cmp_chunk ON COMMIT DROP AS SELECT x.* FROM change_log_rows() x WHERE false;
            TRUNCATE cmp_chunk;
            v_rowbefore := NULL;
            LOOP
                INSERT INTO cmp_chunk SELECT * FROM change_log_rows({a}p_by_entry => true, p_before => v_before, p_limit => v_want, p_row_before => v_rowbefore, p_row_limit => 100);
                GET DIAGNOSTICS v_part = ROW_COUNT;
                EXIT WHEN v_part < 100;
                SELECT min(seq) INTO v_rowbefore FROM (SELECT seq FROM cmp_chunk ORDER BY seq LIMIT v_part) s;
            END LOOP;
            INSERT INTO cmp_rows SELECT * FROM cmp_chunk;
            SELECT count(*), min(mx) INTO v_tops, v_mx FROM (SELECT txid, max(seq) mx FROM cmp_chunk GROUP BY txid) g;
            v_read := v_read + v_tops;
            EXIT WHEN v_tops < v_want;
            v_before := v_mx;
        END LOOP;
    END;
    SELECT count(*) || ' rows ' || md5(COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.seq)::text, '')) INTO v_txt FROM cmp_rows r;
    RAISE NOTICE 'CMP|%', v_txt;"""

def after_body(show, key, args):
    a = (args + ', ') if args else ''
    target = min(show * 5, 1000) if key else show + 1
    return f"""    SELECT count(*) || ' rows ' || md5(COALESCE(jsonb_agg(e ORDER BY (e->>'seq')::bigint)::text, '')) INTO v_txt
      FROM jsonb_array_elements(change_log_page({a}p_entries => {target}) -> 'rows') e;
    RAISE NOTICE 'CMP|%', v_txt;"""

# dictionaries: the registry pairs; BEFORE = one count(*) per (value, ref) like page.tsx:156-162; AFTER = dictionary_usage_counts summed the same way
pairs = json.load(open(sys.argv[1]))
refs = [{'dict': x['table'], 'ref_table': r.split('.')[0], 'ref_column': r.split('.')[1]} for x in pairs for r in x['refs']]
RJ = json.dumps(refs).replace("'", "''")
dict_before = f"""    SELECT md5(COALESCE(jsonb_agg(jsonb_build_array(d, code, n) ORDER BY d, code)::text, '')) || ' over ' || count(*) || ' values' INTO v_txt FROM (
      SELECT p.dict AS d, v.code, sum(pg_temp.cnt(p.ref_table, p.ref_column, v.code)) AS n
        FROM jsonb_to_recordset('{RJ}'::jsonb) AS p(dict text, ref_table text, ref_column text)
        CROSS JOIN LATERAL pg_temp.codes(p.dict) v(code) GROUP BY 1, 2) s;
    RAISE NOTICE 'CMP|%', v_txt;"""
dict_after = f"""    DECLARE j jsonb := dictionary_usage_counts('{RJ}'::jsonb);
    BEGIN
    SELECT md5(COALESCE(jsonb_agg(jsonb_build_array(d, code, n) ORDER BY d, code)::text, '')) || ' over ' || count(*) || ' values' INTO v_txt FROM (
      SELECT p.dict AS d, v.code, sum(COALESCE((j -> (p.ref_table || '.' || p.ref_column) ->> v.code)::bigint, 0)) AS n
        FROM jsonb_to_recordset('{RJ}'::jsonb) AS p(dict text, ref_table text, ref_column text)
        CROSS JOIN LATERAL pg_temp.codes(p.dict) v(code) GROUP BY 1, 2) s;
    END;
    RAISE NOTICE 'CMP|%', v_txt;"""
HELPERS = """CREATE FUNCTION pg_temp.cnt(t text, c text, v text) RETURNS bigint LANGUAGE plpgsql AS $f$ DECLARE n bigint; BEGIN
  EXECUTE format('SELECT count(*) FROM public.%I WHERE %I = $1', t, c) INTO n USING v; RETURN n; END $f$;
CREATE FUNCTION pg_temp.codes(t text) RETURNS SETOF text LANGUAGE plpgsql AS $f$ BEGIN
  RETURN QUERY EXECUTE format('SELECT code::text FROM public.%I', t); END $f$;
"""

bad = 0
print(f'COMPARE|record filter {REC} · actor filter {ACT}')
for role, uid in ROLES.items():
    for name, show, key, args in CASES + [('dictionaries', 0, False, None)]:
        if name == 'dictionaries':
            b = psql('gl2ref', HELPERS + wrap(uid, dict_before)); a = psql(AFTER_DB, HELPERS + wrap(uid, dict_after))
        else:
            b = psql('gl2ref', wrap(uid, before_body(show, key, args))); a = psql(AFTER_DB, wrap(uid, after_body(show, key, args)))
        same = b == a
        bad += not same
        print(f"{'SAME' if same else 'DIFF'}|{role:9} {name:15} before {b[0] if b else '—'} · after {a[0] if a else '—'}")
print(f'COMPARE_EXIT={1 if bad else 0} ({bad} differing of {len(ROLES) * (len(CASES) + 1)})')
sys.exit(1 if bad else 0)
