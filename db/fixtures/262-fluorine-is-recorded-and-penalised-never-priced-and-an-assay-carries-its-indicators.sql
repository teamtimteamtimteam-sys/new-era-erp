-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 262 —— 氟与氯记得下、罚得到,从不计价;一份化验带得下它的指标
--   (MES-6a-2,2026-10-10;MES-0 Q69;MES-6a Step 0 Q3 · Q4 · Q26–Q32 · Q38–Q45,Tim 照推荐裁定)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   ROLE   substances 上每一行都有 role(NOT NULL、没有默认值、只认三个值);既有七个是 payable_metal;f / cl 是 penalty_element
--          (Fluorine / 氟 / F · 8,Chlorine / 氯 / Cl · 9,启用);不说 role 的插入按 not_null 拒
--   PAY    一个惩罚元素在【每一条定价的路】上以员工身份按名拒 SUBSTANCE_NOT_PAYABLE:行情(upsert_metal_prices)· 计价器
--          (calculate_metal_price)· 新公式与改公式的申请(提交时的试跑)· 合同计价条款 · 合同精炼费;一个可计价的金属在同几条路上照常
--   PEN    f 与 cl 点得进合同的惩罚条款;一个可计价的金属(cu)与一个 other 按名拒 SUBSTANCE_NOT_PENALTY_ELEMENT
--   SETTLE 一份卖方化验上有 f 与 cl:结算算得出(计价那一圈只有 ni,不要 f 的计价条款、不收 f 的精炼费);惩罚按 f 收,金额逐分手算;
--          与同一份没有 f 的化验相比,金属价值逐分相同
--   QUOTE  一批产出带着 f:销售报价(现价预设与公式两种)算得出,而且与没有 f 的孪生批逐分相同;报价的明细里没有 f
--   APPLY  按条款计价:一份带 f 的进料化验应用得了(含量把 f 照抄进批次),提的定价申请单价与不带 f 的孪生批相同;试算同价;
--          按已承诺条款计价(committed_terms_price)对一批含 f 的含量同价
--   RECOV  一炉进出都含 f:回收率只有 ni 一行,没有 f
--   COST   按金属价值分摊:f 不进 skipped_metals,总金属价值与没有 f 时相同
--   PPM    以 % 存、原样存:0.0050 存进去读出来还是 0.0050(不舍到两位、不改刻度);0.00005 也一样
--   IND    五个指标的定义(只有定义,没有值、没有限);两张化验表单那条路(record_assay_result 的 p_indicators,进料与产出)记得下;
--          值 ≥ 0、没有上限(1e6 也收);负数、不认识的码、同一份里重复按名拒;不给就是零行;读跟着化验的父批次(进料查看码
--          读得到进料那一份、读不到产出那一份;什么码都没有读到 0 行);停用一个指标照旧读得出已记的值
--   LOG    两张新表进变更记录(覆盖零缺口、豁免仍是 8);审计:指标挂在两个批次主语下,指标字典是一本字典主语;
--          一份化验的指标行进变更记录
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的调用真的切成 authenticated + 那个人的 JWT。
-- 【数怎么来的】逐条写在断言旁边。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f262_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人跑一句;返回 'OK' 或错误原文。之后身份回到调用之前的那一个。
CREATE FUNCTION pg_temp.f262_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f262_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN SQLERRM;
END;
$f$;

-- 以某人读一个值(读不到就抛 —— 读的失败不许被读成一个答案)
CREATE FUNCTION pg_temp.f262_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f262_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f262_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx262-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx262-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    IF cardinality(p_codes) > 0 THEN
        INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    END IF;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

