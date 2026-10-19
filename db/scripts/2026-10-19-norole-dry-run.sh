#!/usr/bin/env bash
# NOROLE-SURFACE — the COMMIT → ROLLBACK dry run on live (brief step 4; AGENTS.md / migration-dry-run rule).
# Runs the migration FILE exactly as db/apply_migration.sh would (its body, then the function-grants replay), but where the file says
# COMMIT it runs the per-role reading (docs/surveys/NOROLE-SURFACE/per-role-readings.sql, phase=dry) and then ROLLBACK. Nothing stays.
# Usage: db/scripts/2026-10-19-norole-dry-run.sh > log 2>&1; echo "DRY_OWN_EXIT=$?" >> log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
MIG="$HERE/migrations/2026-10-19-norole-surface.sql"
READ="$REPO/docs/surveys/NOROLE-SURFACE/per-role-readings.sql"
grep -q '^COMMIT;' "$MIG" || { echo "✗ no COMMIT; in $MIG"; exit 2; }
{
  awk '/^COMMIT;[[:space:]]*$/ { exit } { print }' "$MIG"
  echo "\\i $HERE/views/zzz_function_grants.sql"
  echo "SELECT set_config('noroleprobe.phase', 'dry', true);"
  # the reading's DO block only (its own BEGIN / ROLLBACK and the psql-variable line are dropped — it runs inside this transaction)
  awk '/^DO \$read\$/ { on = 1 } on { print } /^\$read\$;/ { on = 0 }' "$READ"
  echo "ROLLBACK;"
} | psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f -
