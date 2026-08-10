-- 42 发票按【单据币种】开:客户账单上的数 = 数量 × 单价,与汇率无关
--
-- 【判别臂是 A:汇率 ≠ 1】INV-1 之前,发票页与 PDF 拿 invoices.currency 去标
-- *_base 的数。汇率恰好为 1 时两者相等 —— 线上 INV-2026-0002 就这么侥幸对上,
-- 而 INV-2026-0003/0004 各多报了 336 与 1,440 USD。所以本 fixture 的销售
-- 【必须用一个不等于 1 的汇率】,否则整臂对着"直接印本位币"的实现照样全绿。
-- 注入方式:把 invoice_document_totals 的 sum(l.amount_ccy) 改成
-- sum(l.amount_base),本臂即红并把两个数一起说出来。
--
-- 【B:生成列不可写、也不会漂】amount_ccy 是 GENERATED ALWAYS,直插会被拒;
-- 它只由 quantity × unit_price 决定,不经汇率 —— 这正是它能当客户账单的原因。
-- 【C:两道门】无 data.view_prices 的读者拿不到行(而不是拿到置空的数)。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    u2 uuid := gen_random_uuid();
    r uuid; r2 uuid;
    v_mat uuid; v_cust uuid; ob uuid;
    v_sale jsonb; v_inv jsonb; v_inv_id uuid;
    v_base text;
    v_row record;
    v_denied boolean;
    v_n int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-42', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['module.output.edit','module.output.view','module.finance.edit',
                           'module.finance.view','module.customers.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    -- 只有模块权限、没有 data.view_prices 的读者(C 臂用)
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-42b', 'f', 'f', true) RETURNING id INTO r2;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r2, unnest(ARRAY['module.finance.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u2, r2);

    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX42-M', 'fixture 42 material', 'other') RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX42-C', 'fixture 42 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX42-OB', v_mat, 1000, 1000, '2027-09-01') RETURNING id INTO ob;

    -- 【汇率 1.25,不是 1】—— A 臂的全部判别力在这里
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2027-09-05', 'tt_buy', 1.25);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- 500 kg × 12 USD/kg = 6,000.00 USD(客户要付的);本位币 7,500.00(记账的)
    v_sale := record_output_sale(ob, 500, 12, 'USD', NULL, v_cust,
                                 '2027-09-05'::date, NULL, 'manual', NULL);
    v_inv  := create_invoice(v_cust, ARRAY[(v_sale->>'sale_id')::uuid],
                             '2027-09-05'::date, NULL, NULL);
    v_inv_id := (v_inv->>'invoice_id')::uuid;

    -- ══════════ A. 账单上的数是单据币种的,且【不等于】本位币的数 ═══════════
    SELECT * INTO v_row FROM invoice_document_totals WHERE invoice_id = v_inv_id;
    IF v_row.total_ccy <> 6000.00 THEN
        RAISE EXCEPTION 'FIXTURE 42A 失败:客户应付 6,000.00 USD(500 × 12,与汇率无关),实得 % —— 客户照着这个数付款,错一分都是错',
            v_row.total_ccy;
    END IF;
    IF v_row.currency <> 'USD' THEN
        RAISE EXCEPTION 'FIXTURE 42A 失败:单据币种应为 USD,实得 %', v_row.currency;
    END IF;
    -- 本位币那一侧仍然是 7,500.00,而且【必须与账单的数不同】,否则本臂空转
    SELECT total_base INTO v_row FROM invoices WHERE id = v_inv_id;
    IF v_row.total_base <> 7500.00 THEN
        RAISE EXCEPTION 'FIXTURE 42A 前置失败:本位币总额应为 7,500.00(6,000 × 1.25),实得 % —— 汇率若为 1,本臂对"直接印本位币"的实现也会通过',
            v_row.total_base;
    END IF;

    -- 行金额同理:单据币种 6,000.00,本位币 7,500.00
    SELECT amount_ccy, amount_base INTO v_row FROM invoice_lines WHERE invoice_id = v_inv_id;
    IF v_row.amount_ccy <> 6000.00 OR v_row.amount_base <> 7500.00 THEN
        RAISE EXCEPTION 'FIXTURE 42A 失败:行金额应为 单据币 6,000.00 / 本位币 7,500.00,实得 % / % —— 同一行里单价是单据币、金额若是本位币,这张发票自己都对不上账',
            v_row.amount_ccy, v_row.amount_base;
    END IF;

    -- ══════════ B. 生成列:写不得,也不会与单价漂开 ═══════════════════════════
    v_denied := false;
    BEGIN
        UPDATE invoice_lines SET amount_ccy = 1 WHERE invoice_id = v_inv_id;
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 42B 失败:amount_ccy 是生成列,直写应被拒 —— 能被单独改写的账单金额就不再是"数量 × 单价"';
    END IF;

    -- ══════════ C. 两道门:无 data.view_prices 的读者拿不到行(不是拿到空数)═══
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u2), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM invoice_document_totals WHERE invoice_id = v_inv_id;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 42C 失败:没有 data.view_prices 的读者不该看到账单金额,实得 % 行', v_n;
    END IF;
END $$;
ROLLBACK;
