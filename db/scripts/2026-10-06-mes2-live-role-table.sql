-- db/scripts/2026-10-06-mes2-live-role-table.sql
-- MES-2 · 线上逐角色读数表(委托书 §Live verification:"Read the capture queue, a ticket page and the calibration page as the 7 real
--   roles' permissions; record what each sees, as a table")。
--   先在本事务里造出三页要读的东西(探针网关送来的一张待确认草稿 · 一张完成了的进厂地磅单带一张照片登记行 · 一台秤带一次校准),
--   再以七个真账号各自的身份(SET LOCAL ROLE authenticated + 那个人的 JWT —— PostgREST 对每一次请求做的就是这两件事)读三页的数据源。
--   每一格写的是"读到了什么":一个数 / 一个值 / 42501(被拒)/ no rows。
-- 以 postgres 跑:psql -X -v ON_ERROR_STOP=1 -f 本文件。一笔事务,ROLLBACK —— 造出来的东西一行都不留。
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE m2_who (email text, uid uuid, role text);
INSERT INTO m2_who
SELECT u.email, u.id, (SELECT string_agg(r.code, '+' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                        WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
  FROM auth.users u WHERE u.email NOT LIKE '%@test.local' ORDER BY u.email;
GRANT SELECT ON m2_who TO authenticated;
CREATE TEMP TABLE m2_obj (draft uuid, ticket uuid, scale uuid);
GRANT SELECT ON m2_obj TO authenticated;
CREATE TEMP TABLE m2_out (email text, role text, item text, got text);
GRANT INSERT, SELECT ON m2_out TO authenticated;

CREATE FUNCTION pg_temp.m2_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true) $f$;
CREATE FUNCTION pg_temp.m2_do(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.m2_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'ROLE TABLE setup: % — %', SQLSTATE, SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.m2_cell(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    EXECUTE p_sql INTO v;
    RETURN COALESCE(v, 'no rows');
EXCEPTION WHEN insufficient_privilege THEN
    RETURN '42501';
WHEN OTHERS THEN
    RETURN 'error: ' || left(SQLERRM, 60);
END $f$;

-- ── 造三页要读的东西(以真账号的身份走真函数)──────────────────────────────────────────────
DO $$
DECLARE
    u_wh uuid := (SELECT id FROM auth.users WHERE email = 'fusheng@evoltrya.test');
    u_cto uuid := (SELECT id FROM auth.users WHERE email = 'phua@evolytra.test');
    gw uuid; gw_code text; sc uuid; sc_code text; key text; dr uuid; tk uuid; v jsonb;
BEGIN
    gw := (pg_temp.m2_do(u_cto, $q$SELECT to_jsonb(save_device('{"name":"ZZ-PROBE-GW-MES2-ROLES","kind":"gateway"}'::jsonb))$q$)) #>> '{}';
    SELECT code INTO gw_code FROM devices WHERE id = gw;
    sc := (pg_temp.m2_do(u_cto, format($q$SELECT to_jsonb(save_device(jsonb_build_object('name','ZZ-PROBE-SCALE-MES2-ROLES','kind','scale','gateway_id',%L,'data_class','weighing','station','Probe','interface_status','connected','capacity',20,'unit','t')))$q$, gw))) #>> '{}';
    SELECT code INTO sc_code FROM devices WHERE id = sc;
    key := pg_temp.m2_do(u_cto, format('SELECT issue_gateway_key(%L)', gw)) ->> 'secret';
    PERFORM pg_temp.m2_do(u_cto, format($q$SELECT to_jsonb(record_instrument_calibration(%L, %L, %L, 'passed', 'ROLE-TABLE-CERT', 'Accredited Lab'))$q$, sc, CURRENT_DATE - 30, CURRENT_DATE + 335));
    PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE 'SET LOCAL ROLE anon';
    v := ingest_submit(gw_code, key, jsonb_build_object('stream', 'mes2-roles', 'messages', jsonb_build_array(
        jsonb_build_object('seq', 1, 'device', sc_code, 'class', 'weighing', 'payload', '{"weight_kg": 777}'::jsonb,
                           'site_from', now() - interval '2 minutes', 'site_to', now() - interval '1 minute'))));
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.m2_do(u_wh, 'SELECT ingest_process_pending(50)');
    SELECT c.id INTO dr FROM capture_drafts c JOIN ingest_inbox b ON b.id = c.inbox_id WHERE b.gateway_id = gw;
    v := pg_temp.m2_do(u_wh, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 12000}'::jsonb, %L::uuid, NULL, NULL, '{"new_ticket": {"direction": "inbound", "vehicle_reg": "ZZ ROLES"}}'::jsonb)$q$, sc));
    tk := (SELECT ticket_id FROM weighings WHERE id = (v ->> 'weighing_id')::uuid);
    PERFORM pg_temp.m2_do(u_wh, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 4000}'::jsonb, %L::uuid, NULL, NULL, %L::jsonb)$q$, sc, jsonb_build_object('ticket_id', tk)));
    PERFORM pg_temp.m2_do(u_wh, format($q$SELECT to_jsonb(record_ticket_photo(%L, %L, 'front.jpg', 'image/jpeg', 2048))$q$, tk, tk::text || '/role-table-front.jpg'));
    IF dr IS NULL OR tk IS NULL THEN RAISE EXCEPTION 'ROLE TABLE setup: draft % / ticket %', dr, tk; END IF;
    INSERT INTO m2_obj VALUES (dr, tk, sc);
END $$;

DO $$
DECLARE w record; o record;
BEGIN
    SELECT * INTO o FROM m2_obj;
    FOR w IN SELECT * FROM m2_who ORDER BY email LOOP
        PERFORM pg_temp.m2_as(w.uid);
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO m2_out VALUES
        (w.email, w.role, '01 door: capture queue + calibration page (module.processing.view)',
            pg_temp.m2_cell('SELECT CASE WHEN has_permission(''module.processing.view'') THEN ''opens'' ELSE ''Restricted page'' END')),
        (w.email, w.role, '02 door: weighbridge pages (module.inbound.view OR module.logistics.view)',
            pg_temp.m2_cell('SELECT CASE WHEN has_permission(''module.inbound.view'') OR has_permission(''module.logistics.view'') THEN ''opens'' ELSE ''Restricted page'' END')),
        (w.email, w.role, '03 confirm / reject / manual / correct / ticket void / photo (action.confirm_capture)',
            pg_temp.m2_cell('SELECT CASE WHEN has_permission(''action.confirm_capture'') THEN ''pressable'' ELSE ''disabled, names the code'' END')),
        (w.email, w.role, '04 record / void calibration + calibration settings (action.manage_devices)',
            pg_temp.m2_cell('SELECT CASE WHEN has_permission(''action.manage_devices'') THEN ''pressable'' ELSE ''disabled, names the code'' END')),
        (w.email, w.role, '05 capture queue: the pending draft (reading)',
            pg_temp.m2_cell(format('SELECT string_agg(status || '' '' || (proposed->>''weight_kg'') || '' kg'', '','') FROM capture_drafts WHERE id = %L', o.draft))),
        (w.email, w.role, '06 capture queue: recent weighings of the probe scale (calibration status)',
            pg_temp.m2_cell(format('SELECT count(*) || '' · '' || string_agg(DISTINCT status, '','') FROM weighing_calibration WHERE device_id = %L', o.scale))),
        (w.email, w.role, '07 base view weighing_calibration_all',
            pg_temp.m2_cell(format('SELECT count(*)::text FROM weighing_calibration_all WHERE device_id = %L', o.scale))),
        (w.email, w.role, '08 ticket page: status · gross / tare / net',
            pg_temp.m2_cell(format('SELECT status || '' · '' || gross_kg || '' / '' || tare_kg || '' / '' || net_kg FROM weighbridge_ticket_weights WHERE ticket_id = %L', o.ticket))),
        (w.email, w.role, '09 ticket page: weighing rows · photo rows',
            pg_temp.m2_cell(format('SELECT (SELECT count(*) FROM weighings WHERE ticket_id = %L) || '' · '' || (SELECT count(*) FROM weighbridge_ticket_photos WHERE ticket_id = %L)', o.ticket, o.ticket))),
        (w.email, w.role, '10 ticket page: the ticket row (code)',
            pg_temp.m2_cell(format('SELECT CASE WHEN count(*) = 1 THEN ''1 row'' ELSE count(*)::text END FROM weighbridge_tickets WHERE id = %L', o.ticket))),
        (w.email, w.role, '11 calibration page: probe scale status now',
            pg_temp.m2_cell(format('SELECT status || CASE WHEN in_use THEN '' · in use'' ELSE '''' END FROM instrument_calibration_now WHERE device_id = %L', o.scale))),
        (w.email, w.role, '12 calibration page: calibration records of the probe scale',
            pg_temp.m2_cell(format('SELECT count(*)::text FROM instrument_calibrations WHERE device_id = %L', o.scale))),
        (w.email, w.role, '13 calibration page: settings (switch · lead days)',
            pg_temp.m2_cell('SELECT COALESCE(require_calibrated_since::text, ''off'') || '' · '' || COALESCE(calibration_lead_days::text, ''not set'') FROM ingest_settings')),
        (w.email, w.role, '14 pending values visible (V8 · V33)',
            pg_temp.m2_cell('SELECT ''V8 '' || count(*) FILTER (WHERE value_code = ''V8'') || '' · V33 '' || count(*) FILTER (WHERE value_code = ''V33'') FROM pending_values')),
        (w.email, w.role, '15 reminder: capture_draft_pending arm rows',
            pg_temp.m2_cell('SELECT count(*)::text FROM operations_now WHERE item_type = ''capture_draft_pending''')),
        (w.email, w.role, '16 staff session calling the internal confirm (capture_confirm_internal)',
            pg_temp.m2_cell(format('SELECT capture_confirm_internal(%L, ''{}'', ''{}'', ''{}'', NULL, NULL)::text', o.draft)));
        EXECUTE 'RESET ROLE';
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
END $$;

SELECT item, email, role, got FROM m2_out ORDER BY item COLLATE "C", email;
ROLLBACK;
