#!/usr/bin/env bash
# TABLE-EXPORT-2b-1 — the COMMIT → ROLLBACK dry run of the Q5 migration on live (AGENTS.md / migration-dry-run rule).
# Runs the file exactly as db/apply_migration.sh would (its body — with its own self-check — then the function-grants replay), but where the
# file says COMMIT it reads back what the transaction built and then ROLLBACKs. Nothing stays. Shape of db/scripts/2026-10-19-mes9b-dry-run.sh.
# Usage: db/scripts/2026-10-23-table-export-2b1-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-23-table-export-2b1-formula-masked-terms-unchanged.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
Q="SELECT string_agg(p.proname || ':' || (position('pricing_formula_terms_visible' in p.prosrc) > 0)::text || ':' || pg_get_function_identity_arguments(p.oid)
      || ':anon=' || has_function_privilege('anon', p.oid, 'EXECUTE') || ':authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE'), ' | ' ORDER BY p.proname)
     FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('submit_formula_change_request', 'submit_formula_reactivate_request')"
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT 'DRY|inside|' || ($Q) || '|approvals=' || approvals_enabled();"
  echo "ROLLBACK;"
  echo "SELECT 'DRY|after rollback|' || ($Q);"
} | psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f - 2>&1 | grep -E "^DRY\||ERROR|TE2B1_SELFCHECK"
exit "${PIPESTATUS[1]}"
