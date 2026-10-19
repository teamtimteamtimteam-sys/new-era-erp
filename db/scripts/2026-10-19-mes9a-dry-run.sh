#!/usr/bin/env bash
# MES-9a — the COMMIT → ROLLBACK dry run of the migration FILE on live (brief Verify step 4; AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-proof — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays.
# Usage: db/scripts/2026-10-19-mes9a-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-19-mes9a-supplier-portal-identity.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT 'DRY|inside|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|codes=' || (SELECT count(*) FROM permissions)"
  echo "    || '|supplier_portal executes=' || (SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE'))"
  echo "    || '|manage_portal_users holders=' || (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.manage_portal_users')"
  echo "    || '|pending V38/V40 rows=' || (SELECT count(*) FROM account_settings WHERE initial_password_valid_days IS NULL) + (SELECT count(*) FROM account_settings WHERE password_min_length IS NULL);"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|supplier_portal role=' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') || '|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public');"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||NOTICE:  MES9A|ERROR|MES9A_P"
exit "${PIPESTATUS[1]}"
