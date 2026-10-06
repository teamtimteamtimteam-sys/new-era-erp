-- db/scripts/2026-10-06-mes1-live-role-table.sql
-- MES-1 · 线上逐角色读数表(委托书 §Live verification:"Read the device page, inbox and pending-values page as the 7 real roles' permissions")
--   以七个真账号各自的身份(SET LOCAL ROLE authenticated + 那个人的 JWT —— PostgREST 对每一次请求做的就是这两件事)读三页的数据源:
--   设备页(devices · gateway_health · gateway_keys_masked)、收件箱(ingest_inbox · ingest_transmissions)、待补的标准值(pending_values),
--   外加两扇门(module.processing.view 开页、action.manage_devices 开控件)与两条不该通的路(基表 key_hash、员工直调 ingest_submit)。
--   读的对象是探针网关 :'gw'(它此刻已停用,行都还在)。
--   每一格写的是"读到了什么":一个数 / 一个值 / 42501(被拒)/ no rows。
-- 以 postgres 跑(psql -v gw=<网关 uuid>),一笔事务,ROLLBACK;不写任何东西。
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE m1_who (email text, uid uuid, role text);
INSERT INTO m1_who
SELECT u.email, u.id, (SELECT string_agg(r.code, '+' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                        WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
  FROM auth.users u WHERE u.email NOT LIKE '%@test.local' ORDER BY u.email;
GRANT SELECT ON m1_who TO authenticated;
CREATE TEMP TABLE m1_gw (id uuid);
INSERT INTO m1_gw VALUES (:'gw');
GRANT SELECT ON m1_gw TO authenticated;

CREATE TEMP TABLE m1_out (email text, role text, item text, got text);
GRANT INSERT, SELECT ON m1_out TO authenticated;

CREATE FUNCTION pg_temp.m1_cell(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    EXECUTE p_sql INTO v;
    RETURN COALESCE(v, 'no rows');
EXCEPTION WHEN insufficient_privilege THEN
    RETURN '42501';
WHEN OTHERS THEN
    RETURN 'error: ' || left(SQLERRM, 60);
END $f$;

DO $$
DECLARE w record; g uuid;
BEGIN
    SELECT id INTO g FROM m1_gw;
    FOR w IN SELECT * FROM m1_who ORDER BY email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', w.uid), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO m1_out VALUES
        (w.email, w.role, '1 door: the three pages (module.processing.view)',
            pg_temp.m1_cell('SELECT CASE WHEN has_permission(''module.processing.view'') THEN ''opens'' ELSE ''Restricted page'' END')),
        (w.email, w.role, '2 door: register / keys / retry / discard / limits (action.manage_devices)',
            pg_temp.m1_cell('SELECT CASE WHEN has_permission(''action.manage_devices'') THEN ''pressable'' ELSE ''disabled, names the code'' END')),
        (w.email, w.role, '3 devices page: probe gateway + device rows',
            pg_temp.m1_cell(format('SELECT count(*)::text FROM devices WHERE id = %L OR gateway_id = %L', g, g))),
        (w.email, w.role, '4 devices page: probe gateway status',
            pg_temp.m1_cell(format('SELECT status || '' · keys '' || active_keys FROM gateway_health WHERE gateway_id = %L', g))),
        (w.email, w.role, '5 device page: keys (masked view) · hash',
            pg_temp.m1_cell(format('SELECT count(*) || '' rows · hash '' || COALESCE(max(key_hash::text), ''NULL'') FROM gateway_keys_masked WHERE gateway_id = %L', g))),
        (w.email, w.role, '6 base table gateway_keys.key_hash',
            pg_temp.m1_cell(format('SELECT count(key_hash)::text FROM gateway_keys WHERE gateway_id = %L', g))),
        (w.email, w.role, '7 inbox: probe rows (by status)',
            pg_temp.m1_cell(format('SELECT string_agg(status || '' '' || n, '', '' ORDER BY status) FROM (SELECT status, count(*) n FROM ingest_inbox WHERE gateway_id = %L GROUP BY status) x', g))),
        (w.email, w.role, '8 device page: transmission log rows',
            pg_temp.m1_cell(format('SELECT count(*)::text FROM ingest_transmissions WHERE gateway_id = %L', g))),
        (w.email, w.role, '9 device page: outages',
            pg_temp.m1_cell(format('SELECT count(*)::text FROM gateway_outages WHERE gateway_id = %L', g))),
        (w.email, w.role, '10 pending values: rows visible (V5 · V6)',
            pg_temp.m1_cell('SELECT count(*) || '' (V5 '' || count(*) FILTER (WHERE value_code = ''V5'') || '' · V6 '' || count(*) FILTER (WHERE value_code = ''V6'') || '')'' FROM pending_values')),
        (w.email, w.role, '11 staff session calling ingest_submit directly',
            pg_temp.m1_cell('SELECT ingest_submit(''x'', ''y'', ''{}''::jsonb)::text'));
        EXECUTE 'RESET ROLE';
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
END $$;

SELECT item, email, role, got FROM m1_out ORDER BY item COLLATE "C", email;
ROLLBACK;
