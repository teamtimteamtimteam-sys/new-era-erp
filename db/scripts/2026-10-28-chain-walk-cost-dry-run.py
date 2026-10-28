#!/usr/bin/env python3
"""CHAIN-WALK-COST · live dry run (COMMIT -> ROLLBACK). Builds one psql script: lock_timeout 10s · BEGIN · BEFORE readings ·
the migration body (exactly the lines between its BEGIN; and COMMIT; lines — never cut at a semicolon) · AFTER readings · ROLLBACK.
Readings, as two real role holders (tim@ = cfo, the warehouse account), read-only inside the rolled-back transaction:
  walks from six live documents, record_trail of two records, and a row hash of five tables' readable rows — before and after must match;
  then the 2 s walk budget still refuses (app.chain_walk_budget_ms = 0). Prints PROOF| lines; the caller compares B vs A.
usage: python3 db/scripts/2026-10-28-chain-walk-cost-dry-run.py [migration path] > dry-run.sql ; psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f dry-run.sql
(default migration: db/migrations/2026-10-28-chain-walk-cost.sql; -fu1 passes db/migrations/2026-10-29-chain-walk-cost-fu1.sql)"""
import json, os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
mig = open(os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'db/migrations/2026-10-28-chain-walk-cost.sql')).read().split('\n')
b = mig.index('BEGIN;'); c = len(mig) - 1 - mig[::-1].index('COMMIT;')
body = '\n'.join(mig[b + 1:c])
src = open(os.path.join(ROOT, 'lib/chains.ts')).read()
lit = src[src.index('// CHAINS-BEGIN') + 15:src.index('// CHAINS-END')]
import subprocess
chains = json.loads(subprocess.run(['node', '-e', f'console.log(JSON.stringify(eval({json.dumps("(" + lit + ")")})))'], capture_output=True, text=True).stdout)
D = {c['id']: json.dumps({'steps': [{'keys': s['keys'], 'filter': s.get('filter')} for s in c['steps']], 'edges': c['edges']}) for c in chains}
IDX = {c['id']: {s['id']: i for i, s in enumerate(c['steps'])} for c in chains}
READERS = {'cfo': '634c00f9-c3a9-4444-9eed-b624cb6a2a93', 'warehouse': 'c8116e6c-80db-4a16-be12-24fb6ce6859d'}
WALKS = [('PO-2026-0003', 'purchase_orders', 'purchasing', 'purchase_order', 'purchase_order'),
         ('IN-2026-0001', 'inbound_batches', 'processing', 'input_batches', 'inbound_batch'),
         ('OUT-2026-0119', 'output_batches', 'processing', 'output_batches', 'output_batch'),
         ('SHP-2026-0001', 'shipments', 'sales', 'shipment', 'shipment'),
         ('PAY-2026-0001', 'payroll_periods', 'people', 'payroll_period', 'payroll_period'),
         ('BS-2026-0001', 'bank_statements', 'purchasing', 'bank_reconciliation', 'bank_statement')]
TRAILS = [('output_batch', 'output_batches', 'OUT-2026-0119'), ('purchase_order', 'purchase_orders', 'PO-2026-0003')]
TABLES = ['inbound_batches', 'output_batches', 'journal_entries', 'payments', 'leave_requests']

def readings(tag):
    out = []
    for role, uid in READERS.items():
        out.append("SET LOCAL ROLE authenticated;")
        out.append(f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null""")
        for code, table, chain, step, key in WALKS:
            out.append(f"SELECT 'PROOF|{tag}|{role}|walk {code}|' || coalesce(md5(jsonb_agg(to_jsonb(w) ORDER BY w.step, w.code, w.id)::text), 'empty') || '|' || count(*) "
                       f"FROM document_chain_walk('{D[chain]}'::jsonb, {IDX[chain][step]}, '{key}', (SELECT id FROM public.{table} WHERE code = '{code}')) w;")
        for subj, table, code in TRAILS:
            out.append(f"""DO $t$ DECLARE v text; BEGIN
  SELECT md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.entry_no, t.seq NULLS LAST, t.occurred_at, t.table_name, t.row_key::text)::text, '[]')) INTO v
    FROM record_trail('{subj}', (SELECT id::text FROM public.{table} WHERE code = '{code}'), 20) t;
  RAISE NOTICE 'PROOF|{tag}|{role}|trail {code}|%', v;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|{tag}|{role}|trail {code}|ERR %', split_part(SQLERRM, '|', 1); END $t$;""")
        for t in TABLES:
            out.append(f"""DO $r$ DECLARE v text; c text; BEGIN
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO c FROM pg_attribute a
   WHERE a.attrelid = 'public.{t}'::regclass AND a.attnum > 0 AND NOT a.attisdropped AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'SELECT');
  EXECUTE format('SELECT count(*) || '' '' || md5(coalesce(string_agg(h, '''' ORDER BY h), '''')) FROM (SELECT md5(ROW(%s)::text) h FROM public.{t}) z', c) INTO v;
  RAISE NOTICE 'PROOF|{tag}|{role}|read {t}|%', v;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|{tag}|{role}|read {t}|ERR %', SQLSTATE; END $r$;""")
        out.append("RESET ROLE;")
    return '\n'.join(out)

print(f"""\\set ON_ERROR_STOP 1
SET lock_timeout = '10s';
\\timing on
BEGIN;
SELECT 'PROOF|clock before|' || clock_timestamp();
{readings('B')}
SELECT 'PROOF|clock migration start|' || clock_timestamp();
{body}
SELECT 'PROOF|clock migration end|' || clock_timestamp();
{readings('A')}
SELECT 'PROOF|counts|' || json_build_object(
  'policies_wrapped', (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND (coalesce(qual, '') || coalesce(with_check, '')) ~ 'SELECT (has_(any_)?permission|current_user_employee|auth\\.uid)'),
  'unwrapped_left', (SELECT count(*) FROM pg_policies p, regexp_matches(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''), '(\\(\\s*SELECT\\s+)?\\m(has_(any_)?permission\\(|current_user_employee\\(\\)|auth\\.uid\\(\\))', 'g') m WHERE p.schemaname = 'public' AND m[1] IS NULL),
  'new_functions', (SELECT count(*) FROM pg_proc WHERE proname IN ('document_relation_arm_pairs', 'document_chain_step_admitted')),
  'anon_can_walk', has_function_privilege('anon', 'public.document_chain_walk(jsonb,integer,text,uuid)', 'EXECUTE'))::text;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{{"sub":"{READERS['cfo']}","role":"authenticated"}}', true) \\g /dev/null
SELECT set_config('app.chain_walk_budget_ms', '0', true) \\g /dev/null
DO $$ BEGIN PERFORM * FROM document_chain_walk('{D['purchasing']}'::jsonb, 0, 'purchase_order', (SELECT id FROM public.purchase_orders WHERE code = 'PO-2026-0003'));
  RAISE NOTICE 'PROOF|budget|NOT_ENFORCED'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|budget|%', left(SQLERRM, 80); END $$;
RESET ROLE;
SELECT 'PROOF|clock rollback|' || clock_timestamp();
ROLLBACK;
""")
