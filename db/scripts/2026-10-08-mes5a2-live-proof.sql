-- db/scripts/2026-10-08-mes5a2-live-proof.sql
-- MES-5a-2 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关。
--   由 db/scripts/2026-10-08-mes5a2-live-proof.mjs 驱动:它先用 mintThrowaway 造一次性账号(前缀 mes5a2probe),
--   再以 psql 跑本文件,把那些邮箱经 -v 传进来;跑完按 ephemeral 计划收走账号、授权、一次性角色。
--   【每一步都以一次性账号跑】(Tim,MES-5a-1 close-out 裁定:证明里动手的是一次性账号,不是七个真账号):
--     dev   = module.processing.view + action.manage_devices            —— 设电表、把电表挂到机器上
--     cap   = module.processing.view + action.confirm_capture           —— 记读数
--     ops   = module.processing.view/edit + action.processing_commit/aftercare —— 提交炉次、记电量、手敲估计
--     finv  = module.finance.view + module.processing.view(没有 finance.edit、没有价格码)—— 过账被拒、金额遮住
--     c_<角色> = 七个真角色【此刻的码】的一次性克隆(cloneOf)—— 逐角色读数表、AP = 总账的勾稽;财务那一个过账
--   用的全是【自己造的】东西:ZZ-PROBE-MES5A2-* 供应商 / 物料 / 批次 / 两台机器 / 一道探针工序(克隆深度放电的配置,
--   另给它一个 energy_kwh 字段 —— 在册的工序一行都不碰)。在册的单据、批次、炉次、设备、安全状态一张都不碰、不决定、不改。
--   ① 两台电表:M1 挂我的机器 EQ,M2 不挂机器(共用池);没有 manage_devices 的人设不了。
--   ② 读数:M1 1000 → 1600;比前一条小的 1500 拒;M2 50 → 80,时间段之后清零到 5 —— 没理由拒、有理由收;没有 confirm_capture 记不了。
--   ③ 炉次(时间段内,机器 EQ):r1 记 30 kWh / 60 分钟 · r2 记 10 kWh / 120 分钟 → 预览按电量分 450 / 150;
--      再提交 r3(没记电量,60 分钟)→ 整台按运行时长分 150 / 300 / 150;每一行都带依据。
--      另一台没装表的机器 EQ2 上一炉 r4 带一条手敲估计 40(不动);r1 上手敲估计 50(被冲掉)。
--   ④ 预览 = 过账(逐键);一张费用单;一炉一条实际电费行(已结);那张分录 借 2200 / 借 6200 / 贷 2000 平;估计按上;
--      不计量与共用池留在 6200;AP 清单 = 总账,unexplained 0.00(过账前后)。外币账单按名拒;没有 finance.edit 的人过不了账;
--      没有价格码的读者:金额空、kWh 照见。
--   ⑤ 逐角色读数表(七个真角色的码):设备页 · 炉次页 · 分摊页各看见什么、能按什么。
-- 打印的每一行都是 STEP|… 或 ROLE|… ;任何一处与预期不符就 RAISE,整笔回滚。
-- 跑法:由驱动脚本跑;单独跑要自己给齐 -v dev= cap= ops= finv= c_admin= c_finance= c_warehouse= c_cto= c_cco= c_cfo= c_gm=
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SELECT set_config('mes5a2.dev', :'dev', true), set_config('mes5a2.cap', :'cap', true), set_config('mes5a2.ops', :'ops', true),
       set_config('mes5a2.finv', :'finv', true),
       set_config('mes5a2.c_admin', :'c_admin', true), set_config('mes5a2.c_finance', :'c_finance', true),
       set_config('mes5a2.c_warehouse', :'c_warehouse', true), set_config('mes5a2.c_cto', :'c_cto', true),
       set_config('mes5a2.c_cco', :'c_cco', true), set_config('mes5a2.c_cfo', :'c_cfo', true), set_config('mes5a2.c_gm', :'c_gm', true) \g /dev/null

CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid; e text := current_setting('mes5a2.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = e;
    IF v IS NULL OR e NOT LIKE 'mes5a2probe-%@test.local' THEN RAISE EXCEPTION 'MES5A2_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
CREATE FUNCTION pg_temp.try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.bal_(p_code text) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(l.debit - l.credit), 0) FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE a.code = p_code
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_(), pg_temp.try_(text) TO authenticated;

CREATE TEMP TABLE mes5a2_roles (who text, role text, codes_match boolean,
    device_page boolean, meter_rows int, set_meter boolean, record_reading boolean,
    run_page boolean, run_energy text, run_basis text, run_line_amount text,
    alloc_page boolean, alloc_rows int, alloc_bill_amount text, alloc_kwh text, alloc_lines int, post_bill boolean, v25_listed int,
    recon text) ON COMMIT DROP;
GRANT INSERT ON mes5a2_roles TO authenticated;

