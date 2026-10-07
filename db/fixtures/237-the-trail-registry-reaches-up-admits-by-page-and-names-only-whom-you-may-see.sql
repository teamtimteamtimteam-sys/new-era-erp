-- 237 AUDIT-TRAIL-1b-1:审计记录登记表的六个扩展(M1–M6)与折入 1(人名按别的页面同一条规矩受限)(2026-09-29)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1b Step 0 的 M1–M6 与 Tim 2026-09-29 的折入 1,全部照建议裁定)
--   M1 一页认【任一】个码:临时主语 fx237_any 认 module.sales.view 或 module.suppliers.view —— 只持其中一个的读者都进得去,
--      两个都不持的按名拒(TRAIL_NOT_PERMITTED)
--   M2 "记录开始之前"的人记成【员工 id】:一张 22/09 之前签收的交接班,签收人是员工 —— 拼回来的那一行认得出这个人,
--      而不是读成 Removed account
--   M3 页面的码就是门:只持 module.processing.view 的读者进得了设备的审计记录(根表 fixed_assets 只给财务读);
--      资产卡自己的那一行对他是 row_hidden,保养那一行看得见;持财务的读者两行都看得见;一个码都不持的按名拒
--   M4 往上一跳:进料批次够得到它收货的采购单的审批与修改史,而采购单本身的行一行都不进来(垫脚石)
--   M5 单行设置表(主键是 boolean):临时主语 fx237_settings 的记录【读得到】它的改动 —— 不是空着而不报错
--   M6 只取几列:fx237_settings 只管 wo_input_overrun_pct —— 只动了 notes 的那一次不出现;两列都动的那一次只剩这一列
--   A  折入 1(AT-1a 决定 1 推翻):采购单(PO 页)· 加工单 · 角色 · 汇总页的读法 —— 不持 module.hr.view 的读者看到别人
--      是 restricted、看到他自己是 person;持 module.hr.view 的读者看到名字。System (automatic) 不受影响。
--
-- 【临时主语】M1 · M5 · M6 在 1b-1 没有真主语用到(1b-2 的发货单、1b-3 的阈值面板会用),所以本支在自己的事务里
--   把两个临时主语【加进】trail_subjects()(照原函数的定义改一处 VALUES,EXECUTE)—— 随 ROLLBACK 一起消失。
-- 自带数据(README 第 2 条)。后几次操作是直接插进 change_log 的合成行(fixture 234 / 236 同一个做法)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f237_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f237_json(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f237_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

CREATE FUNCTION pg_temp.f237_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 200) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT pg_temp.f237_json(p_user, format(
        'SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), ''[]''::jsonb) FROM record_trail(%L, %L, %s) r',
        p_subject, p_id, p_n))
$f$;

CREATE FUNCTION pg_temp.f237_log(p_tx bigint, p_at timestamptz, p_table text, p_key jsonb, p_op text, p_kind text,
                                 p_account uuid, p_employee uuid, p_cols text[], p_old jsonb, p_new jsonb) RETURNS bigint
LANGUAGE sql AS $f$
    INSERT INTO change_log (occurred_at, txid, table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role,
                            changed_columns, old, new)
    VALUES (p_at, p_tx, p_table, p_key, p_op, p_account, p_employee, p_kind,
            CASE WHEN p_kind = 'no_session' THEN 'postgres' ELSE 'authenticated' END, p_cols, p_old, p_new)
    RETURNING seq
$f$;

-- 两个临时主语(M1 · M5 · M6):照 trail_subjects() 今天的定义,在 VALUES 的末尾加两行
DO $reg$
DECLARE d text;
BEGIN
    d := pg_get_functiondef('public.trail_subjects()'::regprocedure);
    IF position(E'\n    ) AS s(subject' IN d) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 237 setup: trail_subjects() no longer has the shape this fixture extends';
    END IF;
    d := replace(d, E'\n    ) AS s(subject', E',\n        (''fx237_any'', ARRAY[''module.sales.view'', ''module.suppliers.view''], ''fixed_assets'', ''id'', ''page'', NULL),'
        || E'\n        (''fx237_settings'', ARRAY[''module.processing.view''], ''processing_settings'', ''id'', ''table'', ARRAY[''wo_input_overrun_pct''])'
        || E'\n    ) AS s(subject');
    EXECUTE d;
END;
$reg$;

DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 持全部码(也持 module.hr.view)
    u_buy   uuid := gen_random_uuid();   -- module.purchasing.view,不持 module.hr.view;挂着一个员工(他自己)
    u_proc  uuid := gen_random_uuid();   -- module.processing.view,不持 module.hr.view、不持财务
    u_role  uuid := gen_random_uuid();   -- action.manage_permissions,不持 module.hr.view
    u_cl    uuid := gen_random_uuid();   -- data.view_change_log,不持 module.hr.view
    u_sales uuid := gen_random_uuid();   -- 只有 module.sales.view
    u_supp  uuid := gen_random_uuid();   -- 只有 module.suppliers.view
    u_no    uuid := gen_random_uuid();   -- 一个码都不持
    r_all uuid; r_buy uuid; r_proc uuid; r_role uuid; r_cl uuid; r_sales uuid; r_supp uuid;
    e_all uuid := gen_random_uuid(); e_buy uuid := gen_random_uuid(); e_out uuid := gen_random_uuid(); e_in uuid := gen_random_uuid();
    v_ccy text; v_sup uuid; v_mat uuid; v_matB uuid; v_r jsonb; v_po uuid; v_line uuid; v_ib uuid; v_run uuid; v_fa uuid; v_ho uuid;
    v_tx0 bigint := txid_current(); v_now timestamptz := clock_timestamp(); v_began timestamptz := change_log_began_at();
    v_j jsonb; v_x jsonb; v_n int; v_miss text;
