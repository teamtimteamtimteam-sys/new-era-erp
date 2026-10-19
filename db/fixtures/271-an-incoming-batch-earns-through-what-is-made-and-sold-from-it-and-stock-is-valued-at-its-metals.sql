-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 271 —— 一批进料的毛利来自用它做出来、卖出去的每一样(按投入质量分),没卖的按成本在库;还在库的料按可计价金属的最新价估值
--   (MES-8b-1,2026-10-17;MES-0 Q80 · Q81;MES-8 Step 0 Q10 · Q11 · Q12 · Q13,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   GATE     两支函数的门都是 data.view_prices AND (module.finance.view OR module.processing.view)(AGENTS.md 常设决定 2):
--            缺价格码 → PERMISSION_DENIED|data.view_prices;有价格码而两个模块码都没有 → PERMISSION_DENIED|module.finance.view · module.processing.view;
--            财务 + 价格、加工 + 价格都放行(OR 就是全部要点);不存在的批 → INBOUND_BATCH_NOT_FOUND
--   PATH     两段加工(进料 A 600 + 进料 B 200 → 产出 O1 500 · O2 300;O1 400 → 产出 O3 380):A 在 O1 / O2 的份额 0.75,在 O3 的份额 0.75;
--            每一个产出批一行,份额、已售、收入、成本、毛利、在库与在库成本逐行精确(手算见臂里)
--   MARGIN   毛利 = Σ 份额 × (收入 − 单位成本 × 已售) = 112.50 + 225.00 = 337.50;收入 637.50;已售成本 300.00
--   UNSOLD   没卖的按成本在库:O1 75 × 1.2 + O2 150 × 1.0 + O3 135 × 1.5 + A 自己的 400 × 1 = 842.50;不算进毛利
--   REVENUE  收入只取 sales_records(与 batch_margin 同一句):一条卖方结算(sales_settlements,没过账)一分钱都不改毛利与收入
--   NOCOMP   路径上任一条腿没价 → 「not computable」:一个产出批没有单位成本(output_no_unit_cost)、一个成本不完整(output_cost_incomplete)、
--            进料批自己没有落地成本(inbound_unpriced)—— 毛利、收入、在库成本都是 NULL,永远不是 0;原因逐条点名
--   NOSALE   一样都没卖出去:margin_state = nothing_sold,毛利 NULL(不是 0);在库成本照算
--   EXPO     敞口:只算可计价金属;Ni 在 A(400 kg × 10%)与 O3(180 kg × 20%)= 76 kg × 15,000 = 1,140.00 美元,价的日子是那一条价的日子;
--            明天那一条价不算("今天或之前");Co 一条价都没有 → no_price、不估值、金属吨数照列;Mn 同一天两条价(两个指数)→ price_ambiguous;
--            惩罚元素 f 的含量不进来;价比含量旧 → price_older_than_content 计数;B 一种可计价金属的含量都没有 → not measured(列 kg,不估值);
--            单位不是 kg 的批另列;备件不进来;合计只加估了值的金属、complete = false
--   KIND     ★ MES-8b-2 F18(Tim 裁定 MES8B1-EXPOSURE-SKIPS-UNKINDED-STOCK):物料【种类没说】的在库批 —— 进料 250 kg(带 Ni 10% 的含量)、
--            产出 40 kg、一批 7 pcs —— 列进 kind_not_stated(代码与 kg,不是 kg 的照列数量与单位),【不估值】(Ni 的吨数与值不变),
--            不进 not measured,合计标不完整、kind_not_stated_kg = 290;种类【说了】而不可投料的备件照旧哪儿都不出现。
--            种类为空的物料在重建库里只能这样造:去掉 materials_kind_stated、插、再以 NOT VALID 加回 —— 与线上那 7 行的来历同一个形状
--            (约束之前就在),整段随本 fixture 的事务回滚。
--   LOG      本刀的新表都进变更记录(三张,豁免仍 8);两支函数不写任何东西
--
-- 自带数据(README 第 2 条);以 postgres 直写布景(收货与产出的流水由触发器写,消耗与销售的流水在这里写);读者那几臂切成 authenticated + JWT。
-- 全部判定写成 IF (…) IS NOT FALSE —— 一个 NULL 也是红。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f271_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f271_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f271_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f271_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f271_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f271_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx271-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx271-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f271_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF (p_got IS NULL OR p_got NOT LIKE p_like) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 一批进料(直写):带安全状态;p_price 不为空就按它定价(落地单价 = p_price)
CREATE FUNCTION pg_temp.f271_ib(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_price numeric, p_unit text DEFAULT 'kg') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, p_unit, CURRENT_DATE - 30, 'other', 'fixture 271 自带数据') RETURNING id INTO v;
    IF (SELECT k.has_condition_axes FROM materials mm JOIN material_kinds k ON k.code = mm.kind_code WHERE mm.id = p_mat) THEN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, 'discharged_verified');
    END IF;
    IF p_price IS NOT NULL THEN
        PERFORM reprice_inbound_batch(v, p_price, v_ccy, NULL, 'f271');
    END IF;
    RETURN v;
