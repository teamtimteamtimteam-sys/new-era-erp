-- db/scripts/2026-10-05-u1b-live-proof.sql
-- U1-B · 线上证明(委托书 §3「Live verification · Inside one rolled-back transaction」)—— psql 以 postgres 跑,【一笔事务,ROLLBACK】。
--   以 admin@(321f1819…,真账号;它的 JWT,不登录、不改账号)的身份,在这笔事务里自建、只动【自己的】单据:
--   ① 一张整单发完的销售单 → 加一行(Q14)
--   ② 一台自己的设备上的停机 → 记、更正、作废;删 → 按名拒(Q15)
--   ③ 一张自己的采购单 → 深度放电判断(Q20)→ 带理由关闭 → 带理由重开(Q25)
--   ④ 一张自己的加工单 → 选了机器(Q21)
--   然后读它们的审计记录(record_trail,以 admin@ 的身份),把原始行吐成 JSON(U1B_TRAIL <主语> <json>)——
--   db/scripts/2026-10-05-u1b-render-live-trails.mjs 用应用自己的造句器(lib/trail/render.ts)把它们说成英文,核对措辞。
-- 不碰任何既有单据:每一张都是这笔事务里建的,随 ROLLBACK 消失。
--   ⚠ 照直写出来的一处:①要走到"整单发完",开票与放行在审批开着时要等 CFO —— 这笔事务里先把审批关上(审批开关的上下文,
--     与 fixture 229 同一个写法),发完货再打开,然后才加行;开关的两次改动随 ROLLBACK 一起消失,线上从头到尾是开着的。
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE TEMP TABLE u1b_ids (k text PRIMARY KEY, id uuid);
-- 每一步开始的那一刻(clock_timestamp)—— 应用里每一个动作是它自己的一笔事务,这里全在一笔里,于是审计记录会把它们按 txid
-- 并成【一条】(一次操作一条,change-log §9.4)。渲染脚本按这些时刻把行切回一步一条 —— 正是分开的几次动作会留下的样子。
CREATE TEMP TABLE u1b_marks (n serial, step text, at timestamptz DEFAULT clock_timestamp());
GRANT INSERT, SELECT ON u1b_marks TO authenticated;
GRANT USAGE ON SEQUENCE u1b_marks_n_seq TO authenticated;

