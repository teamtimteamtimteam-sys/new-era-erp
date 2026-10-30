#!/usr/bin/env python3
"""GOLIVE-2 · live dry run (COMMIT -> ROLLBACK). Builds one psql script: lock_timeout 10s · BEGIN · BEFORE readings ·
the migration body (exactly the lines between its BEGIN; and COMMIT; lines — never cut at a semicolon) · the function-grant replay
(db/views/zzz_function_grants.sql, as apply_migration.sh does inside the same transaction) · AFTER readings · ROLLBACK.
Readings, read-only inside the rolled-back transaction:
  as postgres (rolbypassrls, base tables): md5 of the seven real roles' grants, change_log (count + max seq), contracts, contract_document_terms,
    terms_requests, sales_settlements, cod_issues; the anon relation count; column privileges of authenticated on the copy's two jsonb columns and on
    terms_requests.snapshot; EXECUTE of authenticated on sale_settlement_compute; the new functions and views present; idx_change_log_txid present.
  as the real cfo (tim@, holds data.view_change_log): change history the old way (change_log_rows, the page's loop for 21 operations) and the new way
    (change_log_page, one call) — row count and md5 must be equal; change_log_count for the last 7 days; dictionary_usage_counts runs.
  as the real warehouse holder (no data.view_change_log): change_log_page refuses by name.
Nothing is pressed and nothing is written besides the migration body, which is rolled back with everything else.
usage: python3 db/scripts/2026-10-30-golive-2-dry-run.py > dry-run.sql ; psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f dry-run.sql"""
import json, os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
mig = open(os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'db/migrations/2026-10-30-golive-2.sql')).read().split('\n')
b = mig.index('BEGIN;'); c = len(mig) - 1 - mig[::-1].index('COMMIT;')
body = '\n'.join(mig[b + 1:c])
grants = open(os.path.join(ROOT, 'db/views/zzz_function_grants.sql')).read()
CFO = '634c00f9-c3a9-4444-9eed-b624cb6a2a93'
WAREHOUSE = 'c8116e6c-80db-4a16-be12-24fb6ce6859d'
SEVEN = "'admin','cco','cfo','cto','finance','gm','warehouse'"
pairs = json.load(open(os.path.join(ROOT, 'docs/surveys/GOLIVE-2/dictionary-reference-pairs.json')))
REFS = json.dumps(pairs).replace("'", "''")


def md5(rel, order='id'):
    return f"(SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.{order}), '')) FROM public.{rel} t)"


def readings(tag):
    after = tag == 'B'
    out = [f"""SELECT 'PROOF|{tag}|postgres|' || json_build_object(
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ({SEVEN})),
  'user_roles', {md5('user_roles')},
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'contracts', {md5('contracts')}, 'contract_document_terms', {md5('contract_document_terms')}, 'terms_requests', {md5('terms_requests')},
  'sales_settlements', {md5('sales_settlements')}, 'cod_issues', {md5('cod_issues')},
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'auth_reads_copy_pricing', has_column_privilege('authenticated', 'public.contract_document_terms', 'pricing_terms', 'SELECT'),
  'auth_reads_copy_settlement', has_column_privilege('authenticated', 'public.contract_document_terms', 'settlement_terms', 'SELECT'),
  'auth_reads_copy_code', has_column_privilege('authenticated', 'public.contract_document_terms', 'contract_code', 'SELECT'),
  'anon_any_on_copy', has_table_privilege('anon', 'public.contract_document_terms', 'SELECT,INSERT,UPDATE,DELETE'),
  'auth_reads_tr_snapshot', has_column_privilege('authenticated', 'public.terms_requests', 'snapshot', 'SELECT'),
  'auth_reads_tr_label', has_column_privilege('authenticated', 'public.terms_requests', 'label', 'SELECT'),
  'auth_exec_compute', has_function_privilege('authenticated', 'public.sale_settlement_compute(uuid,uuid,uuid)', 'EXECUTE'),
  'auth_exec_record', has_function_privilege('authenticated', 'public.record_sale_settlement(uuid,uuid,uuid)', 'EXECUTE'),
  'new_functions', (SELECT string_agg(proname, ',' ORDER BY proname) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                      AND proname IN ('change_log_page','change_log_count','dictionary_usage_counts','contract_copy_price_visible','trail_subject_member_map','trail_subject_root_map')),
  'new_views', (SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('contract_document_terms_masked','terms_requests_masked')),
  'txid_index', (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_change_log_txid'),
  'inlined_constants', (SELECT string_agg(proname || '=' || coalesce(array_to_string(proconfig, ';'), 'none'), ',' ORDER BY proname) FROM pg_proc
                          WHERE pronamespace = 'public'::regnamespace AND proname IN ('trail_subjects','trail_subject_members','trail_log_only_tables','change_log_mask_rules')))::text;"""]
    # the real cfo: the page's old loop for 21 operations (change_log_rows) — and after the migration the new single call must equal it
    out.append("SET LOCAL ROLE authenticated;")
    out.append(f"""SELECT set_config('request.jwt.claims', '{{"sub":"{CFO}","role":"authenticated"}}', true) \\g /dev/null""")
    out.append(f"""SELECT 'PROOF|{tag}|cfo|old|' || (SELECT count(*) || ' rows ' || md5(coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.seq)::text, ''))
     FROM public.change_log_rows(p_by_entry => true, p_limit => 21) x);""")
    if after:
        out.append(f"""SELECT 'PROOF|{tag}|cfo|new|' || (SELECT count(*) || ' rows ' || md5(coalesce(jsonb_agg(e ORDER BY (e ->> 'seq')::bigint)::text, ''))
     FROM jsonb_array_elements(public.change_log_page(p_entries => 21) -> 'rows') e);""")
        out.append(f"""SELECT 'PROOF|{tag}|cfo|count7d|' || public.change_log_count(p_from => (now() AT TIME ZONE 'Asia/Singapore')::date - 6, p_to => (now() AT TIME ZONE 'Asia/Singapore')::date);""")
        out.append(f"""SELECT 'PROOF|{tag}|cfo|dict|' || (SELECT count(*) FROM jsonb_object_keys(public.dictionary_usage_counts('{REFS}'::jsonb)));""")
    out.append("RESET ROLE;")
    if after:
        out.append("SET LOCAL ROLE authenticated;")
        out.append(f"""SELECT set_config('request.jwt.claims', '{{"sub":"{WAREHOUSE}","role":"authenticated"}}', true) \\g /dev/null""")
        out.append("""DO $w$ BEGIN PERFORM public.change_log_page(p_entries => 21); RAISE NOTICE 'PROOF|B|warehouse|change_log_page READ (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|warehouse|refused %', split_part(SQLERRM, '|', 1); END $w$;""")
        out.append("RESET ROLE;")
    return '\n'.join(out)


print("\\set ON_ERROR_STOP 1")
print("SET lock_timeout = '10s';")
print("BEGIN;")
print(readings('A'))
print("-- ── migration body ──")
print(body)
print("-- ── function grants replay (apply_migration.sh does this inside the migration's transaction) ──")
print(grants)
print(readings('B'))
print("ROLLBACK;")
