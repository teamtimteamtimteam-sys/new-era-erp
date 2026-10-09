-- db/scripts/2026-10-09-mes5b2-live-proof.sql
-- MES-5b-2 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关。
--   由 db/scripts/2026-10-09-mes5b2-live-proof.mjs 驱动:它先用 mintThrowaway 造一次性账号(前缀 mes5b2probe),
--   再以 psql 跑本文件,把那些邮箱经 -v 传进来;跑完按 ephemeral 计划收走账号、授权、一次性角色。
--   【每一个动作都以一次性账号跑】(七个真账号一个都不用):
--     dev = module.processing.view + action.manage_devices              —— 设电表、挂机器
--     cap = module.processing.view + action.confirm_capture             —— 记读数
--     ops = module.processing.view/edit + action.processing_commit/aftercare + module.inbound.view —— 提交炉次、手敲估计;
--           它也是【加工编辑者】:直连改结算戳,必须被拒
--     fin = module.finance.view/edit + data.view_prices + data.view_purchase_prices —— 过账、撤回、冲抵、冲销、记费用单
--     c_<角色> = 七个真角色【此刻的码】的一次性克隆(cloneOf)—— 逐角色读数表;对账在 c_cfo 的会话里读
--   【布景】(以属主插,都是我自己的行):ZZ-PROBE-MES5B2-* 供应商 / 物料 / 批次 / 两台机器 / 一道探针工序(深度放电配置的逐行克隆)。
--     "经付款结过"那一笔的付款也是布景:以属主调 record_payment_internal(批准过的付款申请执行时走的那一支)—— 证明要的是之后那一次【冲销被拒】。
--   在册的单据、费用单、付款、炉次、设备、分录一张都不碰、不决定、不改、不冲。
--   ① 未付的电费单 A(600 / 400 kWh)过账,覆盖 r1 · r2 上手敲的估计 → 撤回(带理由)→ 估计回来、重新计提已过、一行撤回记录、
--      四个科目回到过账之前 → 同一段时间再过一张改正过的 A'(640)。
--   ② 已付的电费单 B(本位币银行)过账 → 撤回 → 银行借回。
--   ③ 月结冲抵 R(r4 的估计)→ 冲销 R → 估计回到未结 → 再冲抵一次。
--   ④ 一张经付款结过的费用单 → 冲销被拒 EXPENSE_HAS_SETTLEMENT;A' 经付款付过 → 撤回被拒。
--   ⑤ ops(加工编辑者)直连改一个汇出戳 / 冲抵戳 → COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY。
--   每一步之后:AP 清单 = 总账,两边 unexplained 0.00(c_cfo 的会话)。
--   ⑥ 逐角色读数表:电费单页(进得去吗、撤回钮按得下去吗、哪些金额被遮)与费用单页(进得去吗、冲销钮按得下去吗)。
-- 打印的每一行都是 STEP|… 或 ROLE|… ;任何一处与预期不符就 RAISE,整笔回滚。
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SELECT set_config('mes5b2.dev', :'dev', true), set_config('mes5b2.cap', :'cap', true), set_config('mes5b2.ops', :'ops', true),
       set_config('mes5b2.fin', :'fin', true),
       set_config('mes5b2.c_admin', :'c_admin', true), set_config('mes5b2.c_finance', :'c_finance', true),
       set_config('mes5b2.c_warehouse', :'c_warehouse', true), set_config('mes5b2.c_cto', :'c_cto', true),
       set_config('mes5b2.c_cco', :'c_cco', true), set_config('mes5b2.c_cfo', :'c_cfo', true), set_config('mes5b2.c_gm', :'c_gm', true) \g /dev/null

CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid; e text := current_setting('mes5b2.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = e;
    IF v IS NULL OR e NOT LIKE 'mes5b2probe-%@test.local' THEN RAISE EXCEPTION 'MES5B2_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
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
-- AP / AR 清单 = 总账(c_cfo 的会话;那支函数按读者的码过滤)。不为 0 就抛。
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; out text := '';
BEGIN
    PERFORM pg_temp.as_('c_cfo');
    v := list_ledger_reconciliation();
    PERFORM pg_temp.me_();
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES5B2_LIVE|AP/AR list <> ledger after %: % list % ledger % unexplained %', p_step, s ->> 'side', s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base';
        END IF;
        out := out || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RETURN out;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_(), pg_temp.try_(text) TO authenticated;

CREATE TEMP TABLE mes5b2_roles (who text, role text, codes_match boolean,
    alloc_page boolean, alloc_reverse boolean, alloc_bill text, rev_amounts text, rev_counts text,
    exp_page boolean, exp_reverse boolean, relief_count text, recon text) ON COMMIT DROP;
GRANT INSERT ON mes5b2_roles TO authenticated;

DO $live$
DECLARE
    today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    d0 date; d1 date; d2 date; d3 date; dx date;
    v_base text := (SELECT code FROM currencies WHERE is_base);
    v_bank text := (SELECT c FROM unnest(ARRAY['1000', '1010']) c WHERE bank_native_currency(c) = (SELECT code FROM currencies WHERE is_base) LIMIT 1);
    sup uuid; m_mod uuid; b uuid; eq uuid; eq2 uuid; m1 uuid; m2 uuid;
    r1 uuid; r2 uuid; r3 uuid; r4 uuid; e1 uuid; e2 uuid; e3 uuid; e4 uuid;
    a1 uuid; x1 uuid; je1 uuid; a1b uuid; x1b uuid; a2 uuid; x2 uuid; rel uuid; rel2 uuid; xo uuid; pay uuid;
    v_msg text; v_j jsonb; v_n bigint; v_live_before text; v_rec text;
    v_b2200 numeric; v_b6200 numeric; v_b2000 numeric; v_b5110 numeric; v_bbank numeric;
    v_notif bigint := (SELECT count(*) FROM notifications);
    v_pending text := (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    v_fp_before text;
    v_t0 timestamptz := now();
    r record;
BEGIN
    d0 := today - 40; d1 := today - 31; d2 := today - 25; d3 := today - 22; dx := today - 6;
    -- 在册的东西先记一个指纹(只比【进来之前就在】的行;我的行按 created_at >= 事务开始 排除)
    SELECT md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_cost_entries x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payment_allocations x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM devices x)))
      INTO v_fp_before;
    v_rec := pg_temp.agree_('start');
    RAISE NOTICE 'STEP|start|AP/AR before anything (c_cfo): %', v_rec;

    -- ══════════ 布景(以属主插:都是我自己的行)══════════
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES5B2-S', 'MES-5b-2 probe utility and vendor', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES5B2-MOD', 'MES-5b-2 probe modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 chemistry_certainty_code)
    VALUES ('ZZ-PROBE-MES5B2-B', m_mod, sup, 5000, 5000, 'kg', d0 - 10, 'other', 'MES-5b-2 live proof', 'single_known') RETURNING id INTO b;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (b, 'charged_not_discharged');
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ-PROBE-MES5B2-EQ', 'MES-5b-2 probe machine A (metered)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ-PROBE-MES5B2-EQ2', 'MES-5b-2 probe machine B (metered)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq2;
    INSERT INTO operation_types SELECT (jsonb_populate_record(NULL::operation_types, to_jsonb(o)
        || jsonb_build_object('code', 'zz_probe_mes5b2', 'name_en', 'MES-5b-2 probe operation', 'name_zh', 'MES-5b-2 探针工序', 'sort_order', 999))).*
      FROM operation_types o WHERE o.code = 'deep_discharge';
    INSERT INTO operation_type_input_forms SELECT (jsonb_populate_record(NULL::operation_type_input_forms, to_jsonb(x) || '{"operation_type_code":"zz_probe_mes5b2"}'::jsonb)).*
      FROM operation_type_input_forms x WHERE x.operation_type_code = 'deep_discharge';
    INSERT INTO operation_type_output_forms SELECT (jsonb_populate_record(NULL::operation_type_output_forms, to_jsonb(x) || '{"operation_type_code":"zz_probe_mes5b2"}'::jsonb)).*
      FROM operation_type_output_forms x WHERE x.operation_type_code = 'deep_discharge';
    INSERT INTO operation_type_safety_states SELECT (jsonb_populate_record(NULL::operation_type_safety_states, to_jsonb(x) || '{"operation_type_code":"zz_probe_mes5b2"}'::jsonb)).*
      FROM operation_type_safety_states x WHERE x.operation_type_code = 'deep_discharge';
    RAISE NOTICE 'STEP|setup|probe supplier, material, batch ZZ-PROBE-MES5B2-B, machines ZZ-PROBE-MES5B2-EQ / -EQ2, probe operation zz_probe_mes5b2 (clone of deep_discharge); periods % – % and % – %', d0, d1, d2, d3;

    -- ══════════ 电表、读数、炉次、手敲的估计(一次性账号)══════════
    PERFORM pg_temp.as_('dev');
    m1 := save_device(jsonb_build_object('name', 'ZZ-PROBE-MES5B2 meter A', 'kind', 'meter', 'equipment_id', eq));
    m2 := save_device(jsonb_build_object('name', 'ZZ-PROBE-MES5B2 meter B', 'kind', 'meter', 'equipment_id', eq2));
    PERFORM pg_temp.as_('cap');
    PERFORM record_meter_reading(m1, ((d0)::timestamp + interval '1 hour') AT TIME ZONE 'Asia/Singapore', 1000);
    PERFORM record_meter_reading(m1, ((d1)::timestamp + interval '23 hours') AT TIME ZONE 'Asia/Singapore', 1300);
    PERFORM record_meter_reading(m2, ((d2)::timestamp + interval '1 hour') AT TIME ZONE 'Asia/Singapore', 50);
    PERFORM record_meter_reading(m2, ((d3)::timestamp + interval '23 hours') AT TIME ZONE 'Asia/Singapore', 150);
    PERFORM pg_temp.as_('ops');
    r1 := commit_processing_run(d0 + 2, 'MES-5b-2 live proof r1', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq, 'zz_probe_mes5b2', ((d0 + 2)::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore',
                                ((d0 + 2)::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    r2 := commit_processing_run(d0 + 3, 'MES-5b-2 live proof r2', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq, 'zz_probe_mes5b2', ((d0 + 3)::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore',
                                ((d0 + 3)::timestamp + interval '11 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    r3 := commit_processing_run(d2 + 1, 'MES-5b-2 live proof r3', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq2, 'zz_probe_mes5b2', ((d2 + 1)::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore',
                                ((d2 + 1)::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    r4 := commit_processing_run(today - 15, 'MES-5b-2 live proof r4 (month-end relief)', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq, 'zz_probe_mes5b2', ((today - 15)::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore',
                                ((today - 15)::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore', 'day');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r1, 'electricity', 120, true, 'MES-5b-2 live proof typed estimate') RETURNING id INTO e1;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r2, 'electricity', 250, true, 'MES-5b-2 live proof typed estimate') RETURNING id INTO e2;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r3, 'electricity', 90, true, 'MES-5b-2 live proof typed estimate') RETURNING id INTO e3;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r4, 'gas', 80, true, 'MES-5b-2 live proof typed estimate') RETURNING id INTO e4;
    PERFORM pg_temp.me_();
    RAISE NOTICE 'STEP|runs|ops committed % · % (machine A, period 1), % (machine B, period 2), % (no bill); typed estimates 120 / 250 / 90 (electricity) and 80 (gas) entered by ops',
        (SELECT code FROM processing_runs WHERE id = r1), (SELECT code FROM processing_runs WHERE id = r2), (SELECT code FROM processing_runs WHERE id = r3),
        (SELECT code FROM processing_runs WHERE id = r4);

    -- ══════════ ① 未付的电费单 A:过账 → 撤回 → 再过一张改正过的 ══════════
    SELECT string_agg(id::text || ':' || amount_base || ':' || is_estimate, ',' ORDER BY id) INTO v_live_before
      FROM processing_cost_entries WHERE run_id IN (r1, r2) AND deleted_at IS NULL;
    v_b2200 := pg_temp.bal_('2200'); v_b5110 := pg_temp.bal_('5110'); v_b6200 := pg_temp.bal_('6200'); v_b2000 := pg_temp.bal_('2000');
    PERFORM pg_temp.as_('fin');
    v_j := post_electricity_allocation(d0, d1, d1 + 1, 'ZZ-PROBE-MES5B2-A', 600, 400, v_base, 'unpaid', NULL, sup, NULL, 'MES-5b-2 live proof');
    PERFORM pg_temp.me_();
    a1 := (v_j ->> 'allocation_id')::uuid; x1 := (v_j ->> 'expense_id')::uuid;
    SELECT journal_entry_id INTO je1 FROM electricity_allocations WHERE id = a1;
    IF NOT EXISTS (SELECT 1 FROM processing_cost_entries WHERE id IN (e1, e2) AND deleted_at IS NOT NULL AND relief_expense_id = x1 HAVING count(*) = 2) THEN
        RAISE EXCEPTION 'MES5B2_LIVE|bill A should have relieved both typed estimates'; END IF;
    v_rec := pg_temp.agree_('post A');
    RAISE NOTICE 'STEP|post-unpaid|fin posted bill A % (600.00 / 400 kWh, unpaid): r1 150.00 · r2 300.00 · 6200 150.00; estimates 120 + 250 relieved; AP/AR %',
        (SELECT code FROM expenses WHERE id = x1), v_rec;
    PERFORM pg_temp.as_('fin');
    v_msg := pg_temp.try_(format($q$SELECT reverse_expense(%L)$q$, x1));
    v_j := reverse_electricity_allocation(a1, 'MES-5b-2 live proof: the utility re-issued the bill');
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE format('EXPENSE_IS_ELECTRICITY_ALLOCATION|%s|%s%%', (SELECT code FROM expenses WHERE id = x1), a1) THEN
        RAISE EXCEPTION 'MES5B2_LIVE|reverse_expense on the bill''s expense should be refused, naming the allocation: %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM processing_cost_entries WHERE id IN (e1, e2) AND (deleted_at IS NOT NULL OR relieved_at IS NOT NULL OR relief_expense_id IS NOT NULL))
       OR (SELECT count(*) FROM journal_entries je WHERE je.source_type = 'processing_cost' AND je.source_id IN (e1, e2) AND je.memo LIKE 'Cost restored%') <> 2
       OR NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = a1 AND v.actual_line_count = 2 AND v.actual_line_amount = 450
                        AND v.restored_estimate_count = 2 AND v.restored_estimate_amount = 370)
       OR (SELECT status FROM expenses WHERE id = x1) <> 'reversed' OR (SELECT status FROM journal_entries WHERE id = je1) <> 'reversed' THEN
        RAISE EXCEPTION 'MES5B2_LIVE|reversal of A: estimates restored with re-accruals, one reversal record, expense and journal reversed'; END IF;
    IF pg_temp.bal_('2200') <> v_b2200 OR pg_temp.bal_('5110') <> v_b5110 OR pg_temp.bal_('6200') <> v_b6200 OR pg_temp.bal_('2000') <> v_b2000 THEN
        RAISE EXCEPTION 'MES5B2_LIVE|2200 / 5110 / 6200 / 2000 not back to before bill A'; END IF;
    IF (SELECT string_agg(id::text || ':' || amount_base || ':' || is_estimate, ',' ORDER BY id) FROM processing_cost_entries WHERE run_id IN (r1, r2) AND deleted_at IS NULL)
       IS DISTINCT FROM v_live_before THEN RAISE EXCEPTION 'MES5B2_LIVE|runs'' live cost lines not as before bill A'; END IF;
    v_rec := pg_temp.agree_('reverse A');
    RAISE NOTICE 'STEP|reverse-unpaid|fin: reverse_expense on % refused (%); reverse_electricity_allocation → estimates 120 + 250 restored, 2 re-accruals Dr 5110 / Cr 2200 posted, one reversal record (2 lines 450.00, 2 estimates 370.00), expense and journal reversed; 2200 / 5110 / 6200 / 2000 back to before the bill; AP/AR %',
        (SELECT code FROM expenses WHERE id = x1), split_part(v_msg, '|', 1), v_rec;
    PERFORM pg_temp.as_('fin');
    v_j := post_electricity_allocation(d0, d1, d1 + 1, 'ZZ-PROBE-MES5B2-A-CORRECTED', 640, 400, v_base, 'unpaid', NULL, sup, NULL, 'MES-5b-2 live proof (corrected)');
    PERFORM pg_temp.me_();
    a1b := (v_j ->> 'allocation_id')::uuid; x1b := (v_j ->> 'expense_id')::uuid;
    IF (SELECT string_agg(amount::text, ',' ORDER BY amount) FROM electricity_allocation_lines WHERE allocation_id = a1b) IS DISTINCT FROM '160.00,320.00'
       OR NOT EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e1 AND relief_expense_id = x1b AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'MES5B2_LIVE|the corrected bill should post 160 / 320 and relieve the restored estimates again'; END IF;
    v_rec := pg_temp.agree_('repost A');
    RAISE NOTICE 'STEP|repost|fin posted the corrected bill % for the same period (640.00): r1 160.00 · r2 320.00; the restored estimates relieved again; AP/AR %',
        (SELECT code FROM expenses WHERE id = x1b), v_rec;

    -- ══════════ ② 已付的电费单 B:过账 → 撤回,银行借回 ══════════
    v_b2200 := pg_temp.bal_('2200'); v_b5110 := pg_temp.bal_('5110'); v_b6200 := pg_temp.bal_('6200'); v_b2000 := pg_temp.bal_('2000'); v_bbank := pg_temp.bal_(v_bank);
    PERFORM pg_temp.as_('fin');
    v_j := post_electricity_allocation(d2, d3, d3 + 1, 'ZZ-PROBE-MES5B2-B', 300, 200, v_base, 'paid', v_bank, NULL, NULL, 'MES-5b-2 live proof (paid)');
    PERFORM pg_temp.me_();
    a2 := (v_j ->> 'allocation_id')::uuid; x2 := (v_j ->> 'expense_id')::uuid;
    IF pg_temp.bal_(v_bank) - v_bbank <> -300 OR pg_temp.bal_('2000') <> v_b2000 THEN RAISE EXCEPTION 'MES5B2_LIVE|a paid bill should credit the bank, not payables'; END IF;
    v_rec := pg_temp.agree_('post B');
    PERFORM pg_temp.as_('fin');
    v_j := reverse_electricity_allocation(a2, 'MES-5b-2 live proof: posted against the wrong period');
    PERFORM pg_temp.me_();
    IF pg_temp.bal_(v_bank) <> v_bbank OR pg_temp.bal_('2200') <> v_b2200 OR pg_temp.bal_('5110') <> v_b5110 OR pg_temp.bal_('6200') <> v_b6200
       OR pg_temp.bal_('2000') <> v_b2000 OR EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e3 AND (deleted_at IS NOT NULL OR relieved_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'MES5B2_LIVE|reversing paid bill B: bank debited back, four accounts back, estimate restored'; END IF;
    v_rec := pg_temp.agree_('reverse B');
    RAISE NOTICE 'STEP|paid|fin posted paid bill % (300.00 from bank %: Cr bank 300.00) and reversed it: bank debited back, 2200 / 5110 / 6200 / 2000 / % back, estimate 90 restored; AP/AR %',
        (SELECT code FROM expenses WHERE id = x2), v_bank, v_bank, v_rec;

    -- ══════════ ③ 月结冲抵 → 冲销 → 再冲抵 ══════════
    PERFORM pg_temp.as_('fin');
    v_j := relieve_processing_accruals(ARRAY[e4], 100, dx, 'unpaid', NULL, sup, NULL, 'MES-5b-2 live proof relief');
    rel := (v_j ->> 'expense_id')::uuid;
    v_j := reverse_expense(rel, 'MES-5b-2 live proof: relief entered against the wrong invoice');
    PERFORM pg_temp.me_();
    IF (v_j ->> 'restored_estimates')::int <> 1 OR EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e4 AND (relieved_at IS NOT NULL OR relief_expense_id IS NOT NULL)) THEN
        RAISE EXCEPTION 'MES5B2_LIVE|reversing the relief should put its estimate back as unsettled: %', v_j; END IF;
    v_rec := pg_temp.agree_('reverse relief');
    PERFORM pg_temp.as_('fin');
    v_j := relieve_processing_accruals(ARRAY[e4], 95, dx, 'unpaid', NULL, sup, NULL, 'MES-5b-2 live proof relief again');
    rel2 := (v_j ->> 'expense_id')::uuid;
    PERFORM pg_temp.me_();
    IF (SELECT relief_expense_id FROM processing_cost_entries WHERE id = e4) IS DISTINCT FROM rel2 OR (SELECT currency FROM expenses WHERE id = rel2) <> v_base THEN
        RAISE EXCEPTION 'MES5B2_LIVE|the restored estimate should relieve again (in the base currency read from data)'; END IF;
    v_rec := pg_temp.agree_('relieve again');
    RAISE NOTICE 'STEP|relief|fin relieved the 80 estimate (% at 100.00), reversed it (estimate back to unsettled, no extra journal), relieved it again (% at 95.00, currency %); AP/AR %',
        (SELECT code FROM expenses WHERE id = rel), (SELECT code FROM expenses WHERE id = rel2), v_base, v_rec;

    -- ══════════ ④ 经付款结过的:冲销被拒 ══════════
    PERFORM pg_temp.as_('fin');
    -- 线上登记了 GST:一张费用单要一个税码 —— 取零税率的进项码(ZP,fixture 213 的先例),于是这一笔没有税,付 100 就是付清
    v_j := record_expense(p_expense_date := dx, p_account_code := '6400', p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := sup,
                          p_notes := 'MES-5b-2 live proof', p_tax_code := 'ZP');
    PERFORM pg_temp.me_();
    xo := (v_j ->> 'expense_id')::uuid;
    -- 布景:以属主调 record_payment_internal(批准过的付款申请执行时走的那一支)把它付清;A' 也付清
    v_j := record_payment_internal('out', sup, 100, v_base, NULL, NULL, today - 1, 'MES-5b-2 live proof payment',
                                   jsonb_build_array(jsonb_build_object('expense_id', xo, 'amount_doc', 100)));
    pay := (v_j ->> 'payment_id')::uuid;
    PERFORM record_payment_internal('out', sup, 640, v_base, NULL, NULL, today - 1, 'MES-5b-2 live proof payment of the corrected bill',
                                    jsonb_build_array(jsonb_build_object('expense_id', x1b, 'amount_doc', 640)));
    v_rec := pg_temp.agree_('paid');
    PERFORM pg_temp.as_('fin');
    v_msg := pg_temp.try_(format($q$SELECT reverse_expense(%L)$q$, xo));
    v_j := to_jsonb(pg_temp.try_(format($q$SELECT reverse_electricity_allocation(%L, 'already paid')$q$, a1b)));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE format('EXPENSE_HAS_SETTLEMENT|%s|100%%', (SELECT code FROM expenses WHERE id = xo)) THEN
        RAISE EXCEPTION 'MES5B2_LIVE|reversing an expense settled through a payment should be refused by name: %', v_msg; END IF;
    IF v_j #>> '{}' NOT LIKE format('EXPENSE_HAS_SETTLEMENT|%s|640%%', (SELECT code FROM expenses WHERE id = x1b)) THEN
        RAISE EXCEPTION 'MES5B2_LIVE|reversing a bill paid through a payment should be refused by name: %', v_j; END IF;
    v_rec := pg_temp.agree_('settled refused');
    RAISE NOTICE 'STEP|settled|fin: reverse_expense on % (paid 100.00 through %) refused: %; reverse_electricity_allocation on the paid corrected bill refused: %; AP/AR %',
        (SELECT code FROM expenses WHERE id = xo), (SELECT code FROM payments WHERE id = pay), v_msg, v_j #>> '{}', v_rec;

    -- ══════════ ⑤ 加工编辑者直连改结算戳:拒 ══════════
    PERFORM pg_temp.as_('ops');
    v_msg := pg_temp.try_(format($q$UPDATE processing_cost_entries SET remitted_at = NULL, remitted_journal_entry_id = NULL WHERE id = %L$q$,
                                 (SELECT cost_entry_id FROM electricity_allocation_lines WHERE allocation_id = a1b AND run_id = r1)));
    v_j := to_jsonb(pg_temp.try_(format($q$UPDATE processing_cost_entries SET relieved_at = NULL, relief_expense_id = NULL WHERE id = %L$q$, e4)));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|remitted%' OR v_j #>> '{}' NOT LIKE 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|relieved%'
       OR (SELECT remitted_at FROM processing_cost_entries WHERE id = (SELECT cost_entry_id FROM electricity_allocation_lines WHERE allocation_id = a1b AND run_id = r1)) IS NULL THEN
        RAISE EXCEPTION 'MES5B2_LIVE|a processing editor changing a settlement stamp directly should be refused: % / %', v_msg, v_j; END IF;
    RAISE NOTICE 'STEP|guard|ops (module.processing.edit) clearing a remitted stamp directly: %; clearing a relieved stamp directly: %', v_msg, v_j #>> '{}';

    -- ══════════ ⑥ 逐角色读数表 ══════════
    FOR r IN SELECT w, substr(w, 3) AS role FROM unnest(ARRAY['c_admin','c_finance','c_warehouse','c_cto','c_cco','c_cfo','c_gm']) w LOOP
        PERFORM pg_temp.as_(r.w);
        INSERT INTO mes5b2_roles VALUES (r.w, r.role,
            (SELECT array_agg(c ORDER BY c) FROM unnest(current_user_permissions()) c) IS NOT DISTINCT FROM
              (SELECT array_agg(rp.permission_code ORDER BY rp.permission_code) FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = r.role),
            has_permission('module.finance.view'),
            has_permission('module.finance.edit'),
            COALESCE((SELECT bill_amount::text FROM electricity_allocations_masked WHERE id = a1), CASE WHEN EXISTS (SELECT 1 FROM electricity_allocations_masked WHERE id = a1) THEN 'masked' ELSE 'no row' END),
            COALESCE((SELECT bill_amount::text || ' / ' || actual_line_amount::text || ' / ' || restored_estimate_amount::text FROM electricity_allocation_reversals_masked WHERE allocation_id = a1 AND bill_amount IS NOT NULL),
                     CASE WHEN EXISTS (SELECT 1 FROM electricity_allocation_reversals_masked WHERE allocation_id = a1) THEN 'masked' ELSE 'no row' END),
            COALESCE((SELECT actual_line_count::text || ' / ' || restored_estimate_count::text FROM electricity_allocation_reversals_masked WHERE allocation_id = a1), 'no row'),
            has_permission('module.finance.view'),
            has_permission('module.finance.edit'),
            CASE WHEN has_permission('module.finance.view') OR has_permission('module.processing.view')
                 THEN (SELECT count(*)::text FROM processing_cost_entry_lookup WHERE relief_expense_id = rel2 AND deleted_at IS NULL) ELSE 'no row' END,
            CASE WHEN has_permission('module.finance.view') THEN
                (SELECT string_agg((s ->> 'side') || ' ' || COALESCE(s ->> 'unexplained_base', 'restricted'), ' · ') FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s)
                 ELSE 'no module.finance.view' END);
        PERFORM pg_temp.me_();
    END LOOP;
    IF EXISTS (SELECT 1 FROM mes5b2_roles WHERE NOT codes_match) THEN RAISE EXCEPTION 'MES5B2_LIVE|a role clone does not hold exactly its real role''s codes'; END IF;

    -- ══════════ 在册的东西逐字没变(只比进来之前就在的行)══════════
    IF md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x WHERE x.id NOT IN (r1, r2, r3, r4)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_cost_entries x WHERE x.run_id NOT IN (r1, r2, r3, r4)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.entry_id IN (SELECT id FROM journal_entries WHERE created_at < v_t0)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payment_allocations x WHERE x.payment_id IN (SELECT id FROM payments WHERE created_at < v_t0)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM devices x WHERE x.id NOT IN (m1, m2)))) IS DISTINCT FROM v_fp_before THEN
        RAISE EXCEPTION 'MES5B2_LIVE|a pre-existing run, cost line, expense, journal, journal line, payment, allocation or device changed inside the transaction'; END IF;
    IF (SELECT count(*) FROM notifications) <> v_notif THEN RAISE EXCEPTION 'MES5B2_LIVE|a notification was written'; END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) IS DISTINCT FROM v_pending THEN
        RAISE EXCEPTION 'MES5B2_LIVE|the pending documents changed inside the transaction'; END IF;
    RAISE NOTICE 'STEP|untouched|pre-existing runs, cost lines, expenses, journals and their lines, payments and their allocations, devices identical inside the transaction; notifications % (unchanged); pending documents unchanged (%)', v_notif, v_pending;
    RAISE NOTICE 'STEP|done|all steps as expected — rolling back';
END
$live$;

SELECT 'ROLE', role, alloc_page, alloc_reverse, alloc_bill, rev_amounts, rev_counts, exp_page, exp_reverse, relief_count, recon
  FROM mes5b2_roles ORDER BY array_position(ARRAY['c_admin','c_finance','c_warehouse','c_cto','c_cco','c_cfo','c_gm'], who);
ROLLBACK;
SELECT 'AFTER|probe suppliers/materials/batches/assets/operation types', (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES5B2%') || ' / '
       || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES5B2%') || ' / ' || (SELECT count(*) FROM inbound_batches WHERE code LIKE 'ZZ-PROBE-MES5B2%')
       || ' / ' || (SELECT count(*) FROM fixed_assets WHERE code LIKE 'ZZ-PROBE-MES5B2%') || ' / ' || (SELECT count(*) FROM operation_types WHERE code = 'zz_probe_mes5b2');
SELECT 'AFTER|meters/allocations/reversals', (SELECT count(*) FROM devices WHERE kind = 'meter') || ' / ' || (SELECT count(*) FROM electricity_allocations)
       || ' / ' || (SELECT count(*) FROM electricity_allocation_reversals);
SELECT 'AFTER|require_calibrated_since', COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');
SELECT 'AFTER|pending documents', (SELECT count(*) FROM approval_pending_documents());
