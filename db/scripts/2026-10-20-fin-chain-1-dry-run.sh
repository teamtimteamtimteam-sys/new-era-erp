#!/usr/bin/env bash
# FIN-CHAIN-1 — the COMMIT → ROLLBACK dry run of the migration FILE on live (brief Verify step 3; AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-proof — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays. Shape of db/scripts/2026-10-20-mes9c-dry-run.sh.
# Usage: db/scripts/2026-10-20-fin-chain-1-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-20-fin-chain-1.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT 'DRY|inside|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|new accounts=' || (SELECT string_agg(code || ':' || account_type || ':' || is_monetary || ':' || COALESCE(cash_flow_section, '-'), ',' ORDER BY code) FROM accounts WHERE code IN ('2600','6010','6130','6140','6210','6220','6230','6240','6250','6310','6410','6420','6510','6520'))"
  echo "    || '|freight=' || (SELECT string_agg(p.oid::regprocedure::text, ' ') FROM pg_proc p WHERE p.proname = 'reverse_freight_document')"
  echo "    || '|authenticated executes freight=' || has_function_privilege('authenticated', 'public.reverse_freight_document(uuid,text,date)', 'EXECUTE')"
  echo "    || '|anon executes freight=' || has_function_privilege('anon', 'public.reverse_freight_document(uuid,text,date)', 'EXECUTE')"
  echo "    || '|quote guard=' || (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_quotes_status_through_function')"
  echo "    || '|close_period refuses=' || (position('CLOSE_LEDGER_LIST_UNEXPLAINED' IN pg_get_functiondef('public.close_period(date,text)'::regprocedure)) > 0)"
  echo "    || '|exclusions=' || (change_log_coverage_gaps() ->> 'excluded') || '|gaps=' || (change_log_coverage_gaps() -> 'gaps')::text;"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|new accounts=' || (SELECT count(*) FROM accounts WHERE code IN ('2600','6010','6130','6140','6210','6220','6230','6240','6250','6310','6410','6420','6510','6520'))"
  echo "    || '|freight=' || (SELECT string_agg(p.oid::regprocedure::text, ' ') FROM pg_proc p WHERE p.proname = 'reverse_freight_document')"
  echo "    || '|quote guard=' || (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_quotes_status_through_function');"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||NOTICE:  FINCHAIN1|ERROR|FINCHAIN1_P"
exit "${PIPESTATUS[1]}"
