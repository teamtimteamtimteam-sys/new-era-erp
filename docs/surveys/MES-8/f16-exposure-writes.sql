-- MES-7b-2 close-out, step 1.2 — every change_log row on the 37 base tables of the 45 views that accepted a write before F16, one per line
-- (time CST · table · op · row key · actor kind · db role · changed columns · txid). Read-only, as postgres. The five tables listed are the only
-- ones of the 37 with any row (docs/surveys/MES-8/f16-exposure.sql, TBL lines). Output: docs/surveys/MES-8/f16-exposure-writes.txt
BEGIN READ ONLY;
SELECT to_char(cl.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' | ' || cl.table_name || ' | ' || cl.op || ' | '
    || COALESCE(cl.row_key->>'id', cl.row_key::text, '-') || ' | ' || cl.actor_kind || ' | ' || cl.db_role || ' | '
    || COALESCE(array_to_string(cl.changed_columns, ','), '-') || ' | txid ' || cl.txid
  FROM change_log cl WHERE cl.table_name IN ('approval_log', 'employees', 'gateway_keys', 'leave_requests', 'performance_reviews')
 ORDER BY cl.seq;
ROLLBACK;
