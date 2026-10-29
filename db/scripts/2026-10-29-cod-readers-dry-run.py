#!/usr/bin/env python3
"""COD-READERS · live dry run (COMMIT -> ROLLBACK). Builds one psql script: lock_timeout 10s · BEGIN · BEFORE readings ·
the migration body (exactly the lines between its BEGIN; and COMMIT; lines — never cut at a semicolon) · AFTER readings · ROLLBACK.
Readings, read-only inside the rolled-back transaction:
  as two real role holders (tim@ = cfo, the warehouse account) and as a signed-in session with no role:
    how many certificates_of_destruction / cod_issues rows and cod-documents storage objects each can read;
  as postgres: an md5 of every certificates_of_destruction and cod_issues row and of the cod-documents objects' names and metadata
    (before and after must match: the migration changes who reads, never what is there);
  the policy expressions, the holders of data.view_cod and action.issue_cod, and document_types.cod.view_permission.
Prints PROOF| lines; the caller compares B vs A. Nothing is pressed: no write function is called.
usage: python3 db/scripts/2026-10-29-cod-readers-dry-run.py > dry-run.sql ; psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f dry-run.sql"""
import os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
mig = open(os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'db/migrations/2026-10-29-cod-readers.sql')).read().split('\n')
b = mig.index('BEGIN;'); c = len(mig) - 1 - mig[::-1].index('COMMIT;')
body = '\n'.join(mig[b + 1:c])
READERS = {'cfo': '634c00f9-c3a9-4444-9eed-b624cb6a2a93', 'warehouse': 'c8116e6c-80db-4a16-be12-24fb6ce6859d',
           'no-role': '00000000-0000-4000-8000-00000000c0d0'}

def readings(tag):
    out = [f"""SELECT 'PROOF|{tag}|postgres|rows|' || json_build_object(
  'cod', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(c)::text, '' ORDER BY c.id), '')) FROM public.certificates_of_destruction c),
  'issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(i)::text, '' ORDER BY i.id), '')) FROM public.cod_issues i),
  'objects', (SELECT count(*) || ' ' || md5(coalesce(string_agg(o.name || coalesce(o.metadata::text, ''), '' ORDER BY o.name), '')) FROM storage.objects o WHERE o.bucket_id = 'cod-documents'))::text;"""]
    for role, uid in READERS.items():
        out.append("SET LOCAL ROLE authenticated;")
        out.append(f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null""")
        out.append(f"""SELECT 'PROOF|{tag}|{role}|reads|' || (SELECT count(*) FROM public.certificates_of_destruction) || ' cod · '
  || (SELECT count(*) FROM public.cod_issues) || ' issues · ' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'cod-documents') || ' objects';""")
        out.append("RESET ROLE;")
    out.append(f"""SELECT 'PROOF|{tag}|catalog|' || json_build_object(
  'view_cod', (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE rp.permission_code = 'data.view_cod'),
  'issue_cod', (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.issue_cod'),
  'doctype', (SELECT view_permission FROM public.document_types WHERE key = 'cod'),
  'policies', (SELECT json_object_agg(tablename || ' / ' || policyname || ' / ' || cmd, coalesce(qual, with_check) ORDER BY tablename, policyname)
                 FROM pg_policies WHERE (schemaname = 'public' AND tablename IN ('certificates_of_destruction', 'cod_issues'))
                    OR (schemaname = 'storage' AND policyname LIKE 'cod-documents%')))::text;""")
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
SELECT 'PROOF|clock rollback|' || clock_timestamp();
ROLLBACK;
""")
