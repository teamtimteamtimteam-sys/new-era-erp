-- MES-7b-2 close-out, step 1.2 — the writes f16-exposure.sql counted, one by one. Read-only, as postgres (base tables).
-- Tables: the 4 of the 37 base tables that have any change_log row (approval_log, employees, gateway_keys, leave_requests,
-- performance_reviews); every other base table of the 45 views has 0 rows (f16-exposure.sql, TBL lines).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8/f16-exposure-detail.sql
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- every authenticated write: time, table, op, row, actor (and whether that account still exists), the other tables its transaction wrote
SELECT 'AUTH|' || cl.seq || '|' || to_char(cl.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || '|' || cl.table_name || '|' || cl.op
    || '|row=' || COALESCE(cl.row_key::text, '-') || '|cols=' || COALESCE(array_to_string(cl.changed_columns, ','), '-')
    || '|actor=' || COALESCE(cl.actor_account::text, '-') || '|account=' || COALESCE((SELECT u.email FROM auth.users u WHERE u.id = cl.actor_account), 'GONE')
    || '|txid=' || cl.txid
    || '|tx_tables=' || COALESCE((SELECT string_agg(DISTINCT c2.table_name || ':' || c2.op, ',') FROM change_log c2 WHERE c2.txid = cl.txid AND c2.seq <> cl.seq), '-')
  FROM change_log cl
 WHERE cl.table_name IN ('approval_log','gateway_keys','leave_requests')
   AND cl.actor_kind = 'user' AND cl.db_role = 'authenticated'
 ORDER BY cl.seq;
-- performance_reviews by authenticated users: by day × op, whether each row was inserted and deleted, actors still existing
SELECT 'PR_AUTH|' || to_char(cl.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD') || '|' || cl.op || '|' || count(*)
    || '|actors=' || count(DISTINCT cl.actor_account)
    || '|actors_existing=' || count(DISTINCT cl.actor_account) FILTER (WHERE EXISTS (SELECT 1 FROM auth.users u WHERE u.id = cl.actor_account))
    || '|cols=' || COALESCE(string_agg(DISTINCT array_to_string(cl.changed_columns, ','), ' ; '), '-')
  FROM change_log cl WHERE cl.table_name = 'performance_reviews' AND cl.actor_kind = 'user' AND cl.db_role = 'authenticated'
 GROUP BY to_char(cl.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD'), cl.op ORDER BY 1;
-- what else did those performance_reviews transactions write
SELECT 'PR_TX|' || x.shape || '|' || count(*) FROM (
  SELECT cl.txid, string_agg(DISTINCT c2.table_name || ':' || c2.op, ',' ORDER BY c2.table_name || ':' || c2.op) AS shape
    FROM change_log cl JOIN change_log c2 ON c2.txid = cl.txid
   WHERE cl.table_name = 'performance_reviews' AND cl.actor_kind = 'user' AND cl.db_role = 'authenticated'
   GROUP BY cl.txid) x GROUP BY x.shape ORDER BY count(*) DESC;
-- the authenticated performance_reviews rows: do they still exist? (row_key id)
SELECT 'PR_ROWS|inserted=' || count(*) FILTER (WHERE op = 'INSERT') || '|deleted_by_any=' ||
       count(*) FILTER (WHERE op = 'INSERT' AND EXISTS (SELECT 1 FROM change_log d WHERE d.table_name = 'performance_reviews' AND d.op = 'DELETE' AND d.row_key = cl.row_key))
    || '|still_present=' || count(*) FILTER (WHERE op = 'INSERT' AND EXISTS (SELECT 1 FROM performance_reviews p WHERE p.id::text = cl.row_key->>'id'))
  FROM change_log cl WHERE cl.table_name = 'performance_reviews' AND cl.actor_kind = 'user' AND cl.db_role = 'authenticated';
-- writes with no session (service_role here): by table × op × day, and pairing
SELECT 'NOSESSION|' || cl.table_name || '|' || cl.db_role || '|' || to_char(cl.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD') || '|' || cl.op || '|' || count(*)
  FROM change_log cl WHERE cl.table_name IN ('employees','performance_reviews') AND cl.actor_kind = 'no_session'
 GROUP BY cl.table_name, cl.db_role, to_char(cl.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD'), cl.op ORDER BY 1;
SELECT 'NOSESSION_PAIRING|' || cl.table_name || '|inserted=' || count(*) FILTER (WHERE op = 'INSERT')
    || '|later_deleted=' || count(*) FILTER (WHERE op = 'INSERT' AND EXISTS (SELECT 1 FROM change_log d WHERE d.table_name = cl.table_name AND d.op = 'DELETE' AND d.row_key = cl.row_key AND d.seq > cl.seq))
    || '|still_present=' || count(*) FILTER (WHERE op = 'INSERT' AND (
          (cl.table_name = 'employees' AND EXISTS (SELECT 1 FROM employees e WHERE e.id::text = cl.row_key->>'id'))
       OR (cl.table_name = 'performance_reviews' AND EXISTS (SELECT 1 FROM performance_reviews p WHERE p.id::text = cl.row_key->>'id'))))
    || '|updates=' || count(*) FILTER (WHERE op = 'UPDATE') || '|deletes=' || count(*) FILTER (WHERE op = 'DELETE')
  FROM change_log cl WHERE cl.table_name IN ('employees','performance_reviews') AND cl.actor_kind = 'no_session' GROUP BY cl.table_name ORDER BY 1;
-- the no-session rows' employee codes / names (to tie them to the smoke and probe helpers' prefixes)
SELECT 'NOSESSION_EMP_PREFIX|' || x.p || '|' || count(*) FROM (
  SELECT left(COALESCE(cl.new->>'employee_code', cl.old->>'employee_code', cl.new->>'full_name', cl.old->>'full_name', '?'), 9) AS p
    FROM change_log cl WHERE cl.table_name = 'employees' AND cl.actor_kind = 'no_session') x GROUP BY x.p ORDER BY 1;
SELECT 'NOSESSION_UPDATE_COLS|' || cl.table_name || '|' || COALESCE(array_to_string(cl.changed_columns, ','), '-') || '|' || count(*)
  FROM change_log cl WHERE cl.table_name IN ('employees','performance_reviews') AND cl.actor_kind = 'no_session' AND cl.op = 'UPDATE'
 GROUP BY cl.table_name, cl.changed_columns ORDER BY 1;
-- any anon or no_session write on ANY table since the log began (context for "actor not an authenticated user")
SELECT 'ALL_NONUSER|' || cl.table_name || '|' || cl.actor_kind || '|' || cl.db_role || '|' || count(*)
  FROM change_log cl WHERE NOT (cl.actor_kind = 'user' AND cl.db_role = 'authenticated') GROUP BY cl.table_name, cl.actor_kind, cl.db_role ORDER BY 1;
ROLLBACK;
