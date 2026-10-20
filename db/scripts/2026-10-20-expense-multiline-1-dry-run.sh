#!/usr/bin/env bash
# EXPENSE-MULTILINE-1 — the COMMIT → ROLLBACK dry run of the migration FILE on live (brief Verify step 3; AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-proof — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays. Shape of db/scripts/2026-10-20-fin-chain-1-dry-run.sh.
# Usage: db/scripts/2026-10-20-expense-multiline-1-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-20-expense-multiline-1.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  # 合计守卫是延迟的 —— 在回滚之前强制它们跑一次,于是"回填逐张对得上"是这一次干跑【量到】的,不是推出来的
  echo "SET CONSTRAINTS ALL IMMEDIATE;"
  echo "SELECT 'DRY|inside|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|expense_lines=' || (SELECT count(*) FROM expense_lines) || '|claim_items=' || (SELECT count(*) FROM expense_claim_items)"
  echo "    || '|writers=' || (SELECT string_agg(p.oid::regprocedure::text, ' ' ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname IN ('record_expense_document', 'submit_expense_claim_items', 'decide_expense_claim_items'))"
  echo "    || '|authenticated executes document writer=' || has_function_privilege('authenticated', 'public.record_expense_document(date,text,jsonb,text,text,uuid,text,text,jsonb,uuid,uuid,text,numeric,text,uuid,boolean)', 'EXECUTE')"
  echo "    || '|anon executes document writer=' || has_function_privilege('anon', 'public.record_expense_document(date,text,jsonb,text,text,uuid,text,text,jsonb,uuid,uuid,text,numeric,text,uuid,boolean)', 'EXECUTE')"
  echo "    || '|header columns left=' || (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND ((table_name = 'expenses' AND column_name IN ('account_code','tax_code','tax_rate_pct')) OR (table_name = 'expense_claims' AND column_name IN ('account_code','tax_code','no_receipt_reason'))))"
  echo "    || '|exclusions=' || (change_log_coverage_gaps() ->> 'excluded') || '|gaps=' || (change_log_coverage_gaps() -> 'gaps')::text;"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|expense_lines exists=' || (to_regclass('public.expense_lines') IS NOT NULL)"
  echo "    || '|header columns back=' || (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expenses' AND column_name IN ('account_code','tax_code','tax_rate_pct'));"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||NOTICE:  EM1|ERROR|EM1_P"
exit "${PIPESTATUS[1]}"