DO $$
DECLARE
    u_all uuid; u_fin uuid; u_cco uuid; u_calc uuid; u_rec uuid; u_iv uuid; u_none uuid; u_mat uuid;
    v_base text; v_idx text;
    v_day date := DATE '2026-09-15';    -- 结算那一臂:9 月计价期(LME 日历 + 每个交易日的报价)
    v_qd  date := DATE '2026-08-14';    -- 其余各臂(报价 · 按条款计价 · 分摊)的报价日 —— 与 9 月那一组报价分开,互不覆盖
    v_sup uuid; v_mat uuid; v_mat_out uuid; v_cust uuid; v_formula uuid; v_sformula uuid;
    con uuid; con_np uuid; con2 uuid; so uuid; so_np uuid;
    ob uuid; ob_twin uuid; a_f uuid; a_nof uuid;
    b1 uuid; b2 uuid; b3 uuid; a1 uuid; a2 uuid; v_run uuid; v_rob uuid;
    ia uuid; oa uuid;
    v_j jsonb; v_j2 jsonb; v_msg text; v_n bigint; v_x numeric; v_y numeric; v_t text;
    v_case record;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT default_metal_index INTO v_idx FROM pricing_settings WHERE id;
    u_all  := pg_temp.f262_user('all', (SELECT array_agg(code) FROM permissions));
    u_fin  := pg_temp.f262_user('fin', ARRAY['action.metal_prices', 'module.pricing.view', 'data.view_prices', 'data.view_purchase_prices']);
    u_cco  := pg_temp.f262_user('cco', ARRAY['action.contract_terms', 'module.customers.view', 'module.customers.edit', 'module.suppliers.view',
                                             'module.pricing.view', 'module.pricing.edit', 'data.view_prices', 'data.view_purchase_prices']);
    u_calc := pg_temp.f262_user('calc', ARRAY['module.pricing.view', 'data.view_purchase_prices']);
    u_rec  := pg_temp.f262_user('rec', ARRAY['module.inbound.view', 'module.inbound.edit', 'module.output.view', 'module.output.edit']);
    u_iv   := pg_temp.f262_user('iv', ARRAY['module.inbound.view']);
    u_none := pg_temp.f262_user('none', ARRAY[]::text[]);
    u_mat  := pg_temp.f262_user('mat', ARRAY['module.materials.view', 'module.materials.edit']);

    -- ══════════════ 布景 ══════════════
    PERFORM pg_temp.f262_as(NULL);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ262-S', 'f262 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ262-BM', 'f262 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ262-BMO', 'f262 black mass out', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat_out;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ262-C', 'f262 customer', 'SG', 30) RETURNING id INTO v_cust;
    -- 牌价(两边,报价日与今天 —— 定价申请批准当场过账,按今天的牌价)与行情:报价日 ni 在【房屋默认指数】下 15,000 USD/t
    --   (报价与分摊读它);房屋默认指数声明了的话,【未声明指数】下另放一条 12,000(购方公式读它)。
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD' AND rate_date IN (v_qd, CURRENT_DATE) AND deleted_at IS NULL;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    SELECT 'USD', d, t, r FROM (VALUES (v_qd), (CURRENT_DATE)) AS x(d)
      CROSS JOIN (VALUES ('tt_sell', 1.30), ('tt_buy', 1.28), ('mid', 1.29)) AS y(t, r);
    DELETE FROM metal_prices WHERE metal = 'ni' AND price_date = v_qd;
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source, price_index) VALUES ('ni', v_qd, 15000, 'broker_quote', v_idx);
    IF v_idx IS NOT NULL THEN
        INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source, price_index) VALUES ('ni', v_qd, 12000, 'broker_quote', NULL);
    END IF;

    -- ══════════════ ROLE ══════════════
    RAISE NOTICE 'fixture 262 · ROLE';
    IF (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'substances' AND column_name = 'role') <> 'NO'
       OR (SELECT column_default FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'substances' AND column_name = 'role') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 262 ROLE: substances.role must be NOT NULL with no default (Q26)'; END IF;
    IF EXISTS (SELECT 1 FROM substances WHERE role IS NULL OR role NOT IN ('payable_metal', 'penalty_element', 'other')) THEN
        RAISE EXCEPTION 'FIXTURE 262 ROLE: every substance carries one of the three roles'; END IF;
    SELECT string_agg(code || ':' || role, ',' ORDER BY sort_order) INTO v_t FROM substances WHERE code IN ('ni','co','li','mn','cu','al','fe','f','cl');
    IF v_t IS DISTINCT FROM 'ni:payable_metal,co:payable_metal,li:payable_metal,mn:payable_metal,cu:payable_metal,al:payable_metal,fe:payable_metal,f:penalty_element,cl:penalty_element' THEN
        RAISE EXCEPTION 'FIXTURE 262 ROLE: the seven metals are payable and f / cl are penalty elements, in that order — got %', v_t; END IF;
    SELECT string_agg(concat_ws('|', code, name_en, name_zh, symbol, sort_order, is_active), ';' ORDER BY sort_order) INTO v_t
      FROM substances WHERE code IN ('f', 'cl');
    IF v_t IS DISTINCT FROM 'f|Fluorine|氟|F|8|t;cl|Chlorine|氯|Cl|9|t' THEN
        RAISE EXCEPTION 'FIXTURE 262 ROLE: the two rows as Q31 states them, got %', v_t; END IF;
    -- (以属主插 —— 这两格问的是【列】的规矩,不是写策略)
    v_msg := 'OK';
    BEGIN INSERT INTO substances (code, name_en, name_zh) VALUES ('zz262x', 'x', 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE '%null value in column "role"%' THEN
        RAISE EXCEPTION 'FIXTURE 262 ROLE: a row that does not say its role is refused (no default), got %', v_msg; END IF;
    v_msg := 'OK';
    BEGIN INSERT INTO substances (code, name_en, name_zh, role) VALUES ('zz262x', 'x', 'x', 'payable');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE '%substances_role_check%' THEN
        RAISE EXCEPTION 'FIXTURE 262 ROLE: only the three roles are accepted, got %', v_msg; END IF;

    -- ══════════════ PAY ══════════════
    RAISE NOTICE 'fixture 262 · PAY';
    -- 一张购方公式(只有 ni 可计价),之后的计价器与改公式都拿它
    PERFORM pg_temp.f262_as(u_all);
    v_j := submit_formula_create_request(jsonb_build_object('name', 'f262 purchase', 'direction', 'purchase', 'price_basis', 'spot',
            'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 70))), 'fixture 262');
    v_formula := (v_j ->> 'formula_id')::uuid;
    PERFORM pg_temp.f262_as(NULL);
    IF NOT (SELECT is_active FROM pricing_formulas WHERE id = v_formula) THEN
        RAISE EXCEPTION 'FIXTURE 262 PAY: setup — with approvals off the formula is born active, got inactive'; END IF;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f262 draft for the term paths', DATE '2026-01-01', 'draft') RETURNING id INTO con_np;
    FOR v_case IN SELECT * FROM (VALUES
        ('metal price (upsert_metal_prices)', u_fin,
         format($q$SELECT upsert_metal_prices(%L, '[{"metal": "%s", "price_usd_per_tonne": 5}]'::jsonb, NULL, 'broker_quote')$q$, v_day, '%s')),
        ('calculator (calculate_metal_price)', u_calc,
         format($q$SELECT calculate_metal_price(%L, '[{"metal": "ni", "content_pct": 20}, {"metal": "%s", "content_pct": 0.01}]'::jsonb, 1000, %L)$q$, v_formula, '%s', v_day)),
        ('new formula (submit_formula_create_request)', u_cco,
         $q$SELECT submit_formula_create_request('{"name": "f262 bad", "direction": "purchase", "metals": [{"metal": "%s", "payable_pct": 10}]}'::jsonb, 'x')$q$),
        ('formula change (submit_formula_change_request)', u_cco,
         format($q$SELECT submit_formula_change_request(%L, '{"name": "f262 purchase", "direction": "purchase", "price_basis": "spot", "metals": [{"metal": "ni", "payable_pct": 70}, {"metal": "%s", "payable_pct": 5}]}'::jsonb, 'x')$q$, v_formula, '%s')),
        ('contract pricing term', u_cco,
         format($q$INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (%L, '%s', 'assay_complete', 0, 'LME', 50)$q$, con_np, '%s')),
        ('contract refining charge', u_cco,
         format($q$INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (%L, '%s', 10)$q$, con_np, '%s'))
    ) AS c(path, who, sql) LOOP
        FOREACH v_t IN ARRAY ARRAY['f', 'cl'] LOOP
            v_msg := pg_temp.f262_do(v_case.who, replace(v_case.sql, '%s', v_t));
            IF v_msg IS DISTINCT FROM 'SUBSTANCE_NOT_PAYABLE|' || v_t THEN
                RAISE EXCEPTION 'FIXTURE 262 PAY: % must refuse % by name (SUBSTANCE_NOT_PAYABLE|%), got %', v_case.path, v_t, v_t, v_msg; END IF;
        END LOOP;
        -- 同一条路上,一个可计价的金属照常(不是"这条路全关了")
        v_msg := pg_temp.f262_do(v_case.who, replace(v_case.sql, '%s', CASE WHEN v_case.path LIKE 'formula change%' THEN 'co' ELSE 'cu' END));
        IF v_msg <> 'OK' THEN
            RAISE EXCEPTION 'FIXTURE 262 PAY: % still takes a payable metal, got %', v_case.path, v_msg; END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM metal_prices WHERE metal IN ('f', 'cl')) OR EXISTS (SELECT 1 FROM pricing_formula_metals WHERE metal IN ('f', 'cl'))
       OR EXISTS (SELECT 1 FROM contract_pricing_terms WHERE metal IN ('f', 'cl')) OR EXISTS (SELECT 1 FROM contract_refining_charges WHERE metal IN ('f', 'cl')) THEN
        RAISE EXCEPTION 'FIXTURE 262 PAY: a refusal left a row behind'; END IF;

    -- ══════════════ PEN ══════════════
    RAISE NOTICE 'fixture 262 · PEN';
    FOREACH v_t IN ARRAY ARRAY['f', 'cl'] LOOP
        v_msg := pg_temp.f262_do(u_cco, format($q$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, %L, 0.005, 1000)$q$, con_np, v_t));
        IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 262 PEN: % is accepted as a contract penalty element, got %', v_t, v_msg; END IF;
    END LOOP;
    v_msg := pg_temp.f262_do(u_cco, format($q$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'cu', 0.5, 5)$q$, con_np));
    IF v_msg IS DISTINCT FROM 'SUBSTANCE_NOT_PENALTY_ELEMENT|cu' THEN
        RAISE EXCEPTION 'FIXTURE 262 PEN: a payable metal is refused as a penalty element by name, got %', v_msg; END IF;
    INSERT INTO substances (code, name_en, name_zh, role, sort_order) VALUES ('zz262o', 'f262 other', 'f262 other', 'other', 990);
    v_msg := pg_temp.f262_do(u_cco, format($q$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'zz262o', 0.5, 5)$q$, con_np));
    IF v_msg IS DISTINCT FROM 'SUBSTANCE_NOT_PENALTY_ELEMENT|zz262o' THEN
        RAISE EXCEPTION 'FIXTURE 262 PEN: an "other" substance is refused as a penalty element by name, got %', v_msg; END IF;
    -- 改一行把 cl 换成 cu —— UPDATE OF substance 也判
    v_msg := pg_temp.f262_do(u_cco, format($q$UPDATE contract_penalty_elements SET substance = 'cu' WHERE contract_id = %L AND substance = 'cl'$q$, con_np));
    IF v_msg IS DISTINCT FROM 'SUBSTANCE_NOT_PENALTY_ELEMENT|cu' THEN
        RAISE EXCEPTION 'FIXTURE 262 PEN: changing a penalty element into a payable metal is refused too, got %', v_msg; END IF;

    -- ══════════════ SETTLE ══════════════
    RAISE NOTICE 'fixture 262 · SETTLE';
    -- LME 9 月每个交易日 ni 10,000(结算按计价期均价读 index_period_average)
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', d::date, EXTRACT(ISODOW FROM d) < 6, 'fixture 262'
      FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d
    ON CONFLICT DO NOTHING;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT 'ni', 10000, c.calendar_date, 'published_index', 'LME'
      FROM index_market_calendar c WHERE c.index_code = 'LME' AND c.is_trading_day AND c.calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'
    ON CONFLICT DO NOTHING;
    -- 合同:ni 可付 70 %;干基、我们的化验;精炼费按金属(只有 ni 一行:100 USD / 吨含镍);惩罚按元素(f:阈值 0.005 %,1,000 USD / 结算吨 / 百分点)
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f262 with an F penalty', DATE '2026-01-01', 'active') RETURNING id INTO con;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (con, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis)
    VALUES (con, 'dry', 'ours', false, 'per_metal', 'per_element');
    INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (con, 'ni', 100);
    INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (con, 'f', 0.005, 1000);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES ('ZZ262-SO1', v_cust, DATE '2026-06-10', v_base, 1) RETURNING id INTO so;
    -- 同样的计价条款但"没有约定惩罚、没有精炼费" —— 金属价值的对照
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f262 none agreed', DATE '2026-01-01', 'active') RETURNING id INTO con2;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (con2, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis)
    VALUES (con2, 'dry', 'ours', false, 'none_agreed', 'none_agreed');
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES ('ZZ262-SO2', v_cust, DATE '2026-06-10', v_base, 1) RETURNING id INTO so_np;
    PERFORM pg_temp.f262_as(u_all);
    PERFORM link_document_to_contract('sales_order', so, con);
    PERFORM link_document_to_contract('sales_order', so_np, con2);
    PERFORM pg_temp.f262_as(NULL);
    -- 一批产出 10,000 kg;我们的化验(干基、水分 10 %):ni 20 · f 0.0123 · cl 0.004 —— 在 % 里记(Q29)
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ262-OB1', v_mat_out, 10000, 10000, v_day) RETURNING id INTO ob;
    PERFORM pg_temp.f262_as(u_rec);
    a_f := (record_assay_result(p_assay_date => v_day, p_output_batch_id => ob, p_weight_basis => 'dry', p_moisture_pct => 10, p_result_party => 'ours',
            p_metals => '[{"metal": "ni", "content_pct": 20}, {"metal": "f", "content_pct": 0.0123}, {"metal": "cl", "content_pct": 0.004}]'::jsonb)
            ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f262_as(NULL);
    v_msg := pg_temp.f262_do(u_all, format($q$SELECT sale_settlement_compute(%L, %L, %L)$q$, so, ob, a_f));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 262 SETTLE: a sale assay carrying F and Cl settles (Q28 — no pricing term or refining charge is asked of them), got %', v_msg; END IF;
    v_j := pg_temp.f262_get(u_all, format($q$SELECT sale_settlement_compute(%L, %L, %L)$q$, so, ob, a_f));
    -- 手算:结算重量 = 10,000 × (1 − 10 %) = 9,000 kg(干基合同,化验干基,含量照用)
    --   ni 含 9,000 × 20 % = 1,800 kg;可付 70 % = 1,260 kg;× 10,000 USD/t = 12,600.00
    --   精炼费 1,800 kg ÷ 1,000 × 100 = 180.00
    --   惩罚 f:超出 0.0123 − 0.005 = 0.0073 个百分点;9,000 kg ÷ 1,000 × 0.0073 × 1,000 = 65.70
    --   金额 12,600.00 − 180.00 − 65.70 = 12,354.30
    IF (v_j ->> 'metal_value_usd')::numeric <> 12600.00 OR (v_j ->> 'refining_charge_usd')::numeric <> 180.00
       OR (v_j ->> 'penalty_usd')::numeric <> 65.70 OR (v_j ->> 'amount_usd')::numeric <> 12354.30 THEN
        RAISE EXCEPTION 'FIXTURE 262 SETTLE: hand figures 12600.00 / 180.00 / 65.70 / 12354.30, got % / % / % / %',
            v_j ->> 'metal_value_usd', v_j ->> 'refining_charge_usd', v_j ->> 'penalty_usd', v_j ->> 'amount_usd'; END IF;
    SELECT string_agg(e ->> 'metal', ',' ORDER BY e ->> 'metal') INTO v_t FROM jsonb_array_elements(v_j -> 'breakdown' -> 'metals') e;
    IF v_t IS DISTINCT FROM 'ni' THEN
        RAISE EXCEPTION 'FIXTURE 262 SETTLE: the payable lines are ni only (F and Cl are not priced), got %', v_t; END IF;
    SELECT string_agg(e ->> 'substance', ',') INTO v_t FROM jsonb_array_elements(v_j -> 'breakdown' -> 'penalties') e;
    IF v_t IS DISTINCT FROM 'f' THEN
        RAISE EXCEPTION 'FIXTURE 262 SETTLE: the penalty line is f only (cl has no term in this contract), got %', v_t; END IF;
    -- 对照:同一批、同一份化验,"没有约定惩罚"的合同 —— 金属价值逐分相同,惩罚 0
    v_j2 := pg_temp.f262_get(u_all, format($q$SELECT sale_settlement_compute(%L, %L, %L)$q$, so_np, ob, a_f));
    IF (v_j2 ->> 'metal_value_usd')::numeric <> (v_j ->> 'metal_value_usd')::numeric OR (v_j2 ->> 'penalty_usd')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 262 SETTLE: the metal value is the same without a penalty term, got % vs %', v_j2 ->> 'metal_value_usd', v_j ->> 'metal_value_usd'; END IF;

    -- ══════════════ QUOTE ══════════════
    RAISE NOTICE 'fixture 262 · QUOTE';
    -- 两批同重:一批含量 ni 20 + f 0.0123,孪生批只有 ni 20。现价预设与一张销售公式,两种报价都要逐分相同
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ262-OB2', v_mat_out, 10000, 10000, v_qd) RETURNING id INTO ob_twin;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES
        (ob, 'ni', 20, 'manual'), (ob, 'f', 0.0123, 'manual'), (ob_twin, 'ni', 20, 'manual');
    PERFORM pg_temp.f262_as(u_all);
    v_j := submit_formula_create_request(jsonb_build_object('name', 'f262 sale', 'direction', 'sale', 'price_basis', 'spot',
            'price_index', v_idx, 'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 80))), 'fixture 262');
    v_sformula := (v_j ->> 'formula_id')::uuid;
    PERFORM pg_temp.f262_as(NULL);
    FOREACH v_t IN ARRAY ARRAY['preset', 'formula'] LOOP
        v_msg := pg_temp.f262_do(u_all, format($q$SELECT price_output_sale(%L, %L, %L, 1000, %L)$q$, ob, CASE WHEN v_t = 'formula' THEN v_sformula END, v_base, v_qd));
        IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 262 QUOTE (%): a batch carrying F is quoted (Q28), got %', v_t, v_msg; END IF;
        v_j := pg_temp.f262_get(u_all, format($q$SELECT price_output_sale(%L, %L, %L, 1000, %L)$q$, ob, CASE WHEN v_t = 'formula' THEN v_sformula END, v_base, v_qd));
        v_j2 := pg_temp.f262_get(u_all, format($q$SELECT price_output_sale(%L, %L, %L, 1000, %L)$q$, ob_twin, CASE WHEN v_t = 'formula' THEN v_sformula END, v_base, v_qd));
        IF (v_j ->> 'unit_price_ccy')::numeric IS DISTINCT FROM (v_j2 ->> 'unit_price_ccy')::numeric OR (v_j ->> 'unit_price_ccy')::numeric <= 0 THEN
            RAISE EXCEPTION 'FIXTURE 262 QUOTE (%): the quote with F equals its twin without F, got % vs %', v_t, v_j ->> 'unit_price_ccy', v_j2 ->> 'unit_price_ccy'; END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j -> 'breakdown' -> 'lines') e WHERE e ->> 'metal' IN ('f', 'cl')) THEN
            RAISE EXCEPTION 'FIXTURE 262 QUOTE (%): no F line in the quote breakdown', v_t; END IF;
    END LOOP;
    -- 只记了惩罚元素的一批:照"没有含量"拒(不是一张价钱为 0 的报价)
    DELETE FROM output_batch_metals WHERE output_batch_id = ob_twin;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob_twin, 'f', 0.02, 'manual');
    v_msg := pg_temp.f262_do(u_all, format($q$SELECT price_output_sale(%L, NULL, %L, 1000, %L)$q$, ob_twin, v_base, v_qd));
    IF v_msg NOT LIKE 'NO_METAL_CONTENT|ZZ262-OB2%' THEN
        RAISE EXCEPTION 'FIXTURE 262 QUOTE: a batch with only penalty elements has no payable content to quote, got %', v_msg; END IF;

    -- ══════════════ APPLY ══════════════
    RAISE NOTICE 'fixture 262 · APPLY';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note) VALUES
        ('ZZ262-B1', v_mat, v_sup, 1000, 1000, 'kg', v_qd, 'other', 'fixture 262'),
        ('ZZ262-B2', v_mat, v_sup, 1000, 1000, 'kg', v_qd, 'other', 'fixture 262');
    SELECT id INTO b1 FROM inbound_batches WHERE code = 'ZZ262-B1';
    SELECT id INTO b2 FROM inbound_batches WHERE code = 'ZZ262-B2';
    PERFORM commit_pricing_terms(v_formula, NULL, b1);
    PERFORM commit_pricing_terms(v_formula, NULL, b2);
    PERFORM pg_temp.f262_as(u_rec);
    a1 := (record_assay_result(p_assay_date => v_qd, p_inbound_batch_id => b1, p_weight_basis => 'as_received', p_result_party => 'ours',
           p_metals => '[{"metal": "ni", "content_pct": 30}, {"metal": "f", "content_pct": 0.0123}]'::jsonb) ->> 'assay_result_id')::uuid;
    a2 := (record_assay_result(p_assay_date => v_qd, p_inbound_batch_id => b2, p_weight_basis => 'as_received', p_result_party => 'ours',
           p_metals => '[{"metal": "ni", "content_pct": 30}]'::jsonb) ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f262_as(NULL);
    -- 试算:带 f 的含量清单与不带 f 的同价(试算拒的地方提交也拒 —— 这里两边都不拒)
    v_j  := pg_temp.f262_get(u_all, format($q$SELECT preview_assay_price(%L, '[{"metal": "ni", "content_pct": 30}, {"metal": "f", "content_pct": 0.0123}]'::jsonb, %L)$q$, b1, v_qd));
    v_j2 := pg_temp.f262_get(u_all, format($q$SELECT preview_assay_price(%L, '[{"metal": "ni", "content_pct": 30}]'::jsonb, %L)$q$, b2, v_qd));
    v_x := (v_j -> 'calc' ->> 'unit_price_usd_per_kg')::numeric; v_y := (v_j2 -> 'calc' ->> 'unit_price_usd_per_kg')::numeric;
    -- 手算:1,000 kg × 30 % = 300 kg 含镍;可付 70 % = 210 kg;× 12,000 USD/t(未声明指数那一条)= 2,520.00;单价 2.5200 USD/kg
    --   (房屋默认指数未声明时同一条行情是 15,000:那时 3.1500 —— 断言只比两边相等,外加不为 0)
    IF v_x IS NULL OR v_x <= 0 OR v_x IS DISTINCT FROM v_y THEN
        RAISE EXCEPTION 'FIXTURE 262 APPLY: preview with F equals preview without F, got % vs %', v_x, v_y; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j -> 'calc' -> 'lines') e WHERE e ->> 'metal' = 'f') THEN
        RAISE EXCEPTION 'FIXTURE 262 APPLY: no F line in the price breakdown'; END IF;
    v_msg := pg_temp.f262_do(u_all, format($q$SELECT apply_assay_result(%L)$q$, a1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 262 APPLY: an inbound assay carrying F applies (Q28), got %', v_msg; END IF;
    v_msg := pg_temp.f262_do(u_all, format($q$SELECT apply_assay_result(%L)$q$, a2));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 262 APPLY: setup — the twin applies, got %', v_msg; END IF;
    IF (SELECT unit_price FROM inbound_batches WHERE id = b1) IS DISTINCT FROM (SELECT unit_price FROM inbound_batches WHERE id = b2)
       OR (SELECT unit_price FROM inbound_batches WHERE id = b1) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 262 APPLY: the price from terms is the same with or without F, got % vs %',
            (SELECT unit_price FROM inbound_batches WHERE id = b1), (SELECT unit_price FROM inbound_batches WHERE id = b2); END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_metals WHERE inbound_batch_id = b1 AND metal = 'f' AND content_pct = 0.0123 AND content_source = 'assay') THEN
        RAISE EXCEPTION 'FIXTURE 262 APPLY: applying still lands F in the batch content (it is recorded, just not priced)'; END IF;
    -- (committed_terms_price 是内层 —— 从 authenticated 收回,由按已承诺条款改价那几支在体内调;这里以属主身份直接问它)
    v_j  := committed_terms_price(b1, v_qd);
    v_j2 := committed_terms_price(b2, v_qd);
    IF (v_j ->> 'unit_price_usd_per_kg')::numeric IS DISTINCT FROM (v_j2 ->> 'unit_price_usd_per_kg')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 262 APPLY: committed-terms pricing ignores F in the batch content, got % vs %',
            v_j ->> 'unit_price_usd_per_kg', v_j2 ->> 'unit_price_usd_per_kg'; END IF;

    -- ══════════════ RECOV + COST ══════════════
    RAISE NOTICE 'fixture 262 · RECOV';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ262-B3', v_mat, v_sup, 100, 100, 'kg', v_qd, 'other', 'fixture 262') RETURNING id INTO b3;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (b3, 'ni', 20, 'manual'), (b3, 'f', 0.01, 'manual');
    PERFORM pg_temp.f262_as(u_all);
    PERFORM reprice_inbound_batch(b3, 1, v_base, NULL, 'fixture 262 price');
    PERFORM pg_temp.f262_as(NULL);
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT b3, 'discharged_verified' WHERE EXISTS (SELECT 1 FROM materials m JOIN material_kinds k ON k.code = m.kind_code WHERE m.id = v_mat AND k.has_condition_axes);
    PERFORM pg_temp.f262_as(u_all);
    v_run := commit_processing_run(v_qd, 'fixture 262 run', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b3, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat_out, 'weight_kg', 100)), 'metal_value', NULL, NULL, 'manual_disassembly',
        p_started_at => (v_qd)::timestamptz + interval '9 hours', p_ended_at => (v_qd)::timestamptz + interval '10 hours', p_shift_code => 'day');
    PERFORM pg_temp.f262_as(NULL);
    SELECT output_batch_id INTO v_rob FROM processing_outputs WHERE run_id = v_run;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (v_rob, 'ni', 18, 'manual'), (v_rob, 'f', 0.008, 'manual');
    SELECT string_agg(metal, ',' ORDER BY metal) INTO v_t FROM processing_metal_recovery_all WHERE run_id = v_run;
    IF v_t IS DISTINCT FROM 'ni' THEN
        RAISE EXCEPTION 'FIXTURE 262 RECOV: recovery is computed for payable metals only — ni, not f; got %', v_t; END IF;
    IF (SELECT recovery_pct FROM processing_metal_recovery_all WHERE run_id = v_run AND metal = 'ni') IS DISTINCT FROM 90.00 THEN
        RAISE EXCEPTION 'FIXTURE 262 RECOV: ni recovery 18 / 20 = 90.00 %%, got %', (SELECT recovery_pct FROM processing_metal_recovery_all WHERE run_id = v_run AND metal = 'ni'); END IF;

    RAISE NOTICE 'fixture 262 · COST';
    PERFORM pg_temp.f262_as(u_all);
    PERFORM allocate_processing_costs(v_run, 'metal_value');
    PERFORM pg_temp.f262_as(NULL);
    SELECT allocation_snapshot INTO v_j FROM processing_runs WHERE id = v_run;   -- 分摊把它的快照落在这一炉上
    -- 手算:100 kg × 18 % = 18 kg 含镍 × 15,000 USD/t(房屋默认指数)= 270.00 —— 氟没有行情,因为它【不计价】,不是缺了一条
    IF COALESCE(jsonb_array_length(v_j -> 'skipped_metals'), -1) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 262 COST: F is not a skipped metal (it is not payable, nothing is missing), got %', v_j -> 'skipped_metals'; END IF;
    IF (v_j ->> 'total_output_metal_value_usd')::numeric IS DISTINCT FROM 270.00 THEN
        RAISE EXCEPTION 'FIXTURE 262 COST: the output metal value is ni only, 270.00, got %', v_j ->> 'total_output_metal_value_usd'; END IF;

    -- ══════════════ PPM ══════════════
    RAISE NOTICE 'fixture 262 · PPM';
    -- Q29:以 % 存、以 % 录;ppm 只是屏幕上的另一种写法(1 % = 10,000 ppm),所以存的必须是原样 —— 不舍到两位、不改刻度
    IF (SELECT content_pct::text FROM assay_result_metals WHERE assay_result_id = a_f AND metal = 'f') IS DISTINCT FROM '0.0123' THEN
        RAISE EXCEPTION 'FIXTURE 262 PPM: 0.0123 %% is stored as given, got %', (SELECT content_pct::text FROM assay_result_metals WHERE assay_result_id = a_f AND metal = 'f'); END IF;
    PERFORM pg_temp.f262_as(u_rec);
    ia := (record_assay_result(p_assay_date => v_day, p_inbound_batch_id => b2, p_weight_basis => 'dry', p_result_party => 'counterparty',
           p_metals => '[{"metal": "ni", "content_pct": 30}, {"metal": "f", "content_pct": 0.0050}, {"metal": "cl", "content_pct": 0.00005}]'::jsonb) ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f262_as(NULL);
    SELECT string_agg(metal || '=' || content_pct::text, ',' ORDER BY metal) INTO v_t FROM assay_result_metals WHERE assay_result_id = ia AND metal IN ('f', 'cl');
    IF v_t IS DISTINCT FROM 'cl=0.00005,f=0.0050' THEN
        RAISE EXCEPTION 'FIXTURE 262 PPM: 0.0050 and 0.00005 come back exactly as entered (50 ppm and 0.5 ppm), got %', v_t; END IF;

    -- ══════════════ IND ══════════════
    RAISE NOTICE 'fixture 262 · IND';
    SELECT string_agg(concat_ws('|', code, unit, is_active), ',' ORDER BY sort_order) INTO v_t FROM assay_indicators;
    IF v_t IS DISTINCT FROM 'residual_powder_pct|%|t,foil_purity_pct|%|t,d10_um|µm|t,d50_um|µm|t,d90_um|µm|t' THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: the five definitions (Q4), got %', v_t; END IF;
    IF EXISTS (SELECT 1 FROM assay_result_indicators) THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: definitions only — no value is seeded'; END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN ('assay_indicators', 'assay_result_indicators')
                AND column_name ~ '(min|max|limit|threshold|target)') THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: no limit column on either table (Q3 — limits are V17, MES-6b)'; END IF;
    -- 两张表单那条路:进料与产出各一份,五个指标都记
    PERFORM pg_temp.f262_as(u_rec);
    ia := (record_assay_result(p_assay_date => v_day, p_inbound_batch_id => b2, p_weight_basis => 'dry', p_result_party => 'ours',
           p_metals => '[{"metal": "ni", "content_pct": 29}]'::jsonb,
           p_indicators => '[{"indicator": "residual_powder_pct", "value": 0.85}, {"indicator": "foil_purity_pct", "value": 99.2},
                             {"indicator": "d10_um", "value": 3.1}, {"indicator": "d50_um", "value": 11.4}, {"indicator": "d90_um", "value": 28.75}]'::jsonb)
           ->> 'assay_result_id')::uuid;
    v_j := record_assay_result(p_assay_date => v_day, p_output_batch_id => ob, p_weight_basis => 'dry', p_moisture_pct => 2, p_result_party => 'ours',
           p_metals => '[{"metal": "ni", "content_pct": 19.5}]'::jsonb,
           p_indicators => '[{"indicator": "residual_powder_pct", "value": 0}, {"indicator": "d50_um", "value": 1000000}]'::jsonb);
    oa := (v_j ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f262_as(NULL);
    IF (v_j ->> 'indicator_count')::int <> 2 THEN RAISE EXCEPTION 'FIXTURE 262 IND: the function reports how many indicators it recorded, got %', v_j; END IF;
    SELECT string_agg(indicator || '=' || value::text, ',' ORDER BY indicator) INTO v_t FROM assay_result_indicators WHERE assay_result_id = ia;
    IF v_t IS DISTINCT FROM 'd10_um=3.1,d50_um=11.4,d90_um=28.75,foil_purity_pct=99.2,residual_powder_pct=0.85' THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: the inbound form''s five values as entered, got %', v_t; END IF;
    -- 没有上限:0 与 1,000,000 都收(一个限是一条标准,而 Q3 说没有)
    SELECT string_agg(indicator || '=' || value::text, ',' ORDER BY indicator) INTO v_t FROM assay_result_indicators WHERE assay_result_id = oa;
    IF v_t IS DISTINCT FROM 'd50_um=1000000,residual_powder_pct=0' THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: the output form''s values, no limit applied, got %', v_t; END IF;
    -- 不给指标 → 零行(今天的调用照旧)
    IF EXISTS (SELECT 1 FROM assay_result_indicators WHERE assay_result_id = a2) THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: an assay recorded without indicators has none'; END IF;
    FOR v_case IN SELECT * FROM (VALUES
        ('negative', '[{"indicator": "d50_um", "value": -1}]', 'INDICATOR_VALUE_INVALID|d50_um|-1'),
        ('unknown', '[{"indicator": "d99_um", "value": 1}]', 'INDICATOR_INVALID|d99_um'),
        ('duplicate', '[{"indicator": "d50_um", "value": 1}, {"indicator": "d50_um", "value": 2}]', 'DUPLICATE_INDICATOR|d50_um'),
        ('not a number', '[{"indicator": "d50_um", "value": "abc"}]', 'INDICATOR_VALUE_INVALID|d50_um|abc'),
        ('not a list', '{"indicator": "d50_um", "value": 1}', 'INDICATORS_INVALID')
    ) AS c(what, payload, want) LOOP
        v_msg := pg_temp.f262_do(u_rec, format($q$SELECT record_assay_result(p_assay_date => %L, p_inbound_batch_id => %L, p_weight_basis => 'dry',
                    p_result_party => 'ours', p_metals => '[{"metal": "ni", "content_pct": 1}]'::jsonb, p_indicators => %L::jsonb)$q$, v_day, b2, v_case.payload));
        IF v_msg IS DISTINCT FROM v_case.want THEN
            RAISE EXCEPTION 'FIXTURE 262 IND (%): refused by name %, got %', v_case.what, v_case.want, v_msg; END IF;
    END LOOP;
    IF (SELECT count(*) FROM assay_results WHERE inbound_batch_id = b2 AND deleted_at IS NULL) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: a refused recording leaves no assay behind (one transaction)'; END IF;
    -- 没有写策略:一个持编辑码的人直插 → 被 RLS 拒(写只经函数)
    v_msg := pg_temp.f262_do(u_rec, format($q$INSERT INTO assay_result_indicators (assay_result_id, indicator, value) VALUES (%L, 'd10_um', 1)$q$, a2));
    IF v_msg NOT LIKE '%row-level security%' AND v_msg NOT LIKE '%permission denied%' THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: a direct write is refused (writes only through record_assay_result), got %', v_msg; END IF;
    -- 读:跟着化验的父批次
    v_n := (pg_temp.f262_get(u_iv, format($q$SELECT to_jsonb(count(*)) FROM assay_result_indicators WHERE assay_result_id IN (%L, %L)$q$, ia, oa)))::text::bigint;
    IF v_n <> 5 THEN RAISE EXCEPTION 'FIXTURE 262 IND: an inbound-view reader reads the five inbound values and none of the output ones, got %', v_n; END IF;
    v_n := (pg_temp.f262_get(u_none, format($q$SELECT to_jsonb(count(*)) FROM assay_result_indicators WHERE assay_result_id IN (%L, %L)$q$, ia, oa)))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 262 IND: a reader without a batch view code reads none, got %', v_n; END IF;
    v_n := (pg_temp.f262_get(u_none, $q$SELECT to_jsonb(count(*)) FROM assay_indicators$q$))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 262 IND: the definitions are not open to someone with no reading code, got %', v_n; END IF;
    v_n := (pg_temp.f262_get(u_iv, $q$SELECT to_jsonb(count(*)) FROM assay_indicators$q$))::text::bigint;
    IF v_n <> 5 THEN RAISE EXCEPTION 'FIXTURE 262 IND: an assay reader reads the five definitions, got %', v_n; END IF;
    -- 字典:物料编辑码的人停用一个(D5),已记的值照旧读得出;不持码的人改不动(按名拒,不是一次成功的空操作)
    v_msg := pg_temp.f262_do(u_rec, $q$UPDATE assay_indicators SET is_active = false WHERE code = 'd10_um'$q$);
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.materials.edit' THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: changing a definition needs module.materials.edit, refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f262_do(u_mat, $q$UPDATE assay_indicators SET is_active = false WHERE code = 'd10_um'$q$);
    IF v_msg <> 'OK' OR (SELECT is_active FROM assay_indicators WHERE code = 'd10_um') THEN
        RAISE EXCEPTION 'FIXTURE 262 IND: a materials editor deactivates an indicator, got %', v_msg; END IF;
    v_n := (pg_temp.f262_get(u_iv, format($q$SELECT to_jsonb(count(*)) FROM assay_result_indicators WHERE assay_result_id = %L AND indicator = 'd10_um'$q$, ia)))::text::bigint;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 262 IND: a deactivated indicator''s recorded value still reads (D5)'; END IF;

    -- ══════════════ LOG ══════════════
    RAISE NOTICE 'fixture 262 · LOG';
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 262 LOG: change-log coverage %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zzz_change_log' AND tgrelid = 'public.assay_indicators'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zzz_change_log' AND tgrelid = 'public.assay_result_indicators'::regclass) THEN
        RAISE EXCEPTION 'FIXTURE 262 LOG: both new tables are bound'; END IF;
    IF (SELECT count(*) FROM change_log WHERE table_name = 'assay_result_indicators' AND op = 'INSERT' AND (row_key ->> 'assay_result_id')::uuid = ia) <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 262 LOG: the five indicator rows of one assay are in the change log'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'assay_indicators' AND op = 'UPDATE' AND row_key ->> 'code' = 'd10_um') THEN
        RAISE EXCEPTION 'FIXTURE 262 LOG: deactivating a definition is in the change log'; END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subject_members() WHERE subject = 'inbound_batch' AND table_name = 'assay_result_indicators' AND parent_table = 'assay_results')
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() WHERE subject = 'output_batch' AND table_name = 'assay_result_indicators' AND parent_table = 'assay_results')
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() WHERE subject = 'dictionary_assay_indicators' AND root_table = 'assay_indicators') THEN
        RAISE EXCEPTION 'FIXTURE 262 LOG: indicators sit on both batch trails and the definitions are a dictionary subject'; END IF;

    RAISE NOTICE 'FIXTURE 262 全部通过: ROLE · PAY · PEN · SETTLE · QUOTE · APPLY · RECOV · COST · PPM · IND · LOG';
END
$$;
ROLLBACK;
