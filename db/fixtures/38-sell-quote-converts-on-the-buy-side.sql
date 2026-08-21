-- 38 卖方报价:换算在 tt_buy 那一边;现货是预设不是分支;出处可重导;缺价缺汇点名拒
--
-- 【判别臂是 A:汇率的边】买方报价按 tt_sell 折算(付钱出去),销售收钱进来按
-- tt_buy —— record_output_sale 一直是对的,风险全在报价路径照抄买路径。
-- 在 tt_buy ≠ tt_sell 的日子上,同一金属、同一含量、同一日期的卖方报价与
-- "买方口径算出来的数"必须差出这一个价差;两个数相同 = 卖路径继承了买方的边。
-- 注入方式:把 price_output_sale 里的 v_side 翻成 tt_sell,本臂即红并点名边。
--
-- 【B:现货 = 预设】现货预设与显式的 100% 应付/零处理费/零折扣公式给出同一个数 ——
-- 这正是"预设填参数、走同一台引擎"而不是第四条算术分支的证明。
-- 【C:出处】computed 的价能从出处重导出来;manual 记的是 MANUAL,不从"没挂公式"
-- 推断(FIN-26 在本项目上骗过一位仔细的读者,卖方从第一天起同样处理)。
-- 【D:缺即拒】缺金属行情、缺汇率,各自点名,绝不代入任何数。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_mat uuid; v_cust uuid; v_base text;
    ob uuid; v_formula uuid;
    q jsonb; q2 jsonb;
    v_usd numeric; v_expect numeric; v_wrong numeric;
    v_denied boolean; v_msg text;
    v_sale jsonb; v_row record;
    v_rederived numeric;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-38', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['data.view_prices','module.output.view','module.output.edit',
                           'module.pricing.view','module.finance.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX38-M', 'fixture 38 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX38-C', 'fixture 38 customer', 'SG') RETURNING id INTO v_cust;

    -- 产出批:100 kg,ni 50%
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX38-OB', v_mat, 100, 100, '2027-06-01') RETURNING id INTO ob;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob, 'ni', 50, 'manual');

    -- 行情:ni 20,000 USD/吨 → 含 50%、100% 应付时 10 USD/kg
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 20000, '2027-06-01', 'broker_quote');
    -- 【tt_buy ≠ tt_sell,故意拉开】—— 这一对就是 A 臂的判别力
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2027-06-05', 'tt_buy', 1.20), ('USD', '2027-06-05', 'tt_sell', 1.30);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. 边:卖方报价按 tt_buy 折算 ═══════════════════════════════
    -- 现货预设,卖价折成本位币:usd_price × tt_buy(USD) / 1
    q := price_output_sale(ob, NULL, v_base, 100, '2027-06-05');
    v_usd := (q->'provenance'->>'unit_price_usd_per_kg')::numeric;
    IF v_usd <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 38A 前置失败:USD 单价应为 10(20000/吨 × 50%% × 100%%),实得 % —— 引擎算术不对,后面的边无从谈起', v_usd;
    END IF;
    v_expect := round(v_usd * 1.20, 4);   -- 收钱进来:tt_buy
    v_wrong  := round(v_usd * 1.30, 4);   -- 买方的边:tt_sell —— 这是【错误】的数
    IF (q->>'unit_price_ccy')::numeric = v_wrong THEN
        RAISE EXCEPTION 'FIXTURE 38A 失败:卖方报价 % 等于按 tt_sell(买方的边)折出来的数 —— 报价路径继承了买路径的汇率边。收钱进来必须按 tt_buy:期望 %',
            q->>'unit_price_ccy', v_expect;
    END IF;
    IF (q->>'unit_price_ccy')::numeric <> v_expect THEN
        RAISE EXCEPTION 'FIXTURE 38A 失败:卖方报价应为 %(10 USD/kg × tt_buy 1.20),实得 %',
            v_expect, q->>'unit_price_ccy';
    END IF;
    IF q->'provenance'->'fx'->>'side' <> 'tt_buy' THEN
        RAISE EXCEPTION 'FIXTURE 38A 失败:出处里记的边应为 tt_buy,实得 %', q->'provenance'->'fx'->>'side';
    END IF;

    -- ══════════ B. 现货 = 预设:与显式 100%/0/0 公式同数 ═════════════════════
    INSERT INTO pricing_formulas (code, name, direction, price_basis,
                                  treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX38-PF', 'fixture 38 explicit spot', 'sale', 'spot', 0, 0)
    RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_formula, 'ni', 100);

    q2 := price_output_sale(ob, v_formula, v_base, 100, '2027-06-05');
    IF (q2->>'unit_price_ccy')::numeric <> (q->>'unit_price_ccy')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 38B 失败:现货预设(%)与显式 100%%/0/0 公式(%)应给出同一个数 —— 不同就说明现货是第四条算术分支,而分支会像修掉的那六个重复实现一样漂移',
            q->>'unit_price_ccy', q2->>'unit_price_ccy';
    END IF;

    -- 买方向的公式不能拿来卖
    UPDATE pricing_formulas SET direction = 'purchase' WHERE id = v_formula;
    v_denied := false;
    BEGIN
        PERFORM price_output_sale(ob, v_formula, v_base, 100, '2027-06-05');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FORMULA_DIRECTION|%' THEN
        RAISE EXCEPTION 'FIXTURE 38B 失败:purchase 方向的公式用于卖方报价应被 FORMULA_DIRECTION 拒绝,实得 denied=% msg=%', v_denied, v_msg;
    END IF;
    UPDATE pricing_formulas SET direction = 'sale' WHERE id = v_formula;

    -- ══════════ C. 出处:computed 可重导;manual 是记录不是推断 ═══════════════
    v_sale := record_output_sale(ob, 10, (q->>'unit_price_ccy')::numeric, v_base, NULL,
                                 v_cust, '2027-06-05'::date, NULL,
                                 'computed', q->'provenance');
    SELECT price_source, price_provenance INTO v_row
    FROM sales_records WHERE id = (v_sale->>'sale_id')::uuid;
    IF v_row.price_source <> 'computed' OR v_row.price_provenance IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 38C 失败:computed 的销售应带出处,实得 source=% provenance null=%',
            v_row.price_source, v_row.price_provenance IS NULL;
    END IF;
    -- 【重导】:出处里的 usd 单价 × 出处里的汇率因子 = 存下的单价。
    -- 重导不出来的出处只是标签(FIN-26 的标准)。
    v_rederived := round((v_row.price_provenance->>'unit_price_usd_per_kg')::numeric
                         * (v_row.price_provenance->'fx'->>'factor')::numeric, 4);
    IF v_rederived <> (q->>'unit_price_ccy')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 38C 失败:从出处重导出 %,存下的是 % —— 出处重导不出这个数,它只是标签',
            v_rederived, q->>'unit_price_ccy';
    END IF;

    -- manual:明说,不从"没挂公式"推断 —— 系统里明明有公式,这单仍是 manual
    v_sale := record_output_sale(ob, 5, 99, v_base, NULL, v_cust, '2027-06-05'::date, NULL,
                                 'manual', NULL);
    SELECT price_source, price_provenance INTO v_row
    FROM sales_records WHERE id = (v_sale->>'sale_id')::uuid;
    IF v_row.price_source <> 'manual' OR v_row.price_provenance IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 38C 失败:手填的销售应记 manual 且不带依据,实得 source=% provenance null=%',
            v_row.price_source, v_row.price_provenance IS NULL;
    END IF;

    -- computed 无依据:函数拒(PROVENANCE_REQUIRED),直插拒(配对 CHECK)——
    -- "没有依据的 computed"在两个门上都不可表示
    v_denied := false;
    BEGIN
        PERFORM record_output_sale(ob, 1, 12, v_base, NULL, v_cust, '2027-06-05'::date, NULL,
                                   'computed', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'PROVENANCE_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 38C 失败:computed 无依据应被 PROVENANCE_REQUIRED 拒绝,实得 denied=% msg=%', v_denied, v_msg;
    END IF;
    v_denied := false;
    BEGIN
        INSERT INTO sales_records (output_batch_id, quantity, unit_price, currency, fx_rate,
                                   amount_base, sale_date, price_source)
        VALUES (ob, 1, 12, v_base, 1, 12, '2027-06-05', 'computed');
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 38C 失败:直插"computed 无依据"被接受了 —— 配对 CHECK 没在';
    END IF;

    -- ══════════ D. 缺即拒,各自点名 ═════════════════════════════════════════
    -- 缺金属行情(2027-01-01 之前无 ni 价)
    v_denied := false;
    BEGIN
        PERFORM price_output_sale(ob, NULL, v_base, 100, '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'METAL_PRICE_MISSING|%' THEN
        RAISE EXCEPTION 'FIXTURE 38D 失败:缺行情应 METAL_PRICE_MISSING 点名,实得 denied=% msg=% —— 报价路径缺价必须停,一份按零价发出去的报价比停一下更坏',
            v_denied, v_msg;
    END IF;
    -- 缺汇率:2027-06-10(周四,工作日)没有 USD 牌价 → 换外币报价必须拒
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source) VALUES ('ni', 21000, '2027-06-10', 'broker_quote');
    v_denied := false;
    BEGIN
        PERFORM price_output_sale(ob, NULL, 'USD', 100, '2027-06-10');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FX_RATE_MISSING|%' THEN
        RAISE EXCEPTION 'FIXTURE 38D 失败:缺汇率应 FX_RATE_MISSING 点名,实得 denied=% msg=%', v_denied, v_msg;
    END IF;
END $$;
ROLLBACK;
