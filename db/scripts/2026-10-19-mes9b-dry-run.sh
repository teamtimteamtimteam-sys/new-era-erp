#!/usr/bin/env bash
# MES-9b — the COMMIT → ROLLBACK dry run of the migration FILE on live (brief Verify step 3; AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-proof — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays. Shape of db/scripts/2026-10-19-mes9a-dry-run.sh.
# Usage: db/scripts/2026-10-19-mes9b-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT 'DRY|inside|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|supplier_portal executes=' || (SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE'))"
  echo "    || '|storage USAGE=' || has_schema_privilege('supplier_portal', 'storage', 'USAGE') || '|storage.objects SELECT=' || has_table_privilege('supplier_portal', 'storage.objects', 'SELECT')"
  echo "    || '|storage policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') || '|portal policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND 'supplier_portal' = ANY (roles))"
  echo "    || '|exclusions=' || (change_log_coverage_gaps() ->> 'excluded') || '|gaps=' || (change_log_coverage_gaps() -> 'gaps')::text"
  echo "    || '|authenticated executes portal_documents=' || has_function_privilege('authenticated', 'public.portal_documents()', 'EXECUTE');"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|download log table=' || (to_regclass('public.portal_document_downloads') IS NOT NULL) || '|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|storage policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') || '|storage USAGE=' || has_schema_privilege('supplier_portal', 'storage', 'USAGE');"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||NOTICE:  MES9B|ERROR|MES9B_P"
exit "${PIPESTATUS[1]}"
