#!/usr/bin/env python3
"""CONTRACT-ESIGN · live dry run (COMMIT -> ROLLBACK). Builds one psql script: lock_timeout 10s · BEGIN · BEFORE readings ·
the migration body (exactly the lines between its BEGIN; and COMMIT; lines — never cut at a semicolon) · the function-grant replay
(db/views/zzz_function_grants.sql, as apply_migration.sh does inside the same transaction) · AFTER readings · ROLLBACK.
Readings, read-only inside the rolled-back transaction:
  as postgres (rolbypassrls, base tables): md5 of the seven real roles' grants, user_roles, change_log (count + max seq), contracts, cod_issues;
    buckets and storage-policy counts; anon relation count; the new tables, functions and code present; who holds action.manage_signatories.
  as the real cfo (tim@): contract_signatory_active() (expected false: nobody is on the list) and contract_sign_begin on a made-up file id
    (expected CONTRACT_FILE_NOT_FOUND) — the new functions run for a real reader.
  as the real warehouse holder: contract_signatory_add refuses by name (no action.manage_signatories).
Nothing is pressed and nothing is written besides the migration body, which is rolled back with everything else.
usage: python3 db/scripts/2026-10-30-contract-esign-dry-run.py > dry-run.sql ; psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f dry-run.sql"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
mig = open(os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'db/migrations/2026-10-30-contract-esign.sql')).read().split('\n')
b = mig.index('BEGIN;'); c = len(mig) - 1 - mig[::-1].index('COMMIT;')
body = '\n'.join(mig[b + 1:c])
grants = open(os.path.join(ROOT, 'db/views/zzz_function_grants.sql')).read()
CFO = '634c00f9-c3a9-4444-9eed-b624cb6a2a93'
WAREHOUSE = 'c8116e6c-80db-4a16-be12-24fb6ce6859d'
SEVEN = "'admin','cco','cfo','cto','finance','gm','warehouse'"


def md5(rel, order='id'):
    return f"(SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.{order}), '')) FROM public.{rel} t)"


def readings(tag):
    after = tag == 'B'
    out = [f"""SELECT 'PROOF|{tag}|postgres|' || json_build_object(
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ({SEVEN})),
  'six_grants_no_admin', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ({SEVEN}) AND r.code <> 'admin'),
  'user_roles', {md5('user_roles')},
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'contracts', {md5('contracts')}, 'cod_issues', {md5('cod_issues')},
  'buckets', (SELECT count(*) FROM storage.buckets), 'storage_policies', (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage'),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'new_tables', (SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace = 'public'::regnamespace
                   AND relname IN ('contract_files','contract_signatories','signature_specimens','company_stamps')),
  'manage_signatories_holders', (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                   WHERE rp.permission_code = 'action.manage_signatories'),
  'approvals', (SELECT approvals_enabled FROM public.finance_settings),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM public.ingest_settings))::text;"""]
    if after:
        out.append("SET LOCAL ROLE authenticated;")
        out.append(f"""SELECT set_config('request.jwt.claims', '{{"sub":"{CFO}","role":"authenticated"}}', true) \\g /dev/null""")
        out.append(f"SELECT 'PROOF|{tag}|cfo|signatory_active ' || public.contract_signatory_active()::text;")
        out.append(f"SELECT 'PROOF|{tag}|cfo|files_visible ' || (SELECT count(*) FROM public.contract_files);")
        out.append("""DO $c$ BEGIN PERFORM public.contract_sign_begin(gen_random_uuid(), false, 1, 0.5, 0.5); RAISE NOTICE 'PROOF|B|cfo|sign_begin returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|cfo|sign_begin refused %', SQLERRM; END $c$;""")
        out.append("RESET ROLE;")
        out.append("SET LOCAL ROLE authenticated;")
        out.append(f"""SELECT set_config('request.jwt.claims', '{{"sub":"{WAREHOUSE}","role":"authenticated"}}', true) \\g /dev/null""")
        out.append("""DO $w$ BEGIN PERFORM public.contract_signatory_add(gen_random_uuid(), 'x'); RAISE NOTICE 'PROOF|B|warehouse|signatory_add returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|warehouse|signatory_add refused %', SQLERRM; END $w$;""")
        out.append("RESET ROLE;")
    return '\n'.join(out)


print("\\set ON_ERROR_STOP 1")
print("SET lock_timeout = '10s';")
print("\\timing on")
print("BEGIN;")
print(readings('A'))
print("-- ── migration body ──")
print(body)
print("-- ── function-grant replay (apply_migration.sh does this inside the same transaction) ──")
print(grants)
print(readings('B'))
print("ROLLBACK;")
print("SELECT 'PROOF|C|after rollback|new_tables=' || COALESCE((SELECT string_agg(relname, ',') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('contract_files','contract_signatories','signature_specimens','company_stamps')), 'none') || ' buckets=' || (SELECT count(*) FROM storage.buckets);")