BEGIN
    -- ══════════════ 布景 ══════════════
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, approvals_enabled = false;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx237-all@test.local', now()), (u_buy, 'fx237-buy@test.local', now()), (u_proc, 'fx237-proc@test.local', now()),
        (u_role, 'fx237-role@test.local', now()), (u_cl, 'fx237-cl@test.local', now()), (u_sales, 'fx237-sales@test.local', now()),
        (u_supp, 'fx237-supp@test.local', now()), (u_no, 'fx237-no@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx237-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx237-buy', 'f', 'f', true) RETURNING id INTO r_buy;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx237-proc', 'f', 'f', true) RETURNING id INTO r_proc;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx237-role', 'f', 'f', true) RETURNING id INTO r_role;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx237-cl', 'f', 'f', true) RETURNING id INTO r_cl;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx237-sales', 'f', 'f', true) RETURNING id INTO r_sales;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx237-supp', 'f', 'f', true) RETURNING id INTO r_supp;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_buy, 'module.purchasing.view'), (r_buy, 'module.inbound.view'), (r_proc, 'module.processing.view'),
        (r_role, 'action.manage_permissions'), (r_cl, 'data.view_change_log'), (r_sales, 'module.sales.view'),
        (r_supp, 'module.suppliers.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all, r_all), (u_buy, r_buy), (u_proc, r_proc), (u_role, r_role), (u_cl, r_cl), (u_sales, r_sales), (u_supp, r_supp);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, user_id) VALUES
        (e_all, 'FX237-ALL', 'Fixture Two Three Seven', 'Fx237 Tim', 'full_time', 'office', DATE '2020-01-01', 'active', u_all),
        (e_buy, 'FX237-BUY', 'Fixture Buyer', 'Fx237 Buyer', 'full_time', 'office', DATE '2020-01-01', 'active', u_buy),
        (e_out, 'FX237-OUT', 'Fixture Outgoing', 'Fx237 Out', 'full_time', 'shopfloor', DATE '2020-01-01', 'active', NULL),
        (e_in,  'FX237-IN',  'Fixture Incoming', 'Fx237 In',  'full_time', 'shopfloor', DATE '2020-01-01', 'active', NULL);
    PERFORM pg_temp.f237_as(u_all);

    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ237-S1', 'Fixture 237 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ237-M1', 'Fixture 237 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ237-M2', 'Fixture 237 output', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;

    -- ══════════════ M4 · 往上一跳:批次 → 它收货的采购单的审批与修改史;采购单本身不进来 ══════════════
    v_r := create_purchase_order(v_sup, CURRENT_DATE, CURRENT_DATE + 30, v_ccy, NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg', 'estimated_unit_price', 10)),
        p_category => 'equipment_goods');
    v_po := (v_r ->> 'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    PERFORM amend_purchase_order(v_po, 'fixture 237 amend', jsonb_build_object('notes', 'Deliver in two lots'));
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('ZZ237-IB1', v_mat, v_sup, 100, 100, 'kg', CURRENT_DATE, v_po, v_line) RETURNING id INTO v_ib;
    v_j := pg_temp.f237_trail(u_all, 'inbound_batch', v_ib::text);
    IF v_j ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 M4: %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'approval_log' AND e -> 'new' ->> 'subject_type' = 'purchase_order')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'purchase_order_history') THEN
        RAISE EXCEPTION 'FIXTURE 237 M4: the batch does not reach its purchase order''s approval and amendment: %', v_j;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' IN ('purchase_orders', 'purchase_order_lines')) THEN
        RAISE EXCEPTION 'FIXTURE 237 M4: the purchase order''s own rows leaked into the batch trail (a stepping stone is not shown)';
    END IF;

    -- ══════════════ M3 · 页面的码就是门 ══════════════
    INSERT INTO fixed_assets (code, description, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, category)
    VALUES ('ZZ237-FA1', 'Fixture 237 shredder', CURRENT_DATE - 30, 1000, v_ccy, 1, 1000, 60, 'equipment') RETURNING id INTO v_fa;
    INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description, performed_by_name)
    VALUES (v_fa, CURRENT_DATE, 'service', 'Changed the blades', 'Fixture technician');
    v_x := pg_temp.f237_trail(u_proc, 'equipment', v_fa::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 M3: a processing-only reader was refused the equipment trail: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'equipment_maintenance')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 237 M3: the processing reader should see the service and a Restricted asset-card row: %', v_x;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'fixed_assets') THEN
        RAISE EXCEPTION 'FIXTURE 237 M3: the asset card leaked to a reader without finance';
    END IF;
    v_x := pg_temp.f237_trail(u_all, 'equipment', v_fa::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 M3: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'fixed_assets') THEN
        RAISE EXCEPTION 'FIXTURE 237 M3: a finance reader should see the asset card row: %', v_x;
    END IF;
    v_x := pg_temp.f237_trail(u_no, 'equipment', v_fa::text);
    IF COALESCE(v_x ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 237 M3: a reader without the page''s code should be refused, got %', v_x;
    END IF;
    v_x := pg_temp.f237_json(u_proc, format('SELECT to_jsonb(count(*)) FROM equipment_usage WHERE equipment_id = %L', v_fa));
    IF v_x IS DISTINCT FROM '1'::jsonb THEN RAISE EXCEPTION 'FIXTURE 237 M3: the equipment list does not show the machine to a processing reader: %', v_x; END IF;

    -- ══════════════ M1 · 任一个码 ══════════════
    v_x := pg_temp.f237_trail(u_sales, 'fx237_any', v_fa::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 M1: a reader holding the first code was refused: %', v_x; END IF;
    v_x := pg_temp.f237_trail(u_supp, 'fx237_any', v_fa::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 M1: a reader holding the second code was refused: %', v_x; END IF;
    v_x := pg_temp.f237_trail(u_proc, 'fx237_any', v_fa::text);
    IF COALESCE(v_x ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 237 M1: a reader holding neither code should be refused, got %', v_x;
    END IF;

    -- ══════════════ M5 · M6 · 单行设置表,只取一列 ══════════════
    PERFORM pg_temp.f237_log(v_tx0 + 1, v_now + interval '1 min', 'processing_settings', '{"id": true}', 'UPDATE', 'user', u_all, e_all,
        ARRAY['wo_input_overrun_pct'], '{"wo_input_overrun_pct": 10}', '{"wo_input_overrun_pct": 12}');
    PERFORM pg_temp.f237_log(v_tx0 + 2, v_now + interval '2 min', 'processing_settings', '{"id": true}', 'UPDATE', 'user', u_all, e_all,
        ARRAY['notes'], '{"notes": null}', '{"notes": "only the notes"}');
    PERFORM pg_temp.f237_log(v_tx0 + 3, v_now + interval '3 min', 'processing_settings', '{"id": true}', 'UPDATE', 'user', u_all, e_all,
        ARRAY['wo_input_overrun_pct', 'notes'], '{"wo_input_overrun_pct": 12, "notes": "only the notes"}', '{"wo_input_overrun_pct": 15, "notes": "both"}');
    v_x := pg_temp.f237_trail(u_all, 'fx237_settings', 'true');
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 M5: %', v_x; END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'processing_settings';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 237 M5/M6: expected the two changes that touch wo_input_overrun_pct (boolean key matched, notes-only change left out), got % rows: %', v_n, v_x;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'processing_settings'
                 AND (e -> 'changed_columns' ? 'notes' OR e -> 'new' ? 'notes' OR e -> 'old' ? 'notes')) THEN
        RAISE EXCEPTION 'FIXTURE 237 M6: a column the panel does not own leaked into its trail: %', v_x;
    END IF;

    -- ══════════════ M2 · 员工 id 记的人(22/09 之前签收的交接班)══════════════
    ALTER TABLE shift_handovers DISABLE TRIGGER zzz_change_log;
    INSERT INTO shift_handovers (shift_code, handover_date, outgoing_employee_id, incoming_employee_id, notes, submitted_at, submitted_by,
                                 acknowledged_at, acknowledged_by, created_at, created_by)
    VALUES ('day', (v_began - interval '3 days')::date, e_out, e_in, 'fixture 237 handover', v_began - interval '3 days', u_all,
            v_began - interval '2 days', e_all, v_began - interval '3 days', u_all)
    RETURNING id INTO v_ho;
    ALTER TABLE shift_handovers ENABLE TRIGGER zzz_change_log;
    v_x := pg_temp.f237_trail(u_all, 'shift_handover', v_ho::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 M2: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e
                    WHERE (e ->> 'prelog')::boolean AND e -> 'changed_columns' ? 'acknowledged_at'
                      AND e -> 'actor' ->> 'state' = 'person' AND e -> 'actor' ->> 'name' = 'Fx237 Tim') THEN
        RAISE EXCEPTION 'FIXTURE 237 M2: the acknowledgement recorded by employee id is not attributed to that person: %', v_x;
    END IF;

    -- ══════════════ A · 折入 1:人名受限,与 ActorName 同一条规矩 ══════════════
    -- 采购单(AT-1a 的 PO 页):建单的是 u_all(Fx237 Tim)。另一次改动由 u_buy 自己做(合成行)。
    PERFORM pg_temp.f237_log(v_tx0 + 4, v_now + interval '4 min', 'purchase_orders', jsonb_build_object('id', v_po), 'UPDATE', 'user', u_buy, e_buy,
        ARRAY['notes'], '{"notes": "Deliver in two lots"}', '{"notes": "Deliver in one lot"}');
    PERFORM pg_temp.f237_log(v_tx0 + 5, v_now + interval '5 min', 'purchase_orders', jsonb_build_object('id', v_po), 'UPDATE', 'no_session', NULL, NULL,
        ARRAY['notes'], '{"notes": "Deliver in one lot"}', '{"notes": "System touch"}');
    v_x := pg_temp.f237_trail(u_buy, 'purchase_order', v_po::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 A: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'state' = 'restricted')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'name' = 'Fx237 Tim') THEN
        RAISE EXCEPTION 'FIXTURE 237 A (PO): a reader without module.hr.view should see another person as restricted: %', v_x;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'name' = 'Fx237 Buyer') THEN
        RAISE EXCEPTION 'FIXTURE 237 A (PO): the reader should still see his own name: %', v_x;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'state' = 'system') THEN
        RAISE EXCEPTION 'FIXTURE 237 A (PO): System (automatic) is not a name and must not be restricted: %', v_x;
    END IF;
    v_x := pg_temp.f237_trail(u_all, 'purchase_order', v_po::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 237 A (PO): %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'name' = 'Fx237 Tim')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'state' = 'restricted') THEN
        RAISE EXCEPTION 'FIXTURE 237 A (PO): a reader with module.hr.view should see every name: %', v_x;
    END IF;
    -- 加工单(AT-1a 的加工单页)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ237-IB2', v_mat, v_sup, 20, 20, 'kg', CURRENT_DATE, 'other', 'fixture 237') RETURNING id INTO v_line;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v_line, 'discharged_verified');
    v_run := commit_processing_run(CURRENT_DATE, 'fixture 237 run', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_line, 'quantity_consumed', 20)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'weight_kg', 20)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => (CURRENT_DATE)::timestamptz, p_ended_at => LEAST((CURRENT_DATE)::timestamptz + interval '1 hour', now()), p_shift_code => 'day');
    v_x := pg_temp.f237_trail(u_proc, 'processing_run', v_run::text);
    IF v_x ? 'error' OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'state' = 'restricted')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'state' = 'person') THEN
        RAISE EXCEPTION 'FIXTURE 237 A (run): %', v_x;
    END IF;
    -- 角色(AT-1a 的角色页):u_all 建的角色,由持 action.manage_permissions、不持 module.hr.view 的人读
    PERFORM pg_temp.f237_log(v_tx0 + 6, v_now + interval '6 min', 'roles', jsonb_build_object('id', r_buy), 'UPDATE', 'user', u_all, e_all,
        ARRAY['name_en'], '{"name_en": "f"}', '{"name_en": "Buyers"}');
    v_x := pg_temp.f237_trail(u_role, 'role', r_buy::text);
    IF v_x ? 'error' OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'state' = 'restricted')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e -> 'actor' ->> 'state' = 'person') THEN
        RAISE EXCEPTION 'FIXTURE 237 A (role): %', v_x;
    END IF;
    -- 汇总页的读法(change_log_rows)经过同一个 trail_actor
    v_x := pg_temp.f237_json(u_cl, format(
        'SELECT jsonb_agg(r.actor) FROM change_log_rows(p_record_ids => ARRAY[%L], p_limit => 50) r', v_po));
    IF v_x ? 'error' OR NOT (v_x @> '[{"state": "restricted"}]'::jsonb) OR v_x @> '[{"state": "person"}]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 237 A (summary page): %', v_x;
    END IF;

    RAISE NOTICE 'FIXTURE 237 全部通过:M1–M6 · A(采购单 · 加工单 · 角色 · 汇总页)';
END;
$$;

ROLLBACK;
