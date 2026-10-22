#!/usr/bin/env bash
# PAYROLL-PAY-REVERSAL-1 — the COMMIT → ROLLBACK dry run of the migration FILE on live (brief Verify step 3; AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-proof — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays. Shape of db/scripts/2026-10-21-claim-receipts-1-dry-run.sh.
# Usage: db/scripts/2026-10-22-payroll-pay-reversal-1-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-22-payroll-pay-reversal-1.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT 'DRY|inside|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|target_entry_id=' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'payroll_requests' AND column_name = 'target_entry_id')"
  echo "    || '|masked view has it=' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'payroll_requests_masked' AND column_name = 'target_entry_id')"
  echo "    || '|authenticated executes submit=' || has_function_privilege('authenticated', 'public.submit_payroll_payment_reversal_request(uuid,text)', 'EXECUTE')"
  echo "    || '|authenticated executes engine=' || has_function_privilege('authenticated', 'public.reverse_payroll_payment_internal(uuid,date,text)', 'EXECUTE')"
  echo "    || '|anon executes door=' || has_function_privilege('anon', 'public.reverse_payroll_payment(uuid,date)', 'EXECUTE')"
  echo "    || '|routes=' || (SELECT string_agg(code || ':' || journal_entry_reversal_route(id), ',' ORDER BY code) FROM journal_entries WHERE source_type = 'payroll')"
  echo "    || '|leave rules=' || (SELECT string_agg(code || ':' || qualifying_service_months || ':' || service_rule, ',' ORDER BY code) FROM leave_types WHERE default_days_per_year IS NOT NULL)"
  echo "    || '|exclusions=' || (change_log_coverage_gaps() ->> 'excluded') || '|gaps=' || (change_log_coverage_gaps() -> 'gaps')::text;"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|target_entry_id=' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'payroll_requests' AND column_name = 'target_entry_id')"
  echo "    || '|service_rule=' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'leave_types' AND column_name = 'service_rule')"
  echo "    || '|reverse_payroll_payment=' || (to_regprocedure('public.reverse_payroll_payment(uuid,date)') IS NOT NULL)"
  echo "    || '|routes=' || (SELECT string_agg(code || ':' || journal_entry_reversal_route(id), ',' ORDER BY code) FROM journal_entries WHERE source_type = 'payroll');"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||NOTICE:  PPR1|ERROR|PPR1_P"
exit "${PIPESTATUS[1]}"
