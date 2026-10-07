-- db/scripts/2026-10-06-mes3a-live-role-table.sql
-- MES-3a · 线上逐角色读数表(委托书 §Live verification:"Read /inventory/storage-safety, a batch page and the location editor as the
--   7 real roles' permissions; record what each sees, as a table")。
--   先在本事务里造出三页要读的东西(一个 NEA 类别 + 线上在效执照下的一条上限 · 一张归了类的收货带一条开着的状态 ·
--   一张收在普通库位、之后记上"鼓包或漏液"的收货 —— 记状态从不拒,于是它出现在隔离那一段 · 一个普通库位),
--   再以七个真账号各自的身份(SET LOCAL ROLE authenticated + 那个人的 JWT)读三页的数据源与门。
--   每一格写的是"读到了什么":一个数 / yes·no(门)/ 42501(被拒)。
-- 以 postgres 跑:psql -X -v ON_ERROR_STOP=1 -f 本文件。一笔事务,ROLLBACK —— 造出来的东西一行都不留;既有单据只读。
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE m3_who (email text, uid uuid, role text);
INSERT INTO m3_who
SELECT u.email, u.id, (SELECT string_agg(r.code, '+' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                        WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
  FROM auth.users u WHERE u.email NOT LIKE '%@test.local' ORDER BY u.email;
CREATE TEMP TABLE m3_obj (b1 uuid, b2 uuid, loc uuid);
GRANT SELECT ON m3_obj TO authenticated;

CREATE FUNCTION pg_temp.m3_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true) $f$;
CREATE FUNCTION pg_temp.m3_do(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.m3_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'ROLE TABLE setup: % — %', SQLSTATE, SQLERRM;
END $f$;
-- 一格:以某人身份跑一句数数的 SQL;被拒写 42501
CREATE FUNCTION pg_temp.m3_cell(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.m3_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        EXECUTE p_sql INTO v;
    EXCEPTION WHEN insufficient_privilege THEN v := '42501';
    WHEN OTHERS THEN v := 'error: ' || left(SQLERRM, 50);
    END;
    EXECUTE 'RESET ROLE';
    RETURN COALESCE(v, 'no rows');
END $f$;

DO $$
DECLARE
    u_wh uuid := (SELECT id FROM auth.users WHERE email = 'fusheng@evoltrya.test');
    u_adm uuid := (SELECT id FROM auth.users WHERE email = 'admin@swm-os.test');
    d date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    lic uuid := storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore')::date);
    sup uuid; mat uuid; loc uuid; b1 uuid; b2 uuid;
BEGIN
    IF lic IS NULL THEN RAISE EXCEPTION 'ROLE TABLE setup: no licence in force today'; END IF;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES3A-RS', 'MES-3a role table supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    PERFORM pg_temp.m3_do(u_adm, $q$WITH x AS (INSERT INTO nea_waste_categories (code, name_en, name_zh) VALUES ('ZZR3A', 'MES-3a role probe', 'MES-3a 角色探针') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
    PERFORM pg_temp.m3_do(u_adm, format($q$WITH x AS (INSERT INTO licence_storage_limits (licence_id, category_code, limit_tonnes) VALUES (%L, 'ZZR3A', 5) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$, lic));
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code, nea_waste_category_code)
    VALUES ('ZZ-PROBE-MES3A-RM', 'MES-3a role probe', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction', 'ZZR3A') RETURNING id INTO mat;
    loc := (pg_temp.m3_do(u_adm, $q$SELECT to_jsonb(save_storage_location('ZZ-PROBE-MES3A-RL', 'MES-3a role probe rack', ARRAY[]::text[]))$q$)) #>> '{}';
    b1 := (pg_temp.m3_do(u_wh, format($q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 1000, p_unit => 'kg',
            p_arrival_date => %L, p_location_id => %L, p_safety_states => ARRAY['water_exposed'], p_chemistry_certainty => 'single_known',
            p_source_reason_code => 'other', p_source_reason_note => 'MES-3a role table') -> 'batch_id'$q$, mat, sup, d, loc))) #>> '{}';
    b2 := (pg_temp.m3_do(u_wh, format($q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 200, p_unit => 'kg',
            p_arrival_date => %L, p_location_id => %L, p_chemistry_certainty => 'single_known',
            p_source_reason_code => 'other', p_source_reason_note => 'MES-3a role table') -> 'batch_id'$q$, mat, sup, d, loc))) #>> '{}';
    PERFORM pg_temp.m3_do(u_wh, format($q$SELECT set_inbound_safety_states(%L, ARRAY['swollen_leaking'])$q$, b2));
    INSERT INTO m3_obj VALUES (b1, b2, loc);
END $$;

\pset format aligned
\pset border 2
SELECT w.email, w.role,
       pg_temp.m3_cell(w.uid, $q$SELECT CASE WHEN has_permission('module.inventory.view') THEN 'yes' ELSE 'restricted' END$q$) AS "safety page",
       pg_temp.m3_cell(w.uid, $q$SELECT count(*)::text FROM storage_ceiling_status$q$) AS "ceiling rows",
       pg_temp.m3_cell(w.uid, $q$SELECT count(*)::text FROM safety_state_dwell WHERE batch_id IN (SELECT b1 FROM m3_obj UNION SELECT b2 FROM m3_obj)$q$) AS "dwell rows",
       pg_temp.m3_cell(w.uid, $q$SELECT count(*)::text FROM quarantine_exposure WHERE batch_id = (SELECT b2 FROM m3_obj)$q$) AS "quarantine rows",
       pg_temp.m3_cell(w.uid, $q$SELECT CASE WHEN has_permission('module.inbound.view') THEN 'yes' ELSE 'restricted' END$q$) AS "batch page",
       pg_temp.m3_cell(w.uid, $q$SELECT count(*)::text FROM inbound_batch_safety_states WHERE inbound_batch_id IN (SELECT b1 FROM m3_obj UNION SELECT b2 FROM m3_obj)$q$) AS "state rows",
       pg_temp.m3_cell(w.uid, $q$SELECT string_agg(outcome, ',' ORDER BY outcome) FROM receipt_ceiling_checks WHERE inbound_batch_id IN (SELECT b1 FROM m3_obj UNION SELECT b2 FROM m3_obj)$q$) AS "ceiling record",
       pg_temp.m3_cell(w.uid, $q$SELECT CASE WHEN has_permission('module.inbound.edit') THEN 'yes' ELSE 'no (shown, disabled)' END$q$) AS "end a state",
       pg_temp.m3_cell(w.uid, $q$SELECT CASE WHEN has_permission('module.inventory.view') THEN 'yes' ELSE 'restricted' END$q$) AS "location editor",
       pg_temp.m3_cell(w.uid, $q$SELECT CASE WHEN has_permission('module.inventory.edit') THEN 'yes' ELSE 'no (shown, disabled)' END$q$) AS "mark quarantine",
       pg_temp.m3_cell(w.uid, $q$SELECT count(*)::text FROM operations_now WHERE item_type = 'quarantine_required' AND item_id = (SELECT b2 FROM m3_obj)$q$) AS "quarantine reminder"
  FROM m3_who w ORDER BY w.email;

ROLLBACK;
