-- 41 计价明细:【条款未列明】与【条款谈定 0%】必须分得开;而钱一分不变
--
-- 【判别臂是 A:两种 0 的对照】同一个金属、同样的含量,一边是公式压根没提它,
-- 一边是公式明确写了 payable 0% —— 前者应付比例给 NULL(界面印"—"),后者给 0。
-- 只测"未列明的行是 NULL"的 fixture 对一个"把所有 0 都变 NULL"的实现照样全绿,
-- 而那个实现会把一条真谈成零的条款也说成"未列明",反过来骗人。
-- 注入方式:把 'payable_pct', CASE WHEN v_stated THEN v_payable END 改回
-- 'payable_pct', v_payable,本臂即红并指出两者印成了同一个数。
--
-- 【B:钱不许动】这一刀只改输出行的表达,不改算术 —— 净值、单价、总额与改之前
-- 逐分相等(未列明的金属贡献仍是 0)。手算依据写在臂内。
-- 【C:缺行情的金额也不是 0】有条款但当天没行情,金额算不出来 → NULL,
-- 与"算出来是 0"分开;应付比例照旧给数(条款是有的)。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_silent uuid; v_zero uuid;
    v_metals jsonb := '[{"metal":"ni","content_pct":50},{"metal":"al","content_pct":20}]'::jsonb;
    v_res jsonb; v_line jsonb; v_line0 jsonb;
    v_net numeric; v_unit numeric;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-41', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['data.view_prices','module.pricing.view','module.pricing.edit']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    -- 行情:ni 20,000 USD/吨;al 【本臂自己造】1,000 USD/吨,免得继承线上有没有
    DELETE FROM metal_prices WHERE metal IN ('ni','al') AND price_date = CURRENT_DATE;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 20000, CURRENT_DATE, 'broker_quote'), ('al', 1000, CURRENT_DATE, 'broker_quote');

    -- 两张公式:一张对 al【只字不提】,一张对 al【明确写 0%】
    INSERT INTO pricing_formulas (code, name, direction, price_basis,
                                  treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX41-SILENT', 'silent about al', 'purchase', 'spot', 0, 0) RETURNING id INTO v_silent;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_silent, 'ni', 70);

    INSERT INTO pricing_formulas (code, name, direction, price_basis,
                                  treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX41-ZERO', 'explicit zero for al', 'purchase', 'spot', 0, 0) RETURNING id INTO v_zero;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    VALUES (v_zero, 'ni', 70), (v_zero, 'al', 0);   -- CHECK 是 >= 0:谈定 0% 是正当条款

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. 未列明 → NULL;谈定 0% → 0 ═══════════════════════════════
    v_res := calculate_metal_price_from_terms(
        pricing_terms_of_formula(v_silent), v_metals, 100, CURRENT_DATE);
    SELECT l INTO v_line FROM jsonb_array_elements(v_res->'lines') l
     WHERE l->>'metal' = 'al';
    IF v_line->'payable_pct' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 41A 失败:公式对 al 只字未提,应付比例应为 NULL(界面印"—"),实得 % —— 应付比例列里的 0 会被读成一条谈定的条款("这个金属我们不付钱"),而公式只是没提它',
            v_line->'payable_pct';
    END IF;
    IF v_line->'metal_value_usd' <> 'null'::jsonb OR v_line->'payable_kg' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 41A 失败:未列明条款时应付公斤数与金额也算不出来,应为 NULL,实得 payable_kg=% value=%',
            v_line->'payable_kg', v_line->'metal_value_usd';
    END IF;
    IF NOT ((v_res->'unpaid_metals') ? 'al') THEN
        RAISE EXCEPTION 'FIXTURE 41A 失败:未列明的金属应进 unpaid_metals(灰字提示靠它),实得 %', v_res->'unpaid_metals';
    END IF;

    -- 【对照】明确 0% 的那张:0 就是 0,不许也变成"未列明"
    v_res := calculate_metal_price_from_terms(
        pricing_terms_of_formula(v_zero), v_metals, 100, CURRENT_DATE);
    SELECT l INTO v_line0 FROM jsonb_array_elements(v_res->'lines') l
     WHERE l->>'metal' = 'al';
    IF (v_line0->>'payable_pct')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 41A 失败:公式明确写了 al 0%%,就应当印 0(那是一条真的条款),实得 % —— 把所有 0 都变成"未列明"是反方向的谎',
            v_line0->'payable_pct';
    END IF;
    IF (v_line0->>'metal_value_usd')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 41A 失败:谈定 0%% 的金属金额确实是 0(算得出来的零),实得 %', v_line0->'metal_value_usd';
    END IF;
    IF (v_res->'unpaid_metals') ? 'al' THEN
        RAISE EXCEPTION 'FIXTURE 41A 失败:明确谈定 0%% 不该进 unpaid_metals —— 那句灰字会说反话';
    END IF;

    -- ══════════ B. 钱一分不变:两张公式的净值/单价都只由 ni 撑起 ═══════════════
    -- ni:100 kg × 50% = 50 kg 含量 × 70% 应付 = 35 kg;35/1000 × 20,000 = 700.00 USD
    -- al 两边都贡献 0(一边未列明,一边谈定 0%),处理费与折扣均为 0 → 净值 700.00
    v_net  := (v_res->>'net_value_usd')::numeric;
    v_unit := (v_res->>'unit_price_usd_per_kg')::numeric;
    IF v_net <> 700.00 OR v_unit <> 7.0000 THEN
        RAISE EXCEPTION 'FIXTURE 41B 失败:净值应为 700.00、单价 7.0000(仅 ni:35 kg 应付 × 20,000/吨),实得 % / % —— 把表达改成 NULL 不许动到任何一分钱',
            v_net, v_unit;
    END IF;
    v_res := calculate_metal_price_from_terms(
        pricing_terms_of_formula(v_silent), v_metals, 100, CURRENT_DATE);
    IF (v_res->>'net_value_usd')::numeric <> v_net
       OR (v_res->>'unit_price_usd_per_kg')::numeric <> v_unit THEN
        RAISE EXCEPTION 'FIXTURE 41B 失败:未列明与谈定 0%% 的【金额】应当一样(都贡献零),实得 % vs %',
            v_res->>'net_value_usd', v_net;
    END IF;

    -- ══════════ C. 有条款但没行情:比例照给,金额算不出来 → NULL ════════════════
    DELETE FROM metal_prices WHERE metal = 'al';
    v_res := calculate_metal_price_from_terms(
        pricing_terms_of_formula(v_zero), v_metals, 100, CURRENT_DATE);
    SELECT l INTO v_line FROM jsonb_array_elements(v_res->'lines') l
     WHERE l->>'metal' = 'al';
    IF v_line->'payable_pct' = 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 41C 失败:缺行情不影响"条款写没写"—— 应付比例仍应是 0,实得 NULL';
    END IF;
    IF v_line->'metal_value_usd' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 41C 失败:没有行情就算不出金额,应为 NULL(界面印"—"),实得 % —— 印 0.00 会被读成"这批料里的它一文不值"',
            v_line->'metal_value_usd';
    END IF;
    IF NOT ((v_res->'skipped_metals') ? 'al') THEN
        RAISE EXCEPTION 'FIXTURE 41C 失败:缺行情的金属应进 skipped_metals(琥珀提示靠它),实得 %', v_res->'skipped_metals';
    END IF;
END $$;
ROLLBACK;