DO $live$
DECLARE
    d0 date := (now() AT TIME ZONE 'Asia/Singapore')::date - 20;
    d1 date := (now() AT TIME ZONE 'Asia/Singapore')::date - 11;
    t0 timestamptz; t1 timestamptz;
    v_base text := (SELECT code FROM currencies WHERE is_base);
    v_other text := (SELECT code FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1);
    sup uuid; m_mod uuid; b uuid; eq uuid; eq2 uuid; m1 uuid; m2 uuid;
    r1 uuid; r2 uuid; r3 uuid; r4 uuid; e1 uuid; e4 uuid;
    v_msg text; v_j jsonb; v_p jsonb; v_post jsonb; v_a record; v_alloc uuid; v_n bigint; v_x numeric;
    v_b2200 numeric; v_b6200 numeric; v_b2000 numeric; v_b5110 numeric;
    v_notif bigint := (SELECT count(*) FROM notifications);
    v_pending text := (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    v_fp_before text;
    v_exp_before bigint := (SELECT count(*) FROM expenses);
    r record;
BEGIN
    t0 := ((d0)::timestamp + interval '1 hour') AT TIME ZONE 'Asia/Singapore';
    t1 := ((d1)::timestamp + interval '23 hours') AT TIME ZONE 'Asia/Singapore';
    -- 在册的炉次、成本行、费用单、分录、付款、设备、安全状态:先记一个指纹,最后逐字比(只比【进来之前就在】的行)
    SELECT md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_cost_entries x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM devices x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text)) FROM inbound_batch_safety_states x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text)) FROM output_batch_safety_states x)))
      INTO v_fp_before;

    -- ══════════ 布景(以属主插:都是我自己的行)══════════
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES5A2-S', 'MES-5a-2 probe power utility', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES5A2-MOD', 'MES-5a-2 probe modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 chemistry_certainty_code)
    VALUES ('ZZ-PROBE-MES5A2-B', m_mod, sup, 5000, 5000, 'kg', d0 - 30, 'other', 'MES-5a-2 live proof', 'single_known') RETURNING id INTO b;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (b, 'charged_not_discharged');
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ-PROBE-MES5A2-EQ', 'MES-5a-2 probe machine (metered)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ-PROBE-MES5A2-EQ2', 'MES-5a-2 probe machine (no meter)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq2;
    -- 一道探针工序:深度放电配置的逐行克隆 + 一个 energy_kwh 字段(在册的深度放电一行都不碰)
    INSERT INTO operation_types SELECT (jsonb_populate_record(NULL::operation_types, to_jsonb(o)
        || jsonb_build_object('code', 'zz_probe_mes5a2', 'name_en', 'MES-5a-2 probe operation', 'name_zh', 'MES-5a-2 探针工序', 'sort_order', 999))).*
      FROM operation_types o WHERE o.code = 'deep_discharge';
    INSERT INTO operation_type_input_forms SELECT (jsonb_populate_record(NULL::operation_type_input_forms, to_jsonb(x) || '{"operation_type_code":"zz_probe_mes5a2"}'::jsonb)).*
      FROM operation_type_input_forms x WHERE x.operation_type_code = 'deep_discharge';
    INSERT INTO operation_type_output_forms SELECT (jsonb_populate_record(NULL::operation_type_output_forms, to_jsonb(x) || '{"operation_type_code":"zz_probe_mes5a2"}'::jsonb)).*
      FROM operation_type_output_forms x WHERE x.operation_type_code = 'deep_discharge';
    INSERT INTO operation_type_safety_states SELECT (jsonb_populate_record(NULL::operation_type_safety_states, to_jsonb(x) || '{"operation_type_code":"zz_probe_mes5a2"}'::jsonb)).*
      FROM operation_type_safety_states x WHERE x.operation_type_code = 'deep_discharge';
    INSERT INTO operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, sort_order, notes)
    VALUES ('zz_probe_mes5a2', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 90, 'MES-5a-2 live proof');
    RAISE NOTICE 'STEP|setup|probe supplier, material, batch ZZ-PROBE-MES5A2-B, machines ZZ-PROBE-MES5A2-EQ (metered) and -EQ2 (no meter), probe operation zz_probe_mes5a2 (clone of deep_discharge + energy_kwh); period % – %', d0, d1;

    -- ══════════ ① 两台电表 ══════════
    PERFORM pg_temp.as_('cap');
    v_msg := pg_temp.try_($q$SELECT save_device('{"name":"ZZ-PROBE-MES5A2 nope","kind":"meter"}'::jsonb)$q$);
    PERFORM pg_temp.as_('dev');
    m1 := save_device(jsonb_build_object('name', 'ZZ-PROBE-MES5A2 meter on EQ', 'kind', 'meter', 'equipment_id', eq));
    m2 := save_device('{"name":"ZZ-PROBE-MES5A2 shared-pool meter","kind":"meter"}'::jsonb);
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN RAISE EXCEPTION 'MES5A2_LIVE|a meter set up without action.manage_devices: %', v_msg; END IF;
    IF (SELECT kind FROM devices WHERE id = m1) <> 'meter' OR (SELECT equipment_id FROM devices WHERE id = m1) IS DISTINCT FROM eq
       OR (SELECT equipment_id FROM devices WHERE id = m2) IS NOT NULL THEN RAISE EXCEPTION 'MES5A2_LIVE|meters not as set'; END IF;
    RAISE NOTICE 'STEP|meters|dev made % on ZZ-PROBE-MES5A2-EQ and % with no machine (shared pool); cap (no action.manage_devices) refused: %',
        (SELECT code FROM devices WHERE id = m1), (SELECT code FROM devices WHERE id = m2), split_part(v_msg, '|', 1) || '|' || split_part(v_msg, '|', 2);

    -- ══════════ ② 读数 ══════════
    PERFORM pg_temp.as_('ops');
    v_msg := pg_temp.try_(format($q$SELECT record_meter_reading(%L, %L, 1000)$q$, m1, t0));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN RAISE EXCEPTION 'MES5A2_LIVE|a reading without action.confirm_capture: %', v_msg; END IF;
    PERFORM pg_temp.as_('cap');
    PERFORM record_meter_reading(m1, t0, 1000);
    PERFORM record_meter_reading(m1, t1, 1600);
    PERFORM record_meter_reading(m2, t0, 50);
    PERFORM record_meter_reading(m2, t1, 80);
    v_msg := pg_temp.try_(format($q$SELECT record_meter_reading(%L, %L, 1500)$q$, m1, t1 + interval '1 hour'));
    IF v_msg NOT LIKE 'METER_READING_BELOW_PREVIOUS|1500|1600%' THEN RAISE EXCEPTION 'MES5A2_LIVE|lower reading not refused: %', v_msg; END IF;
    RAISE NOTICE 'STEP|readings|cap recorded M1 1000 → 1600 and M2 50 → 80; ops (no action.confirm_capture) refused; M1 1500 after 1600 refused: %', v_msg;
    v_msg := pg_temp.try_(format($q$SELECT record_meter_reading(%L, %L, 5, true)$q$, m2, t1 + interval '2 hours'));
    IF v_msg NOT LIKE 'METER_RESET_REASON_REQUIRED%' THEN RAISE EXCEPTION 'MES5A2_LIVE|reset without a reason: %', v_msg; END IF;
    v_j := record_meter_reading(m2, t1 + interval '2 hours', 5, true, 'MES-5a-2 live proof: meter replaced');
    SELECT count(*) INTO v_n FROM meter_readings_current WHERE device_id = m2 AND is_register_reset AND delta_kwh IS NULL;
    PERFORM pg_temp.me_();
    IF v_n <> 1 THEN RAISE EXCEPTION 'MES5A2_LIVE|reset reading not current with an empty delta'; END IF;
    BEGIN
        UPDATE meter_readings SET register_kwh = 0 WHERE device_id = m1;
        RAISE EXCEPTION 'MES5A2_LIVE|a reading row was updated in place';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'APPEND_ONLY|meter_readings|update%' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'STEP|reset|M2 reset to 5 without a reason refused (METER_RESET_REASON_REQUIRED); with a reason accepted, delta empty; readings append-only (direct UPDATE: APPEND_ONLY)';

    -- ══════════ ③ 炉次 · 先都记了电量 ══════════
    PERFORM pg_temp.as_('ops');
    r1 := commit_processing_run(d0 + 3, 'MES-5a-2 live proof r1', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq, 'zz_probe_mes5a2', ((d0 + 3)::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore',
                                ((d0 + 3)::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    r2 := commit_processing_run(d0 + 3, 'MES-5a-2 live proof r2', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 50)), '[]'::jsonb,
                                'weight', NULL, eq, 'zz_probe_mes5a2', ((d0 + 3)::timestamp + interval '11 hours') AT TIME ZONE 'Asia/Singapore',
                                ((d0 + 3)::timestamp + interval '13 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    PERFORM record_run_value(r1, 'energy_kwh', '30'::jsonb);
    PERFORM record_run_value(r2, 'energy_kwh', '10'::jsonb);
    r4 := commit_processing_run(d0 + 4, 'MES-5a-2 live proof r4 (unmetered machine)', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq2, 'zz_probe_mes5a2', ((d0 + 4)::timestamp + interval '15 hours') AT TIME ZONE 'Asia/Singapore',
                                ((d0 + 4)::timestamp + interval '16 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r1, 'electricity', 50, true, 'MES-5a-2 live proof typed estimate') RETURNING id INTO e1;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r4, 'electricity', 40, true, 'MES-5a-2 live proof typed estimate') RETURNING id INTO e4;
    PERFORM pg_temp.as_('finv');
    v_p := preview_electricity_allocation(d0, d1, 1337.50, 1200, v_base);
    PERFORM pg_temp.me_();
    SELECT jsonb_object_agg(x ->> 'run_id', jsonb_build_object('basis', x ->> 'basis', 'kwh', (x ->> 'kwh')::numeric)) INTO v_j FROM jsonb_array_elements(v_p -> 'runs') x;
    IF v_j -> r1::text IS DISTINCT FROM '{"basis": "recorded_energy", "kwh": 450}'::jsonb OR v_j -> r2::text IS DISTINCT FROM '{"basis": "recorded_energy", "kwh": 150}'::jsonb
       OR (SELECT count(*) FROM jsonb_object_keys(v_j)) <> 2 THEN
        RAISE EXCEPTION 'MES5A2_LIVE|all runs recorded energy → 600 kWh split 30 : 10 = 450 / 150 by recorded energy; got %', v_j; END IF;
    RAISE NOTICE 'STEP|split-recorded|ops committed % (30 kWh, 60 min) and % (10 kWh, 120 min) on EQ → preview: % 450 kWh recorded_energy, % 150 kWh recorded_energy',
        (SELECT code FROM processing_runs WHERE id = r1), (SELECT code FROM processing_runs WHERE id = r2),
        (SELECT code FROM processing_runs WHERE id = r1), (SELECT code FROM processing_runs WHERE id = r2);

    -- ══════════ ③ 再提交一炉没记电量的 → 整台按运行时长 ══════════
    PERFORM pg_temp.as_('ops');
    r3 := commit_processing_run(d0 + 4, 'MES-5a-2 live proof r3 (no energy)', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 200)), '[]'::jsonb,
                                'weight', NULL, eq, 'zz_probe_mes5a2', ((d0 + 4)::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore',
                                ((d0 + 4)::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    PERFORM pg_temp.as_('finv');
    v_p := preview_electricity_allocation(d0, d1, 1337.50, 1200, v_base);
    PERFORM pg_temp.me_();
    SELECT jsonb_object_agg(x ->> 'run_id', jsonb_build_object('basis', x ->> 'basis', 'kwh', (x ->> 'kwh')::numeric)) INTO v_j FROM jsonb_array_elements(v_p -> 'runs') x;
    IF v_j -> r1::text IS DISTINCT FROM '{"basis": "run_time", "kwh": 150}'::jsonb OR v_j -> r2::text IS DISTINCT FROM '{"basis": "run_time", "kwh": 300}'::jsonb
       OR v_j -> r3::text IS DISTINCT FROM '{"basis": "run_time", "kwh": 150}'::jsonb OR (SELECT count(*) FROM jsonb_object_keys(v_j)) <> 3 THEN
        RAISE EXCEPTION 'MES5A2_LIVE|one run without energy → the whole machine by run time 60 : 120 : 60 = 150 / 300 / 150; got %', v_j; END IF;
    IF (v_p ->> 'metered_kwh')::numeric IS DISTINCT FROM 630 OR (v_p ->> 'shared_pool_kwh')::numeric IS DISTINCT FROM 30
       OR (v_p ->> 'unmetered_kwh')::numeric IS DISTINCT FROM 570 OR (v_p ->> 'allocated_kwh')::numeric IS DISTINCT FROM 600 THEN
        RAISE EXCEPTION 'MES5A2_LIVE|metered 630 (EQ 600 + pool 30), unmetered 570, allocated 600; got %', v_p; END IF;
    IF (SELECT string_agg(x ->> 'id', ',') FROM jsonb_array_elements(v_p -> 'estimates') x) IS DISTINCT FROM e1::text THEN
        RAISE EXCEPTION 'MES5A2_LIVE|only the estimate on a covered run (r1) is to be relieved; got %', v_p -> 'estimates'; END IF;
    RAISE NOTICE 'STEP|split-run-time|ops committed % with no energy (60 min) → preview: every EQ run by run_time 150 / 300 / 150 kWh; metered 630 (EQ 600 + pool 30), unmetered 570; to runs % · to 6200 %; estimate to relieve: % on % only',
        (SELECT code FROM processing_runs WHERE id = r3), v_p ->> 'allocated_amount', v_p ->> 'overhead_amount', (SELECT amount_base FROM processing_cost_entries WHERE id = e1),
        (SELECT code FROM processing_runs WHERE id = r1);

    -- ══════════ ④ 外币 · 没有 finance.edit ══════════
    PERFORM pg_temp.as_('c_finance');
    v_msg := pg_temp.try_(format($q$SELECT preview_electricity_allocation(%L, %L, 1337.50, 1200, %L)$q$, d0, d1, v_other));
    IF v_msg NOT LIKE format('ELECTRICITY_BILL_CURRENCY_NOT_BASE|%s|%s%%', v_other, v_base) THEN RAISE EXCEPTION 'MES5A2_LIVE|foreign preview: %', v_msg; END IF;
    v_msg := pg_temp.try_(format($q$SELECT post_electricity_allocation(%L, %L, %L, 'ZZ-PROBE-MES5A2-FX', 1337.50, 1200, %L, 'unpaid', NULL, %L)$q$,
                                 d0, d1, d1 + 1, v_other, sup));
    IF v_msg NOT LIKE format('ELECTRICITY_BILL_CURRENCY_NOT_BASE|%s|%s%%', v_other, v_base) THEN RAISE EXCEPTION 'MES5A2_LIVE|foreign post: %', v_msg; END IF;
    PERFORM pg_temp.as_('finv');
    v_msg := pg_temp.try_(format($q$SELECT post_electricity_allocation(%L, %L, %L, 'ZZ-PROBE-MES5A2-NOEDIT', 1337.50, 1200, %L, 'unpaid', NULL, %L)$q$,
                                 d0, d1, d1 + 1, v_base, sup));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.edit%' THEN RAISE EXCEPTION 'MES5A2_LIVE|post without module.finance.edit: %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocations) OR (SELECT count(*) FROM expenses) <> v_exp_before THEN
        RAISE EXCEPTION 'MES5A2_LIVE|a refused post left something behind'; END IF;
    RAISE NOTICE 'STEP|refusals|% bill refused by name (preview and post): ELECTRICITY_BILL_CURRENCY_NOT_BASE|%|% (base read from currencies.is_base); finv (no module.finance.edit) refused: PERMISSION_DENIED|module.finance.edit',
        v_other, v_other, v_base;

    -- ══════════ ④ 过账:预览 = 过账 ══════════
    PERFORM pg_temp.as_('c_cfo');
    SELECT jsonb_agg(s) INTO v_j FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
    PERFORM pg_temp.me_();
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) s WHERE (s ->> 'unexplained_base')::numeric <> 0) THEN RAISE EXCEPTION 'MES5A2_LIVE|recon before post: %', v_j; END IF;
    v_b2200 := pg_temp.bal_('2200'); v_b6200 := pg_temp.bal_('6200'); v_b2000 := pg_temp.bal_('2000'); v_b5110 := pg_temp.bal_('5110');
    PERFORM pg_temp.as_('c_finance');
    v_p := preview_electricity_allocation(d0, d1, 1337.50, 1200, v_base, 'unpaid');
    v_post := post_electricity_allocation(d0, d1, d1 + 1, 'ZZ-PROBE-MES5A2-BILL', 1337.50, 1200, v_base, 'unpaid', NULL, sup, NULL, 'MES-5a-2 live proof');
    PERFORM pg_temp.me_();
    v_alloc := (v_post ->> 'allocation_id')::uuid;
    SELECT * INTO v_a FROM electricity_allocations WHERE id = v_alloc;
    IF v_a.bill_amount <> (v_p ->> 'bill_amount')::numeric OR v_a.allocated_amount <> (v_p ->> 'allocated_amount')::numeric
       OR v_a.overhead_amount <> (v_p ->> 'overhead_amount')::numeric OR v_a.metered_kwh <> (v_p ->> 'metered_kwh')::numeric
       OR v_a.allocated_kwh <> (v_p ->> 'allocated_kwh')::numeric OR v_a.shared_pool_kwh <> (v_p ->> 'shared_pool_kwh')::numeric
       OR v_a.unmetered_kwh <> (v_p ->> 'unmetered_kwh')::numeric OR v_a.relieved_estimate_amount <> (v_p ->> 'relieved_estimate_amount')::numeric
       OR v_a.currency <> v_base THEN RAISE EXCEPTION 'MES5A2_LIVE|posted header differs from the preview: % vs %', to_jsonb(v_a), v_p; END IF;
    IF (SELECT jsonb_object_agg(l.run_id, jsonb_build_object('basis', l.basis, 'kwh', l.kwh, 'amount', l.amount)) FROM electricity_allocation_lines l WHERE l.allocation_id = v_alloc)
       IS DISTINCT FROM (SELECT jsonb_object_agg(x ->> 'run_id', jsonb_build_object('basis', x ->> 'basis', 'kwh', (x ->> 'kwh')::numeric, 'amount', (x ->> 'amount')::numeric))
                           FROM jsonb_array_elements(v_p -> 'runs') x) THEN
        RAISE EXCEPTION 'MES5A2_LIVE|posted lines differ from the preview'; END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_lines WHERE allocation_id = v_alloc AND basis IS NULL)
       OR (SELECT count(*) FROM electricity_allocation_lines WHERE allocation_id = v_alloc) <> 3 THEN RAISE EXCEPTION 'MES5A2_LIVE|three lines, each with its basis'; END IF;
    RAISE NOTICE 'STEP|post|c_finance previewed and posted ZZ-PROBE-MES5A2-BILL (% 1337.50, 1200 kWh, unpaid, probe supplier): posted header and 3 lines identical to the preview; to runs %, to 6200 %',
        v_base, v_a.allocated_amount, v_a.overhead_amount;
    -- 一张费用单
    IF (SELECT count(*) FROM expenses WHERE id = v_a.expense_id) <> 1 OR (SELECT count(*) FROM expenses) <> v_exp_before + 1
       OR (SELECT amount_base FROM expenses WHERE id = v_a.expense_id) <> 1337.50 OR (SELECT currency FROM expenses WHERE id = v_a.expense_id) <> v_base
       OR (SELECT account_code FROM expenses WHERE id = v_a.expense_id) <> fin_cost_account('electricity')
       OR (SELECT supplier_id FROM expenses WHERE id = v_a.expense_id) IS DISTINCT FROM sup THEN
        RAISE EXCEPTION 'MES5A2_LIVE|the bill should be one expense (1337.50 %, %, probe supplier)', v_base, fin_cost_account('electricity'); END IF;
    -- 一炉一条实际电费行,已结在那张分录里
    IF (SELECT count(*) FROM processing_cost_entries c JOIN electricity_allocation_lines l ON l.cost_entry_id = c.id
         WHERE l.allocation_id = v_alloc AND c.cost_type = 'electricity' AND NOT c.is_estimate AND c.deleted_at IS NULL
           AND c.remitted_journal_entry_id = v_a.journal_entry_id AND c.amount_base = l.amount AND c.run_id = l.run_id) <> 3 THEN
        RAISE EXCEPTION 'MES5A2_LIVE|each run should carry one actual electricity line for its share, settled in the allocation''s journal'; END IF;
    -- 那张分录:借 2200 各炉 / 借 6200 余数 / 贷 2000,平
    SELECT jsonb_object_agg(a.code || ':' || CASE WHEN l.debit > 0 THEN 'Dr' ELSE 'Cr' END, l.debit + l.credit) INTO v_j
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_a.journal_entry_id;
    IF v_j IS DISTINCT FROM jsonb_build_object('2200:Dr', v_a.allocated_amount, '6200:Dr', v_a.overhead_amount, '2000:Cr', 1337.50)
       OR (SELECT sum(debit) - sum(credit) FROM journal_lines WHERE entry_id = v_a.journal_entry_id) <> 0 THEN
        RAISE EXCEPTION 'MES5A2_LIVE|journal should be Dr 2200 % / Dr 6200 % / Cr 2000 1337.50; got %', v_a.allocated_amount, v_a.overhead_amount, v_j; END IF;
    RAISE NOTICE 'STEP|ledger|one expense % (1337.50 %, account %); 3 actual electricity lines settled in %; journal %; balanced',
        (SELECT code FROM expenses WHERE id = v_a.expense_id), v_base, fin_cost_account('electricity'),
        (SELECT code FROM journal_entries WHERE id = v_a.journal_entry_id), v_j;
    -- 估计:被覆盖的那条冲掉,没被覆盖的不动
    IF (SELECT relieved_at IS NOT NULL AND deleted_at IS NOT NULL AND relief_expense_id = v_a.expense_id FROM processing_cost_entries WHERE id = e1) IS NOT TRUE
       OR (SELECT relieved_at IS NULL AND deleted_at IS NULL FROM processing_cost_entries WHERE id = e4) IS NOT TRUE THEN
        RAISE EXCEPTION 'MES5A2_LIVE|estimate on r1 relieved, on r4 (unmetered machine) untouched'; END IF;
    -- 总账四个科目的移动(估计的计提在基线之前就记了):2200 = 借 分给各炉(账单分录)− 贷 分给各炉(实际电费行的计提)+ 借 50(估计冲抵)= +50;
    --   5110 = 借 分给各炉(计提)− 贷 50(冲抵);6200 = 余数;2000 = −账单
    IF pg_temp.bal_('2200') - v_b2200 <> 50 OR pg_temp.bal_('5110') - v_b5110 <> v_a.allocated_amount - 50
       OR pg_temp.bal_('6200') - v_b6200 <> v_a.overhead_amount OR pg_temp.bal_('2000') - v_b2000 <> -1337.50 THEN
        RAISE EXCEPTION 'MES5A2_LIVE|ledger moves 2200 % (want 50) · 5110 % (want %) · 6200 % (want %) · 2000 % (want −1337.50)',
            pg_temp.bal_('2200') - v_b2200, pg_temp.bal_('5110') - v_b5110, v_a.allocated_amount - 50, pg_temp.bal_('6200') - v_b6200, v_a.overhead_amount,
            pg_temp.bal_('2000') - v_b2000; END IF;
    RAISE NOTICE 'STEP|estimates|typed estimate % on % relieved (soft-deleted, relief → %), estimate % on % (unmetered machine) untouched; ledger moves 2200 % · 5110 % · 6200 % (unmetered 570 kWh + pool 30 kWh stay in overhead) · 2000 %',
        (SELECT amount_base FROM processing_cost_entries WHERE id = e1), (SELECT code FROM processing_runs WHERE id = r1), (SELECT code FROM expenses WHERE id = v_a.expense_id),
        (SELECT amount_base FROM processing_cost_entries WHERE id = e4), (SELECT code FROM processing_runs WHERE id = r4),
        pg_temp.bal_('2200') - v_b2200, pg_temp.bal_('5110') - v_b5110, pg_temp.bal_('6200') - v_b6200, pg_temp.bal_('2000') - v_b2000;
    -- AP 清单 = 总账
    PERFORM pg_temp.as_('c_cfo');
    SELECT jsonb_agg(jsonb_build_object('side', s ->> 'side', 'list', s ->> 'list_base', 'ledger', s ->> 'ledger_base', 'unexplained', s ->> 'unexplained_base'))
      INTO v_j FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
    PERFORM pg_temp.me_();
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) s WHERE (s ->> 'unexplained')::numeric <> 0) THEN RAISE EXCEPTION 'MES5A2_LIVE|recon after post: %', v_j; END IF;
    RAISE NOTICE 'STEP|recon|after the post (c_cfo session): %', v_j;
    -- 一炉的电量:自己记的优先;分到的另列
    PERFORM pg_temp.as_('dev');
    SELECT jsonb_object_agg(e.run_id, jsonb_build_object('energy', e.energy_kwh, 'source', e.energy_source, 'allocated', e.allocated_kwh, 'basis', e.allocation_basis))
      INTO v_j FROM processing_run_energy e WHERE e.run_id IN (r1, r3);
    -- 遮住:没有价格码的读者,金额空、kWh 照见
    SELECT jsonb_build_object('lines', jsonb_agg(jsonb_build_object('kwh', kwh, 'amount', amount)),
                              'bill', (SELECT bill_amount FROM electricity_allocations_masked WHERE id = v_alloc),
                              'bill_kwh', (SELECT bill_kwh FROM electricity_allocations_masked WHERE id = v_alloc))
      INTO v_p FROM electricity_allocation_lines_masked WHERE allocation_id = v_alloc;
    PERFORM pg_temp.me_();
    IF (v_j -> r1::text ->> 'energy')::numeric IS DISTINCT FROM 30 OR v_j -> r1::text ->> 'source' IS DISTINCT FROM 'recorded'
       OR (v_j -> r1::text ->> 'allocated')::numeric IS DISTINCT FROM 150
       OR (v_j -> r3::text ->> 'energy')::numeric IS DISTINCT FROM 150 OR v_j -> r3::text ->> 'source' IS DISTINCT FROM 'allocated' THEN
        RAISE EXCEPTION 'MES5A2_LIVE|run energy: own value where recorded, else the allocated share; got %', v_j; END IF;
    IF jsonb_array_length(v_p -> 'lines') <> 3 OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_p -> 'lines') x WHERE x ->> 'amount' IS NOT NULL OR x ->> 'kwh' IS NULL)
       OR v_p ->> 'bill' IS NOT NULL OR (v_p ->> 'bill_kwh')::numeric IS DISTINCT FROM 1200 THEN
        RAISE EXCEPTION 'MES5A2_LIVE|masking for a reader without data.view_prices: %', v_p; END IF;
    RAISE NOTICE 'STEP|run-energy|dev reads %: own 30 kWh (source recorded; the bill''s share 150 kWh shown apart) and %: 150 kWh (source allocated, run_time)',
        (SELECT code FROM processing_runs WHERE id = r1), (SELECT code FROM processing_runs WHERE id = r3);
    RAISE NOTICE 'STEP|mask|dev (no data.view_prices) reads the allocation: 3 lines, every amount NULL, kWh visible; bill amount NULL, bill 1200 kWh visible';

    -- ══════════ ⑤ 逐角色读数表(七个真角色的码)══════════
    FOR r IN SELECT w, (SELECT ro.code FROM roles ro WHERE ro.code = substr(w, 3)) AS role FROM unnest(ARRAY['c_admin','c_finance','c_warehouse','c_cto','c_cco','c_cfo','c_gm']) w LOOP
        PERFORM pg_temp.as_(r.w);
        INSERT INTO mes5a2_roles VALUES (r.w, r.role,
            (SELECT array_agg(c ORDER BY c) FROM unnest(current_user_permissions()) c) IS NOT DISTINCT FROM
              (SELECT array_agg(rp.permission_code ORDER BY rp.permission_code) FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = r.role),
            has_permission('module.processing.view'),
            (SELECT count(*) FROM meter_readings_current WHERE device_id = m1),
            has_permission('action.manage_devices'), has_permission('action.confirm_capture'),
            has_permission('module.processing.view'),
            (SELECT energy_kwh::text || ' (' || energy_source || ')' FROM processing_run_energy WHERE run_id = r3),
            (SELECT allocation_basis FROM processing_run_energy WHERE run_id = r3),
            COALESCE((SELECT amount::text FROM electricity_allocation_lines_masked WHERE run_id = r3), CASE WHEN EXISTS (SELECT 1 FROM electricity_allocation_lines_masked WHERE run_id = r3) THEN 'masked' ELSE 'no row' END),
            has_permission('module.finance.view'),
            (SELECT count(*) FROM electricity_allocations_masked WHERE id = v_alloc),
            COALESCE((SELECT bill_amount::text FROM electricity_allocations_masked WHERE id = v_alloc), CASE WHEN EXISTS (SELECT 1 FROM electricity_allocations_masked WHERE id = v_alloc) THEN 'masked' ELSE 'no row' END),
            (SELECT bill_kwh::text FROM electricity_allocations_masked WHERE id = v_alloc),
            (SELECT count(*) FROM electricity_allocation_lines_masked WHERE allocation_id = v_alloc),
            has_permission('module.finance.edit'),
            (SELECT count(*) FROM pending_values WHERE value_code = 'V25'),
            CASE WHEN has_permission('module.finance.view') THEN
                (SELECT string_agg((s ->> 'side') || ' ' || COALESCE(s ->> 'unexplained_base', 'restricted'), ' · ') FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s)
                 ELSE 'no module.finance.view' END);
        PERFORM pg_temp.me_();
    END LOOP;
    IF EXISTS (SELECT 1 FROM mes5a2_roles WHERE NOT codes_match) THEN RAISE EXCEPTION 'MES5A2_LIVE|a role clone does not hold exactly its real role''s codes'; END IF;

    -- 在册的东西逐字没变(只比进来之前就在的行)
    IF md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x WHERE x.id NOT IN (r1, r2, r3, r4)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_cost_entries x WHERE x.run_id NOT IN (r1, r2, r3, r4)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.id <> v_a.expense_id),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < (SELECT min(created_at) FROM processing_runs WHERE id IN (r1, r2, r3, r4))),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM devices x WHERE x.id NOT IN (m1, m2)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text)) FROM inbound_batch_safety_states x WHERE x.inbound_batch_id <> b),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text)) FROM output_batch_safety_states x))) IS DISTINCT FROM v_fp_before THEN
        RAISE EXCEPTION 'MES5A2_LIVE|a pre-existing run, cost line, expense, journal, payment, device or safety state changed inside the transaction'; END IF;
    IF (SELECT count(*) FROM notifications) <> v_notif THEN RAISE EXCEPTION 'MES5A2_LIVE|a notification was written'; END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) IS DISTINCT FROM v_pending THEN
        RAISE EXCEPTION 'MES5A2_LIVE|the pending documents changed inside the transaction'; END IF;
    RAISE NOTICE 'STEP|untouched|pre-existing runs, cost lines, expenses, journals, payments, devices and safety states identical inside the transaction; notifications % (unchanged); pending documents unchanged (%)', v_notif, v_pending;
    RAISE NOTICE 'STEP|done|all steps as expected — rolling back';
