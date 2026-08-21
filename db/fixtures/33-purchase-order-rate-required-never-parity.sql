-- 33 采购单的汇率【必须来自牌价】,不许有默认值兜着
--
-- 【为什么值得常设(FIN-35)】purchase_orders.fx_rate 曾带着 DEFAULT 1。
-- 那是 FX 规则花了几切次清掉的 `?? 1`,写成了 schema 默认值 —— 而
-- check-currency-literals 当时看不见它,因为它找的是币种【代码】,这是汇率【数值】。
-- 一条非本位币单据上的 1:1 永远是错的,而且四舍五入到分之后完全看不出来:
-- USD 120,000 会读成本位币 120,000 而不是约 150,600。
--
-- 四臂,两个方向都钉:
--   A 外币 + 当日无牌价 → 【点名】拒绝(FX_RATE_MISSING),不是悄悄给个 1
--   B 外币 + 当日有牌价 → 成功,并且用的就是那一天的 tt_sell(否则 A 臂可能
--     只是因为"采购单根本建不起来"而通过)
--   C 本位币 + 无任何牌价行 → 【仍然成功】,汇率恒 1 —— 本位币没有汇率这回事,
--     不能把"必须有牌价"错误地推广到它头上
--   D 绕过 RPC 直接 INSERT 且不给 fx_rate → 必须失败。这一臂就是删掉 DEFAULT
--     买到的东西:没有默认值可拿,漏传就撞 NOT NULL,而不是拿到一个编出来的 1。
--
-- 【日期自设】(README 第 4 条)。全部落在 2027,并显式清空 locked_before。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_sup uuid; v_mat uuid; v_base text; v_fgn text;
    v_po jsonb; v_lines jsonb;
    v_id uuid; v_rate numeric; v_ccy text;
    v_denied boolean; v_msg text;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    -- 任意一个【非】本位币的币种 —— 不写死 'USD'(币种是数据,不是常量)
    SELECT code INTO v_fgn FROM currencies WHERE NOT is_base LIMIT 1;
    IF v_fgn IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 33 前置失败:currencies 里没有非本位币,本 fixture 无从谈起';
    END IF;

    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-33', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r, 'module.purchasing.edit'), (r, 'module.purchasing.view'),
           (r, 'module.suppliers.view'), (r, 'data.view_prices');
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZFIX33-S', 'fixture 33 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX33-M', 'fixture 33 material', 'battery_material', true) RETURNING id INTO v_mat;

    v_lines := jsonb_build_array(jsonb_build_object(
        'line_no', 1, 'material_id', v_mat, 'quantity', 10, 'estimated_unit_price', 100));

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. 外币 + 当日无牌价 → 点名拒绝 ═════════════════════════════
    -- 2027-03-03 是周三(工作日),所以【不会】走 FIN-13 的就近取值:
    -- 工作日缺牌价必须拒绝,这正是 FIN-19 修好的那条边界。
    v_denied := false;
    BEGIN
        PERFORM create_purchase_order(v_sup, '2027-03-03'::date, NULL, v_fgn, NULL,
                                      NULL, NULL, NULL, v_lines, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 33A 失败:外币采购单在当日没有牌价的情况下建成功了 —— 那意味着某处又给了它一个汇率(默认值、COALESCE 或别的兜底),而编出来的汇率在非本位币单据上永远是错的';
    END IF;
    IF v_msg NOT LIKE 'FX_RATE_MISSING|%' THEN
        RAISE EXCEPTION 'FIXTURE 33A 失败:拒绝了,但报的不是 FX_RATE_MISSING,而是「%」—— 拒绝必须【点名】,否则排查时分不清是缺牌价还是别的毛病', v_msg;
    END IF;

    -- ══════════ B. 外币 + 当日有牌价 → 成功,且用的就是那一天的 tt_sell ══════
    -- 【没有这一臂,A 臂可能只是因为采购单根本建不起来而通过】
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES (v_fgn, '2027-03-03', 'tt_sell', 1.4321);

    v_po := create_purchase_order(v_sup, '2027-03-03'::date, NULL, v_fgn, NULL,
                                  NULL, NULL, NULL, v_lines, NULL);
    v_id := (v_po->>'purchase_order_id')::uuid;
    IF v_id IS NULL THEN
        v_id := (v_po->>'id')::uuid;
    END IF;
    SELECT fx_rate, currency INTO v_rate, v_ccy FROM purchase_orders
     WHERE id = v_id OR code = (v_po->>'code');
    IF v_rate <> 1.4321 THEN
        RAISE EXCEPTION 'FIXTURE 33B 失败:汇率应取当日 tt_sell = 1.4321,实得 % —— 若为 1 就是又从某个默认值里拿的', v_rate;
    END IF;
    IF v_rate = 1 THEN
        RAISE EXCEPTION 'FIXTURE 33B 失败:汇率是 1,而本臂特意把牌价设成 1.4321 就是为了让"平价"与"真汇率"分得开';
    END IF;

    -- ══════════ C. 本位币 → 不需要牌价,汇率恒 1 ═════════════════════════════
    -- 【必须有这一臂】否则"汇率必须来自牌价"会被错误地推广到本位币身上,
    -- 而本位币【没有汇率这回事】(fx_rate_asof 对它直接返回 1,不查表)。
    -- 注意这一天【故意没有任何牌价行】。
    v_po := create_purchase_order(v_sup, '2027-05-05'::date, NULL, v_base, NULL,
                                  NULL, NULL, NULL, v_lines, NULL);
    SELECT fx_rate INTO v_rate FROM purchase_orders WHERE code = (v_po->>'code');
    IF v_rate <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 33C 失败:本位币单据的汇率应为 1,实得 %', v_rate;
    END IF;

    -- ══════════ D. 直接 INSERT 不给汇率 → 必须失败(删掉 DEFAULT 买到的就是这个)══
    v_denied := false;
    BEGIN
        INSERT INTO purchase_orders (code, supplier_id, order_date, currency, estimated_total_ccy)
        VALUES ('ZZFIX33-RAW', v_sup, '2027-06-06', v_fgn, 1000);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true;
    END;
    IF NOT v_denied THEN
        SELECT fx_rate INTO v_rate FROM purchase_orders WHERE code = 'ZZFIX33-RAW';
        RAISE EXCEPTION 'FIXTURE 33D 失败:漏传汇率的直接 INSERT 成功了,拿到 fx_rate = % —— 说明列上又有默认值了。DEFAULT 1 是死的但有毒:唯一的 RPC 路径从不用它,而任何别的写法都会静悄悄拿到平价',
            v_rate;
    END IF;
END $$;
ROLLBACK;