END;
$f$;

-- 一炉(直写):表头、投料腿与它们的消耗流水
CREATE FUNCTION pg_temp.f271_run(p_code text, p_d date, p_in numeric, p_out numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    INSERT INTO processing_runs (code, status, allocation_basis, operation_type_code, process_date, total_input, total_output, started_at, ended_at, shift_code)
    VALUES (p_code, 'committed', 'weight', 'manual_disassembly', p_d, p_in, p_out, p_d::timestamptz + interval '9 hours',
            p_d::timestamptz + interval '11 hours', 'day') RETURNING id INTO v;
    RETURN v;
END;
$f$;
CREATE FUNCTION pg_temp.f271_leg(p_run uuid, p_kind text, p_b uuid, p_q numeric, p_d date) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_kind = 'inbound' THEN
        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (p_run, p_b, p_q);
        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date) VALUES (p_b, 'processing_consume', -p_q, p_run, p_d);
    ELSE
        INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed) VALUES (p_run, p_b, p_q);
        INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date) VALUES (p_b, 'processing_consume', -p_q, p_run, p_d);
    END IF;
END;
$f$;
-- 一条产出(直写):产出批(它的产出流水由触发器写)与它的单位成本
CREATE FUNCTION pg_temp.f271_out(p_run uuid, p_code text, p_mat uuid, p_q numeric, p_unit_cost numeric, p_incomplete boolean, p_d date) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES (p_code, p_mat, p_q, p_q, p_d) RETURNING id INTO v;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (v, 'discharged_verified');
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, allocated_cost_base, unit_cost_base, cost_incomplete)
    VALUES (p_run, v, p_q, round(p_q * p_unit_cost, 2), p_unit_cost, p_incomplete);
    RETURN v;
END;
$f$;
-- 一笔销售(直写):sales_records 一行与它的销售流水
CREATE FUNCTION pg_temp.f271_sell(p_ob uuid, p_cust uuid, p_q numeric, p_amount numeric, p_d date) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date)
    VALUES (p_ob, p_cust, p_q, round(p_amount / p_q, 6), v_ccy, 1, p_amount, p_d);
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date) VALUES (p_ob, 'sale', -p_q, p_d);
END;
$f$;

DO $$
DECLARE
    u_all uuid; u_fin uuid; u_proc uuid; u_noprice uuid; u_pricesonly uuid;
    D date := CURRENT_DATE - 20;
    m uuid; m_spare uuid; s uuid; cust uuid;
    ia uuid; ib uuid; ic uuid; id_ uuid; ie uuid; i_pcs uuid; i_spare uuid; m_nk uuid; i_nk uuid; o_nk uuid;
    r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid;
    o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid; o6 uuid;
    v_m jsonb; v_m2 jsonb; v_l jsonb; v_e jsonb; v_x jsonb; v_msg text; v_txt text; v_n bigint;
    so uuid; ar uuid;