END
$live$;

SELECT 'ROLE', role, device_page, meter_rows, set_meter, record_reading, run_page, COALESCE(run_energy, '-'), COALESCE(run_basis, '-'), run_line_amount,
       alloc_page, alloc_rows, alloc_bill_amount, COALESCE(alloc_kwh, '-'), alloc_lines, post_bill, v25_listed, recon
  FROM mes5a2_roles ORDER BY array_position(ARRAY['c_admin','c_finance','c_warehouse','c_cto','c_cco','c_cfo','c_gm'], who);
ROLLBACK;
SELECT 'AFTER|probe suppliers/materials/assets/operation types', (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES5A2%') || ' / '
       || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES5A2%') || ' / ' || (SELECT count(*) FROM fixed_assets WHERE code LIKE 'ZZ-PROBE-MES5A2%')
       || ' / ' || (SELECT count(*) FROM operation_types WHERE code = 'zz_probe_mes5a2');
SELECT 'AFTER|meters/readings/allocations/lines', (SELECT count(*) FROM devices WHERE kind = 'meter') || ' / ' || (SELECT count(*) FROM meter_readings)
       || ' / ' || (SELECT count(*) FROM electricity_allocations) || ' / ' || (SELECT count(*) FROM electricity_allocation_lines);
SELECT 'AFTER|V25 rule / require_calibrated_since', COALESCE((SELECT shared_pool_rule FROM electricity_settings), 'NULL') || ' / '
       || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');
SELECT 'AFTER|pending documents', (SELECT count(*) FROM approval_pending_documents());
