#!/usr/bin/env bash
# CLAIM-RECEIPTS-1 — the COMMIT → ROLLBACK dry run of the migration FILE on live (brief Verify step 3; AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-proof — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays. Shape of db/scripts/2026-10-20-expense-multiline-1-dry-run.sh.
# Usage: db/scripts/2026-10-21-claim-receipts-1-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-21-claim-receipts-1.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT 'DRY|inside|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|receipts table=' || (to_regclass('public.expense_claim_receipts') IS NOT NULL) || '|receipt rows=' || (SELECT count(*) FROM expense_claim_receipts)"
  echo "    || '|receipt functions=' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname LIKE 'claim\\_receipt\\_%')"
  echo "    || '|authenticated executes begin=' || has_function_privilege('authenticated', 'public.claim_receipt_begin(uuid,text,text,bigint)', 'EXECUTE')"
  echo "    || '|anon executes begin=' || has_function_privilege('anon', 'public.claim_receipt_begin(uuid,text,text,bigint)', 'EXECUTE')"
  echo "    || '|finance_attachments.claim_id=' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'finance_attachments' AND column_name = 'claim_id')"
  echo "    || '|has_receipt=' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expense_claim_status' AND column_name = 'has_receipt')"
  echo "    || '|storage policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') || '|buckets=' || (SELECT count(*) FROM storage.buckets)"
  echo "    || '|claim-receipts=' || COALESCE((SELECT file_size_limit || ' ' || allowed_mime_types::text FROM storage.buckets WHERE id = 'claim-receipts'), 'absent')"
  echo "    || '|objects=' || (SELECT count(*) FROM storage.objects)"
  echo "    || '|exclusions=' || (change_log_coverage_gaps() ->> 'excluded') || '|gaps=' || (change_log_coverage_gaps() -> 'gaps')::text;"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|tables=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')"
  echo "    || '|receipts table=' || (to_regclass('public.expense_claim_receipts') IS NOT NULL)"
  echo "    || '|finance_attachments.claim_id=' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'finance_attachments' AND column_name = 'claim_id')"
  echo "    || '|storage policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') || '|buckets=' || (SELECT count(*) FROM storage.buckets)"
  echo "    || '|objects=' || (SELECT count(*) FROM storage.objects);"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||NOTICE:  CR1|ERROR|CR1_P"
exit "${PIPESTATUS[1]}"