BEGIN
    PERFORM pg_temp.f271_as(NULL);
    u_all       := pg_temp.f271_user('all', ARRAY(SELECT code FROM permissions));
    u_fin       := pg_temp.f271_user('fin', ARRAY['module.finance.view', 'data.view_prices']);
    u_proc      := pg_temp.f271_user('proc', ARRAY['module.processing.view', 'data.view_prices']);
    u_noprice   := pg_temp.f271_user('noprice', ARRAY['module.finance.view', 'module.processing.view']);
    u_pricesonly := pg_temp.f271_user('pricesonly', ARRAY['data.view_prices', 'module.inventory.view']);
    -- 建数据要一个看得见批次的身份(sales_records 的可售性断言按调用者判)
    PERFORM pg_temp.f271_as(u_all);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX271-M', 'fixture 271 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX271-SPARE', 'fixture 271 spare part', 'spare_part', false, NULL, NULL) RETURNING id INTO m_spare;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FX271-S', 'fixture 271 supplier', 'SG', 'goods_supplier') RETURNING id INTO s;
    INSERT INTO customers (code, legal_name, country) VALUES ('FX271-C', 'fixture 271 customer', 'SG') RETURNING id INTO cust;

    -- ── 两段加工:A 1000(价 1)、B 500(价 1)→ 第一炉 A 600 + B 200 → O1 500(单位成本 1.2)· O2 300(1.0);第二炉 O1 400 → O3 380(1.5)
    ia := pg_temp.f271_ib('FX271-A', m, s, 1000, 1);
    ib := pg_temp.f271_ib('FX271-B', m, s, 500, 1);
    r1 := pg_temp.f271_run('FX271-R1', D, 800, 800);
    PERFORM pg_temp.f271_leg(r1, 'inbound', ia, 600, D);
    PERFORM pg_temp.f271_leg(r1, 'inbound', ib, 200, D);
    o1 := pg_temp.f271_out(r1, 'FX271-O1', m, 500, 1.2, false, D);
    o2 := pg_temp.f271_out(r1, 'FX271-O2', m, 300, 1.0, false, D);
    r2 := pg_temp.f271_run('FX271-R2', D + 2, 400, 380);
    PERFORM pg_temp.f271_leg(r2, 'output', o1, 400, D + 2);
    o3 := pg_temp.f271_out(r2, 'FX271-O3', m, 380, 1.5, false, D + 2);
    -- 销售:O2 卖 100 收 250;O3 卖 200 收 600
    PERFORM pg_temp.f271_sell(o2, cust, 100, 250, D + 5);
    PERFORM pg_temp.f271_sell(o3, cust, 200, 600, D + 6);

    -- ── 没价的三条路:C → O4 没有单位成本(卖了);D → O5 成本不完整(卖了);E 自己没定价 → O6(有成本,卖了)
    ic := pg_temp.f271_ib('FX271-C', m, s, 100, 1);
    r3 := pg_temp.f271_run('FX271-R3', D, 100, 90);
    PERFORM pg_temp.f271_leg(r3, 'inbound', ic, 100, D);
    o4 := pg_temp.f271_out(r3, 'FX271-O4', m, 90, NULL, false, D);
    PERFORM pg_temp.f271_sell(o4, cust, 10, 50, D + 5);
    id_ := pg_temp.f271_ib('FX271-D', m, s, 100, 1);
    r4 := pg_temp.f271_run('FX271-R4', D, 100, 90);
    PERFORM pg_temp.f271_leg(r4, 'inbound', id_, 100, D);
    o5 := pg_temp.f271_out(r4, 'FX271-O5', m, 90, 2, true, D);
    PERFORM pg_temp.f271_sell(o5, cust, 10, 50, D + 5);
    ie := pg_temp.f271_ib('FX271-E', m, s, 100, NULL);
    r5 := pg_temp.f271_run('FX271-R5', D, 50, 40);
    PERFORM pg_temp.f271_leg(r5, 'inbound', ie, 50, D);
    o6 := pg_temp.f271_out(r5, 'FX271-O6', m, 40, 2, false, D);
    PERFORM pg_temp.f271_sell(o6, cust, 10, 50, D + 5);

    -- ══════════════ GATE ══════════════
    RAISE NOTICE 'fixture 271 · GATE';
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_noprice, format($q$SELECT inbound_batch_margin(%L)$q$, ia)), 'PERMISSION_DENIED|data.view_prices');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_pricesonly, format($q$SELECT inbound_batch_margin(%L)$q$, ia)), 'PERMISSION_DENIED|module.finance.view · module.processing.view');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_noprice, $q$SELECT inventory_metal_exposure()$q$), 'PERMISSION_DENIED|data.view_prices');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_pricesonly, $q$SELECT inventory_metal_exposure()$q$), 'PERMISSION_DENIED|module.finance.view · module.processing.view');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, ia)), 'OK');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_proc, format($q$SELECT inbound_batch_margin(%L)$q$, ia)), 'OK');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_fin, $q$SELECT inventory_metal_exposure()$q$), 'OK');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_proc, $q$SELECT inventory_metal_exposure()$q$), 'OK');
    PERFORM pg_temp.f271_expect('GATE', pg_temp.f271_do(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, gen_random_uuid())), 'INBOUND_BATCH_NOT_FOUND|%');

    -- ══════════════ PATH ══════════════
    RAISE NOTICE 'fixture 271 · PATH';
    v_m := pg_temp.f271_get(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, ia));
    IF (jsonb_array_length(v_m -> 'lines') <> 3) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 PATH: A reaches three output batches (O1, O2 in stage 1, O3 in stage 2), got %', v_m -> 'lines'; END IF;
    -- 每一行:份额 · 已售 · 收入 · 成本 · 毛利 · 在库 · 在库成本(手算:A 在第一炉 600 / 800 = 0.75;第二炉全是 O1,0.75 × 400 / 400 = 0.75)
    SELECT string_agg(format('%s:%s:%s:%s:%s:%s:%s:%s', l ->> 'batch_code', l ->> 'share', l ->> 'qty_sold', l ->> 'revenue_base', l ->> 'cost_base',
                             l ->> 'margin_base', l ->> 'on_hand', l ->> 'on_hand_at_cost_base'), ' | ' ORDER BY l ->> 'batch_code') INTO v_txt
      FROM jsonb_array_elements(v_m -> 'lines') l;
    IF (v_txt <> 'FX271-O1:0.750000:0.000:0.00:0.00:0.00:75.000:90.00 | FX271-O2:0.750000:75.000:187.50:75.00:112.50:150.000:150.00 | FX271-O3:0.750000:150.000:450.00:225.00:225.00:135.000:202.50') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 PATH: each output''s share, sold, revenue, cost, margin, on hand and on hand at cost, got %', v_txt; END IF;
    -- B 在第一炉的份额 0.25:它也到得了第二炉(O3),份额 0.25
    v_m2 := pg_temp.f271_get(u_proc, format($q$SELECT inbound_batch_margin(%L)$q$, ib));
    IF ((SELECT string_agg((l ->> 'batch_code') || ':' || (l ->> 'share'), ',' ORDER BY l ->> 'batch_code') FROM jsonb_array_elements(v_m2 -> 'lines') l)
        <> 'FX271-O1:0.250000,FX271-O2:0.250000,FX271-O3:0.250000') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 PATH: B''s shares are the mass consumed (200 / 800), carried into stage 2, got %', v_m2 -> 'lines'; END IF;
    -- 两条源头的毛利加起来正好是两个产出批自己的毛利(O2 150、O3 300)—— 按质量的归属不多也不少
    IF ((v_m ->> 'margin_base')::numeric + (v_m2 ->> 'margin_base')::numeric <> (250 - 100 * 1.0) + (600 - 200 * 1.5)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 PATH: A''s and B''s margins add up to the outputs'' own margins (450), got % + %', v_m ->> 'margin_base', v_m2 ->> 'margin_base'; END IF;

    -- ══════════════ MARGIN ══════════════
    RAISE NOTICE 'fixture 271 · MARGIN';
    IF (v_m ->> 'margin_state' <> 'computed' OR (v_m ->> 'computable')::boolean IS NOT TRUE OR (v_m ->> 'margin_base')::numeric <> 337.50
        OR (v_m ->> 'revenue_base')::numeric <> 637.50 OR (v_m ->> 'cost_of_sold_base')::numeric <> 300.00 OR (v_m ->> 'qty_sold')::numeric <> 225
        OR jsonb_array_length(v_m -> 'reasons') <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 MARGIN: margin 112.50 + 225.00 = 337.50, revenue 637.50, cost of what was sold 300.00, got %', v_m - 'lines'; END IF;

    -- ══════════════ UNSOLD ══════════════
    RAISE NOTICE 'fixture 271 · UNSOLD';
    IF ((v_m ->> 'on_hand_own')::numeric <> 400 OR (v_m ->> 'on_hand_downstream')::numeric <> 360
        OR (v_m ->> 'on_hand_at_cost_base')::numeric <> 842.50) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 UNSOLD: on hand at cost 90 + 150 + 202.50 + A''s own 400 × 1 = 842.50 (not in the margin), got %', v_m - 'lines'; END IF;

    -- ══════════════ REVENUE ══════════════
    RAISE NOTICE 'fixture 271 · REVENUE';
    -- 一条卖方结算(没过账 —— 今天没有一条结算会过账):毛利与收入一分不动
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, status)
    VALUES ('FX271-SO', cust, D, (SELECT code FROM currencies WHERE is_base), 1, 'confirmed') RETURNING id INTO so;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, result_party)
    VALUES ('FX271-AS', o3, D + 4, true, 'dry', 'ours') RETURNING id INTO ar;
    INSERT INTO sales_settlements (sales_order_id, output_batch_id, assay_result_id, settling_party_used, weight_basis_used, gross_weight_kg,
                                   settlement_weight_kg, metal_value_usd, refining_charge_usd, penalty_usd, amount_usd, breakdown, terms_snapshot)
    VALUES (so, o3, ar, 'ours', 'dry', 200, 200, 99999, 0, 0, 99999, '{}'::jsonb, '{}'::jsonb);
    v_x := pg_temp.f271_get(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, ia));
    IF ((v_x -> 'margin_base') <> (v_m -> 'margin_base') OR (v_x -> 'revenue_base') <> (v_m -> 'revenue_base') OR v_x ->> 'revenue_source' <> 'sales_records') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 REVENUE: an unposted settlement changes neither revenue nor margin (sales_records only), got %', v_x - 'lines'; END IF;

    -- ══════════════ NOCOMP ══════════════
    RAISE NOTICE 'fixture 271 · NOCOMP';
    v_x := pg_temp.f271_get(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, ic));
    IF (v_x ->> 'margin_state' <> 'not_computable' OR (v_x ->> 'computable')::boolean IS NOT FALSE OR jsonb_typeof(v_x -> 'margin_base') <> 'null'
        OR jsonb_typeof(v_x -> 'revenue_base') <> 'null' OR jsonb_typeof(v_x -> 'on_hand_at_cost_base') <> 'null'
        OR (v_x -> 'reasons') <> '[{"code": "output_no_unit_cost", "batch_code": "FX271-O4"}]'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 NOCOMP: an output with no unit cost → not computable (NULL, never 0), the leg named, got %', v_x - 'lines'; END IF;
    v_x := pg_temp.f271_get(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, id_));
    IF (v_x ->> 'margin_state' <> 'not_computable' OR jsonb_typeof(v_x -> 'margin_base') <> 'null'
        OR (v_x -> 'reasons') <> '[{"code": "output_cost_incomplete", "batch_code": "FX271-O5"}]'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 NOCOMP: an output whose cost is incomplete → not computable, got %', v_x - 'lines'; END IF;
    v_x := pg_temp.f271_get(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, ie));
    IF (v_x ->> 'margin_state' <> 'not_computable' OR jsonb_typeof(v_x -> 'margin_base') <> 'null' OR jsonb_typeof(v_x -> 'on_hand_at_cost_base') <> 'null'
        OR (v_x -> 'reasons') <> '[{"code": "inbound_unpriced", "batch_code": "FX271-E"}]'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 NOCOMP: the inbound batch itself unpriced → not computable, got %', v_x - 'lines'; END IF;

    -- ══════════════ NOSALE ══════════════
    RAISE NOTICE 'fixture 271 · NOSALE';
    PERFORM pg_temp.f271_as(u_all);
    i_spare := pg_temp.f271_ib('FX271-F', m, s, 70, 2);     -- (借 i_spare 装一下,下面 EXPO 再用它装备件批)
    v_x := pg_temp.f271_get(u_fin, format($q$SELECT inbound_batch_margin(%L)$q$, i_spare));
    IF (v_x ->> 'margin_state' <> 'nothing_sold' OR jsonb_typeof(v_x -> 'margin_base') <> 'null' OR (v_x ->> 'on_hand_at_cost_base')::numeric <> 140
        OR jsonb_array_length(v_x -> 'lines') <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 NOSALE: nothing sold → nothing_sold, margin NULL (not 0), its own stock at cost 70 × 2 = 140, got %', v_x; END IF;

    -- ══════════════ EXPO ══════════════
    RAISE NOTICE 'fixture 271 · EXPO';
    -- 含量:A Ni 10% · Co 5% · F 3%(惩罚元素);O3 Ni 20%;B 一种都没有。单位不是 kg 的一批;一个备件批
    PERFORM pg_temp.f271_as(u_all);
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (ia, 'ni', 10, 'manual'), (ia, 'co', 5, 'manual'), (ia, 'f', 3, 'manual');
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (o3, 'ni', 20, 'manual');
    i_pcs := pg_temp.f271_ib('FX271-PCS', m, s, 12, 1, 'pcs');
    i_spare := pg_temp.f271_ib('FX271-SP', m_spare, s, 5, 1);
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (i_spare, 'ni', 50, 'manual');
    -- 价:Ni 15,000 在三天前、16,000 在明天(不算);Co 一条都没有;Mn 同一天两条(两个指数);Li 有价、没有一批有含量
    UPDATE metal_prices SET deleted_at = now() WHERE deleted_at IS NULL;
    INSERT INTO metal_price_indices (code, name_en, name_zh, quote_currency) VALUES ('FX271-IDX', 'fixture 271 index', 'f', NULL)
        ON CONFLICT DO NOTHING;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source) VALUES
        ('ni', 15000, CURRENT_DATE - 3, 'broker_quote'), ('ni', 16000, CURRENT_DATE + 1, 'broker_quote'),
        ('mn', 2000, CURRENT_DATE - 1, 'broker_quote'), ('li', 9000, CURRENT_DATE - 2, 'broker_quote');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index) VALUES ('mn', 2100, CURRENT_DATE - 1, 'broker_quote', 'FX271-IDX');
    v_e := pg_temp.f271_get(u_proc, $q$SELECT inventory_metal_exposure()$q$);
    SELECT x INTO v_l FROM jsonb_array_elements(v_e -> 'metals') x WHERE x ->> 'metal' = 'ni';
    IF (v_l ->> 'state' <> 'priced' OR (v_l ->> 'price_usd_per_tonne')::numeric <> 15000 OR (v_l ->> 'price_date')::date <> CURRENT_DATE - 3
        OR (v_l ->> 'metal_kg')::numeric <> 76 OR (v_l ->> 'value_usd')::numeric <> 1140.00 OR (v_l ->> 'batches')::int <> 2
        OR (v_l ->> 'price_older_than_content')::int <> 2) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: Ni = (400 × 10%% + 180 × 20%%) = 76 kg × 15,000 / t = 1,140.00 at the price of 3 days ago (not tomorrow''s), price older than both contents; the spare part not counted, got %', v_l - 'batch_lines'; END IF;
    SELECT x INTO v_l FROM jsonb_array_elements(v_e -> 'metals') x WHERE x ->> 'metal' = 'co';
    IF (v_l ->> 'state' <> 'no_price' OR jsonb_typeof(v_l -> 'value_usd') <> 'null' OR (v_l ->> 'metal_kg')::numeric <> 20) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: Co has no price → no price, not valued, its 20 kg still listed, got %', v_l - 'batch_lines'; END IF;
    SELECT x INTO v_l FROM jsonb_array_elements(v_e -> 'metals') x WHERE x ->> 'metal' = 'mn';
    IF (v_l ->> 'state' <> 'price_ambiguous' OR (v_l ->> 'prices_on_that_date')::int <> 2 OR jsonb_typeof(v_l -> 'price_usd_per_tonne') <> 'null') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: two prices on the latest date → price ambiguous, nothing picked, got %', v_l - 'batch_lines'; END IF;
    SELECT x INTO v_l FROM jsonb_array_elements(v_e -> 'metals') x WHERE x ->> 'metal' = 'li';
    IF (v_l ->> 'state' <> 'priced' OR (v_l ->> 'metal_kg')::numeric <> 0 OR (v_l ->> 'value_usd')::numeric <> 0
        OR (v_l ->> 'not_measured_kg')::numeric <= 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: Li priced but measured on no batch → 0 kg, and the measured batches are "not measured" for Li, got %', v_l - 'batch_lines'; END IF;
    IF (EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'metals') x WHERE x ->> 'metal' IN ('f', 'cl'))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: penalty elements are not payable metals and never appear'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'not_measured') x WHERE x ->> 'code' = 'FX271-B' AND (x ->> 'kg')::numeric = 300)
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'not_measured') x WHERE x ->> 'code' IN ('FX271-A', 'FX271-SP'))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: B (no content) is "not measured" with its 300 kg; A is measured; the spare part is not stock that carries metal, got %', v_e -> 'not_measured'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'unit_not_kg') x WHERE x ->> 'code' = 'FX271-PCS' AND x ->> 'unit' = 'pcs')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: a batch not in kg is listed apart, not summed, got %', v_e -> 'unit_not_kg'; END IF;
    IF ((v_e ->> 'value_usd_priced')::numeric <> 1140.00 + 0 OR (v_e ->> 'complete')::boolean IS NOT FALSE OR (v_e ->> 'as_of')::date <> (now() AT TIME ZONE 'Asia/Singapore')::date) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: the total adds only valued metals (1,140.00), says it is incomplete, and is as of today (Singapore), got %', v_e - 'metals'; END IF;
    IF (jsonb_array_length(v_e -> 'kind_not_stated') <> 0 OR (v_e ->> 'kind_not_stated_kg')::numeric <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 EXPO: every material here has a kind → nothing under "kind not stated", got %', v_e -> 'kind_not_stated'; END IF;

    -- ══════════════ KIND(MES-8b-2 F18)══════════════
    RAISE NOTICE 'fixture 271 · KIND';
    PERFORM pg_temp.f271_as(u_all);
    -- 一种【种类没说】的物料:线上 7 行就是这样来的(约束加上之前就在)。去掉约束、插、再以 NOT VALID 加回 —— 随事务回滚。
    ALTER TABLE materials DROP CONSTRAINT materials_kind_stated;
    INSERT INTO materials (code, name) VALUES ('FX271-NK', 'fixture 271 material with no kind') RETURNING id INTO m_nk;
    ALTER TABLE materials ADD CONSTRAINT materials_kind_stated CHECK (kind_code IS NOT NULL AND may_be_processed IS NOT NULL) NOT VALID;
    IF ((SELECT kind_code FROM materials WHERE id = m_nk) IS NOT NULL
        OR (SELECT convalidated FROM pg_constraint WHERE conrelid = 'public.materials'::regclass AND conname = 'materials_kind_stated')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND 前置失败: the material must have no kind and the constraint must be back, NOT VALID'; END IF;
    i_nk := pg_temp.f271_ib('FX271-NK-IN', m_nk, s, 250, 1);
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (i_nk, 'ni', 10, 'manual');
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES ('FX271-NK-OUT', m_nk, 40, 40, D) RETURNING id INTO o_nk;
    PERFORM pg_temp.f271_ib('FX271-NK-PCS', m_nk, s, 7, NULL, 'pcs');
    v_e := pg_temp.f271_get(u_proc, $q$SELECT inventory_metal_exposure()$q$);
    IF (jsonb_array_length(v_e -> 'kind_not_stated') <> 3
        OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'kind_not_stated') x WHERE x ->> 'code' = 'FX271-NK-IN' AND x ->> 'kind' = 'inbound' AND (x ->> 'kg')::numeric = 250)
        OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'kind_not_stated') x WHERE x ->> 'code' = 'FX271-NK-OUT' AND x ->> 'kind' = 'output' AND (x ->> 'kg')::numeric = 40)
        OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'kind_not_stated') x WHERE x ->> 'code' = 'FX271-NK-PCS' AND jsonb_typeof(x -> 'kg') = 'null'
                                                                                  AND (x ->> 'qty')::numeric = 7 AND x ->> 'unit' = 'pcs')
        OR (v_e ->> 'kind_not_stated_kg')::numeric <> 290) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND: a material with no kind → its stock is listed under "kind not stated" with code and kg (250 + 40 = 290; the pcs batch with its quantity and unit), got %', v_e -> 'kind_not_stated'; END IF;
    SELECT x INTO v_l FROM jsonb_array_elements(v_e -> 'metals') x WHERE x ->> 'metal' = 'ni';
    IF ((v_l ->> 'metal_kg')::numeric <> 76 OR (v_l ->> 'value_usd')::numeric <> 1140.00 OR (v_l ->> 'batches')::int <> 2
        OR (v_e ->> 'value_usd_priced')::numeric <> 1140.00) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND: the kindless batch is NOT valued — its Ni content adds nothing (Ni stays 76 kg / 1,140.00, total 1,140.00), got %', v_l - 'batch_lines'; END IF;
    IF (EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'not_measured') x WHERE x ->> 'code' LIKE 'FX271-NK%')
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'unit_not_kg') x WHERE x ->> 'code' LIKE 'FX271-NK%')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND: a kindless batch is listed once, under "kind not stated" — not as "not measured" or "not in kg", got %', v_e - 'metals'; END IF;
    IF (EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'kind_not_stated') x WHERE x ->> 'code' = 'FX271-SP')
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'not_measured') x WHERE x ->> 'code' = 'FX271-SP')
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_e -> 'metals') l, jsonb_array_elements(l -> 'batch_lines') b WHERE b ->> 'code' = 'FX271-SP')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND: a recorded kind that may not be processed (the spare part) keeps today''s treatment — absent from every list'; END IF;
    -- 「不完整」要两边都量:先把本 fixture 别的料都改成【说了、不可投料】的种类(于是它们整批离开这一节,没价 / 没计量 / 不是 kg 那几样
    --   原因一起消失),只剩种类没说的那几批 —— complete 必须为 false;再给它们也定一个种类 —— complete 必须回到 true。
    --   (只看第一半是空的:本 fixture 里 complete 本来就因为别的原因是 false —— 一格注入把这一项从合计里摘掉,第一版照样绿。)
    UPDATE materials SET kind_code = 'consumable', may_be_processed = false, form_code = NULL, source_code = NULL WHERE id = m;
    v_e := pg_temp.f271_get(u_proc, $q$SELECT inventory_metal_exposure()$q$);
    IF (jsonb_array_length(v_e -> 'not_measured') <> 0 OR jsonb_array_length(v_e -> 'unit_not_kg') <> 0 OR jsonb_array_length(v_e -> 'kind_not_stated') <> 3) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND 前置失败: with the other material made non-processable only the kindless batches remain, got %', v_e - 'metals'; END IF;
    IF ((v_e ->> 'complete')::boolean IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND: the section is incomplete while any kindless batch exists (and for no other reason here), got %', v_e ->> 'complete'; END IF;
    UPDATE materials SET kind_code = 'consumable', may_be_processed = false WHERE id = m_nk;
    v_e := pg_temp.f271_get(u_proc, $q$SELECT inventory_metal_exposure()$q$);
    IF (jsonb_array_length(v_e -> 'kind_not_stated') <> 0 OR (v_e ->> 'complete')::boolean IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 KIND: once the kind is stated (here: not processable) the batches leave the list and the section is complete again, got %', v_e - 'metals'; END IF;

    -- ══════════════ LOG ══════════════
    RAISE NOTICE 'fixture 271 · LOG';
    v_x := change_log_coverage_gaps();
    IF (jsonb_array_length(v_x -> 'gaps') <> 0 OR (v_x ->> 'excluded')::int <> 8) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 LOG: change-log coverage (gaps 0, exclusions 8): %', v_x; END IF;
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['compliance_settings', 'compliance_packs', 'compliance_pack_issues']) t
                WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgname = 'zzz_change_log' AND g.tgrelid = ('public.' || t)::regclass))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 LOG: every new table is change-logged'; END IF;
    IF ((SELECT provolatile FROM pg_proc WHERE oid = 'public.inbound_batch_margin(uuid)'::regprocedure) <> 's'
        OR (SELECT provolatile FROM pg_proc WHERE oid = 'public.inventory_metal_exposure()'::regprocedure) <> 's') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 LOG: both readers are STABLE (they write nothing)'; END IF;

    RAISE NOTICE 'FIXTURE 271 全部通过: GATE · PATH · MARGIN · UNSOLD · REVENUE · NOCOMP · NOSALE · EXPO · KIND · LOG';
END
$$;

ROLLBACK;