DO $$
DECLARE
    u_admin uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';
    v_base text; d date := CURRENT_DATE;
    v_cust uuid; v_mat uuid; v_matB uuid; v_cons uuid; v_sup uuid;
    so uuid; ln uuid; ob uuid; res uuid; v_res jsonb;
    fa uuid; dt uuid; v_msg text;
    po uuid; pol uuid;
    ib uuid; run uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);

    -- 自己的主数据(随 ROLLBACK 消失)
    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZ-U1B-C1', 'U1B proof customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-U1B-M1', 'U1B proof black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-U1B-M2', 'U1B proof output', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_matB;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZ-U1B-CONS', 'U1B proof gloves', 'consumable', false) RETURNING id INTO v_cons;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ-U1B-S', 'U1B proof supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base,
                              useful_life_months, residual_base)
    VALUES ('ZZ-U1B-A1', 'U1B proof feeder', 'equipment', d - 60, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;

    INSERT INTO u1b_marks (step) VALUES ('so-setup');
    -- ── ① 整单发完的销售单 → 加一行 ──
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    so := (create_sales_order(v_cust, d, v_base, 1,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 12, 'unit_price', 10)), NULL, NULL) ->> 'id')::uuid;
    SELECT id INTO ln FROM sales_order_lines WHERE sales_order_id = so;
    PERFORM set_sales_order_status(so, 'confirmed');
    ob := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    -- 线上已经 GST 注册:开票要说税码(标准税率销项 SR)—— 空库里没有这一问,本地那一轮没碰到
    PERFORM create_order_invoice(so, d, NULL, NULL, NULL, ARRAY[ln], 'SR');
    res := (reserve_stock(ln, ob, 12) ->> 'reservation_id')::uuid;
    BEGIN PERFORM submit_shipping_release(so);
    EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'SHIPPING_RELEASE_%' THEN RAISE; END IF; END;
    PERFORM ship_order(so, d, jsonb_build_array(jsonb_build_object('reservation_id', res)));
    IF (SELECT status FROM sales_orders WHERE id = so) <> 'shipped' THEN
        RAISE EXCEPTION 'U1B_LIVE_PROOF|①: the order should be fully shipped, is %', (SELECT status FROM sales_orders WHERE id = so); END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    INSERT INTO u1b_marks (step) VALUES ('so-amend');
    v_res := amend_sales_order(so, 'U1B proof: the customer wants 5 more', NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 5, 'unit_price', 10)));
    IF (SELECT status FROM sales_orders WHERE id = so) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'U1B_LIVE_PROOF|①: adding a line should put the order back to partially_shipped'; END IF;
    RAISE NOTICE 'U1B_LIVE ① shipped order % took a new line → %', (SELECT code FROM sales_orders WHERE id = so), v_res ->> 'status';
    INSERT INTO u1b_ids VALUES ('sales_order', so);

    INSERT INTO u1b_marks (step) VALUES ('dt-record');
    -- ── ② 停机:记(经 RLS)、更正(经 RLS)、作废(函数)、删(拒)──
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
    VALUES (fa, now() - interval '3 hours', now() - interval '1 hour', 'U1B proof: belt snapped') RETURNING id INTO dt;
    INSERT INTO u1b_marks (step) VALUES ('dt-correct');
    UPDATE equipment_downtime SET started_at = now() - interval '4 hours', reason = 'U1B proof: belt snapped on the feeder' WHERE id = dt;
    INSERT INTO u1b_marks (step) VALUES ('dt-void');
    PERFORM void_equipment_downtime(dt, 'U1B proof: entered on the wrong machine');
    BEGIN
        DELETE FROM equipment_downtime WHERE id = dt;
        v_msg := 'deleted';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg NOT LIKE 'DOWNTIME_NEVER_DELETED%' THEN RAISE EXCEPTION 'U1B_LIVE_PROOF|②: delete should be refused, got %', v_msg; END IF;
    IF (SELECT void_reason FROM equipment_downtime WHERE id = dt) IS DISTINCT FROM 'U1B proof: entered on the wrong machine' THEN
        RAISE EXCEPTION 'U1B_LIVE_PROOF|②: the void did not land'; END IF;
    RAISE NOTICE 'U1B_LIVE ② downtime recorded, corrected, voided; delete refused: %', v_msg;
    INSERT INTO u1b_ids VALUES ('fixed_asset', fa), ('equipment', fa);

    INSERT INTO u1b_marks (step) VALUES ('po-create');
    -- ── ③ 采购单:深度放电判断 → 带理由关闭 → 带理由重开 ──
    po := (create_purchase_order(v_sup, d, NULL, v_base, NULL, NULL, NULL, 'U1B proof: deliver to bay 2',
        jsonb_build_array(jsonb_build_object('material_id', v_cons, 'quantity', 5, 'unit', 'box', 'estimated_unit_price', 10,
                                             'tax_code', 'TX')),   -- GST 注册之后采购行要说税码(标准税率进项)
        p_category => 'consumables') ->> 'purchase_order_id')::uuid;
    SELECT id INTO pol FROM purchase_order_lines WHERE purchase_order_id = po;
    INSERT INTO u1b_marks (step) VALUES ('po-judge');
    PERFORM set_po_line_deep_discharge(pol, 'not_assessed');
    INSERT INTO u1b_marks (step) VALUES ('po-close');
    PERFORM close_purchase_order(po, 'U1B proof: supplier cannot deliver the rest');
    IF (SELECT notes FROM purchase_orders WHERE id = po) IS DISTINCT FROM 'U1B proof: deliver to bay 2' THEN
        RAISE EXCEPTION 'U1B_LIVE_PROOF|③: closing rewrote the notes'; END IF;
    INSERT INTO u1b_marks (step) VALUES ('po-reopen');
    PERFORM reopen_purchase_order(po, 'U1B proof: supplier found the stock');
    RAISE NOTICE 'U1B_LIVE ③ % judged not_assessed, closed (%), reopened (%), notes unchanged', (SELECT code FROM purchase_orders WHERE id = po),
        (SELECT amend_reason FROM purchase_order_history WHERE purchase_order_id = po AND change_type = 'closed'),
        (SELECT reopen_reason FROM purchase_orders WHERE id = po);
    INSERT INTO u1b_ids VALUES ('purchase_order', po);

    INSERT INTO u1b_marks (step) VALUES ('run');
    -- ── ④ 加工单选了机器 ──
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ-U1B-IB1', v_mat, v_sup, 100, 100, 'kg', d, 'other', 'U1B proof') RETURNING id INTO ib;
    PERFORM reprice_inbound_batch(ib, 1, v_base, NULL, 'U1B proof price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (ib, 'discharged_verified');
    run := commit_processing_run(d, 'U1B proof run', 10,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 60)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 50)), 'weight',
        NULL, fa, 'manual_disassembly');
    IF (SELECT equipment_id FROM processing_runs WHERE id = run) IS DISTINCT FROM fa THEN
        RAISE EXCEPTION 'U1B_LIVE_PROOF|④: the run did not record its machine'; END IF;
    RAISE NOTICE 'U1B_LIVE ④ run % recorded machine %', (SELECT code FROM processing_runs WHERE id = run), (SELECT code FROM fixed_assets WHERE id = fa);
    INSERT INTO u1b_ids VALUES ('processing_run', run);
END $$;

SELECT 'U1B_MARKS ' || (SELECT jsonb_agg(jsonb_build_object('step', step, 'at', at) ORDER BY n) FROM u1b_marks)::text AS marks;
-- 审计记录:以 admin@ 的身份,一个主语一行 JSON
SELECT set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true) \gset
SELECT 'U1B_TRAIL ' || i.k || ' ' || COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST)
                                                  FROM record_trail(i.k, i.id::text, 50) r)::text, '[]') AS trail
  FROM u1b_ids i WHERE i.k IN ('sales_order', 'equipment', 'purchase_order', 'processing_run')
 ORDER BY i.k;

ROLLBACK;
