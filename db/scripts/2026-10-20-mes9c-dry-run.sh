#!/usr/bin/env bash
# MES-9c — the COMMIT → ROLLBACK dry run of the migration FILE on live (brief Verify step 3; AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-proof — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays. Shape of db/scripts/2026-10-19-mes9b-dry-run.sh.
# Usage: db/scripts/2026-10-20-mes9c-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-20-mes9c-certificate-uploads.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT 'DRY|inside|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|supplier_portal executes=' || (SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE'))"
  echo "    || '|storage.objects INSERT=' || has_table_privilege('supplier_portal', 'storage.objects', 'INSERT')"
  echo "    || '|storage policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') || '|portal policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND 'supplier_portal' = ANY (roles))"
  echo "    || '|buckets=' || (SELECT count(*) FROM storage.buckets) || '|V39=' || (SELECT portal_upload_max_bytes || ' ' || portal_upload_types::text FROM account_settings WHERE id)"
  echo "    || '|exclusions=' || (change_log_coverage_gaps() ->> 'excluded') || '|gaps=' || (change_log_coverage_gaps() -> 'gaps')::text"
  echo "    || '|change_log_rows=' || (SELECT string_agg(p.oid::regprocedure::text, ' ') FROM pg_proc p WHERE p.proname = 'change_log_rows')"
  echo "    || '|authenticated executes change_log_rows=' || has_function_privilege('authenticated', 'public.change_log_rows(date,date,text,text,uuid,boolean,bigint,integer,text[],boolean,boolean,text[],bigint,integer)', 'EXECUTE')"
  echo "    || '|anon executes change_log_rows=' || has_function_privilege('anon', 'public.change_log_rows(date,date,text,text,uuid,boolean,bigint,integer,text[],boolean,boolean,text[],bigint,integer)', 'EXECUTE')"
  echo "    || '|authenticated executes portal_certificates=' || has_function_privilege('authenticated', 'public.portal_certificates()', 'EXECUTE');"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|submissions table=' || (to_regclass('public.portal_certificate_submissions') IS NOT NULL) || '|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|storage policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') || '|buckets=' || (SELECT count(*) FROM storage.buckets)"
  echo "    || '|change_log_rows=' || (SELECT string_agg(p.oid::regprocedure::text, ' ') FROM pg_proc p WHERE p.proname = 'change_log_rows');"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||NOTICE:  MES9C|ERROR|MES9C_P"
exit "${PIPESTATUS[1]}"
