\timing on
\pset pager off
BEGIN READ ONLY;
SET LOCAL statement_timeout = '120s';
SELECT now() AS at, current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypass,
       (SELECT setting FROM pg_settings WHERE name='statement_timeout') st,
       (SELECT array_to_string(rolconfig, ',') FROM pg_roles WHERE rolname='authenticated') auth_cfg;
SELECT set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT count(*) AS rows, count(DISTINCT txid) AS ops, min(seq), max(seq) FROM change_log_rows(p_by_entry => true, p_limit => 21);
SELECT count(*) AS rows, count(DISTINCT txid) AS ops FROM change_log_rows(p_by_entry => true, p_limit => 21);
RESET ROLE;
WITH t AS (SELECT c.txid, max(c.seq) mx, count(*) n FROM change_log c GROUP BY c.txid ORDER BY max(c.seq) DESC LIMIT 21)
SELECT txid, mx, n FROM t ORDER BY mx DESC;
\set R 'WITH t AS (SELECT c.txid FROM change_log c GROUP BY c.txid ORDER BY max(c.seq) DESC LIMIT 21) SELECT c.* FROM change_log c WHERE c.txid IN (SELECT txid FROM t)'
SELECT table_name, count(*) FROM (:R) r GROUP BY 1 ORDER BY 2 DESC;
SELECT count(*) AS base FROM (:R) r;
SELECT count(trail_actor(actor_kind, actor_account, actor_employee)) AS actor FROM (:R) r;
SELECT count(change_log_mask_row(table_name, row_key, old, new)) AS mask FROM (:R) r;
SELECT count((SELECT image FROM trail_current_image(table_name, row_key))) AS cimg FROM (:R) r;
SELECT count(trail_row_visible(table_name, row_key, COALESCE((SELECT image FROM trail_current_image(table_name, row_key)), new, old))) AS vis FROM (:R) r;
SELECT count(trail_row_record(table_name, row_key, old, new)) AS rec FROM (:R) r;
SELECT count(trail_refs(table_name, old, new, row_key)) AS refs FROM (:R) r;
ROLLBACK;
