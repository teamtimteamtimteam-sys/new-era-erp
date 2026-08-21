-- 104 一笔定金知道自己是什么币种 —— 两条支路,一条拒绝
--
-- 【这份 fixture 自带全部数据】重建出来的库【一行业务数据都没有】,所以每一臂
-- 自己造:一家供货商、一个物料、若干采购单与定金、进料批次与费用单,以及它
-- 自己要用的牌价(不借线上的 fx_rates,那是随时间变的东西 —— README 第 4 条)。
--
-- 【被钉的规矩】1300 预付款项由 record_payment 按【采购单的币种】记入,而
-- apply_prepayment 从前按 base_currency_code() 贷回去。EQP-1b-i 让冲抵按
-- 【应付那一侧的计价币种】陈述,并按两条支路结账:
--   R1 定金币种 = 应付币种 → 单位对齐,差额(两个【历史】汇率之差)进 7100;
--   R2 恰有一个是本位币   → 价值对齐,7100 【恒为零,是构造出来的零】;
--   R3 两边都是外币且不同 → 按名拒绝。
--
-- 【八臂,以及每一臂钉的是什么】
-- A 前提先立:本位币的进料冲抵,分录与从前【逐分相同】,7100 一条行都没有。
--   若这一臂过不去,就说明改写动了材料路径 —— 后面每一条都是空转。
-- B R1 设备链,两侧汇率【不同】(定金 1.30,发票 1.35):2000 按【自己的币种】
--   减 10,000 USD、1300 在定金币种上净额归零、7100 恰好 500。断言的是【那个数】,
--   不是"非零"。
-- C 本刀的目的地:重估。B 之后 2000 的 USD 敞口必须是【剩下的】40,000,
--   不是原来的 50,000。故障注入把贷方改回本位币,这一臂就会读到 50,000 而转红。
-- D R2:外币定金冲【本位币计价】的进料应付 —— 材料进口的常态。
--   7100 收到的是【零这个值】,不是"没查到行"(空结果上的断言恒真)。
-- E R3 按名拒绝,断言那个码本身。
-- F 目的地 XOR 两个方向,【按约束名】断言,直插。
-- G 币种三元组:漏了它的 INSERT 被 CHECK 按名拒;并断言那条 CHECK 确实是
--   NOT VALID(convalidated = false)—— 那才是"历史 NULL 原样不动"的机制。
-- H 【可用预付必须在本位币空间数】造一行与线上那条 2026-07-31 历史行【同形】的
--   记录(currency / amount_ccy 皆 NULL),然后让 apply_prepayment 自己去数:
--   它必须报 PREPAY_INSUFFICIENT。若有人把守卫改成 Σ amount_ccy,那一行会被
--   静默跳过,一笔【已经冲抵完】的定金会读成还能再冲一次,这一臂随即转红。
--
-- 【H 为什么不去读线上那一行】fixture 跑在【重建出来的库】上(gate.py 判词三),
-- 那里没有任何业务数据 —— 线上那条历史行在这里根本不存在。而且依赖线上某一行
-- 保持某个数,正是 README 第 4 条禁止的"依赖随时间变的状态"。所以这一臂用
-- 【历史当初的那条路】把同形的行造出来:那一行之所以能有 NULL,是因为它记于
-- 约束【存在之前】—— 于是先摘掉约束、插入、再按 NOT VALID 挂回去。
--
-- 【SET CONSTRAINTS ALL IMMEDIATE】journal_lines 的借贷平衡是 DEFERRABLE 的
-- 约束触发器;不设成 IMMEDIATE,一支不平的分录要到 COMMIT 才报,而这里 ROLLBACK。
-- 【EQP-1c-b(X1)之后:冲抵日是【必填参数】,不再是 CURRENT_DATE】——
-- 本 fixture 每一处调用因此都显式给了日期。给的是 2027-03-01,与各臂的
-- 发票日同月:这些臂断言的是【金额与科目】,不是期间,所以只要它是一个
-- 确定的、不随"今天"漂移的日子就够 —— 而"不随今天漂移"正是 X1 的全部理由。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_base text;
    po1 uuid; po2 uuid; po3 uuid; po4 uuid; po5 uuid;
    b1 uuid; b3 uuid; b4 uuid; b5 uuid;
    exp2 uuid; exp4 uuid;
    v_res jsonb; v_app uuid; v_entry uuid;
    v_n int; v_msg text; v_denied boolean;
    v_dr numeric; v_cr numeric; v_fx numeric; v_ccy text;
    v_native numeric; v_native0 numeric; v_row jsonb;
BEGIN
    -- 【没有 approve_purchase_order 这一步】审批开关(APR-2)默认是关的,关着时
    -- approve_purchase_order 直接抛 APPROVALS_NOT_ENABLED,而新建的单子本来就是
    -- approved。刻意不在这里打开它:那会把本 fixture 绑到一个【设置】上,
    -- 而这一份要钉的是币种,不是审批。
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-104', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 自己的牌价:精确落在用到的每一天上,不走任何回溯
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit) VALUES
        ('USD', DATE '2027-02-01', 'tt_sell', 1.30),
        ('USD', DATE '2027-03-01', 'tt_sell', 1.35),
        ('USD', DATE '2027-03-31', 'mid',     1.40),
        ('CNY', DATE '2027-03-05', 'tt_sell', 0.19);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX104-S', 'fixture 104 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX104-M', 'fixture 104 material', 'other') RETURNING id INTO v_mat;

    -- ══════════ A · 前提:本位币进料冲抵,与从前逐分相同 ═════════════════════
    v_res := create_purchase_order(v_sup, DATE '2027-02-01', DATE '2027-04-01', v_base, NULL,
        NULL, NULL, 'fixture 104 A base PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'unit', 'kg', 'estimated_unit_price', 20)));
    po1 := (v_res->>'purchase_order_id')::uuid;
    PERFORM record_payment('out', v_sup, 1000, v_base, NULL, NULL, DATE '2027-02-01',
        'fixture 104 A deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', po1, 'amount_doc', 1000)),
        'supplier');
    v_res := create_inbound_batch(v_mat, v_sup, 100, 'kg', DATE '2027-02-05', '待加工',
        20, 'fixture 104 A batch', NULL, NULL, NULL, NULL);
    b1 := (v_res->>'batch_id')::uuid;

    v_res := apply_prepayment(po1, b1, 1000, NULL, NULL, DATE '2027-03-01');
    v_app := (v_res->>'application_id')::uuid;
    SELECT id INTO v_entry FROM journal_entries WHERE source_id = v_app;

    SELECT count(*) INTO v_n FROM journal_lines WHERE entry_id = v_entry;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 104A 失败:本位币冲抵应当恰好两条行(借 2000 / 贷 1300),实得 % —— 多出来的那条多半是 7100,而本位币两侧没有任何汇兑可言', v_n;
    END IF;
    SELECT jl.debit, jl.currency, jl.fx_rate INTO v_dr, v_ccy, v_fx
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = v_entry AND a.code = '2000';
    IF v_dr <> 1000 OR v_ccy <> v_base OR v_fx <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 104A 失败:2000 应当借本位币 1000.00 @1,实得 % % @%', v_dr, v_ccy, v_fx;
    END IF;
    SELECT jl.credit, jl.currency, jl.fx_rate INTO v_cr, v_ccy, v_fx
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = v_entry AND a.code = '1300';
    IF v_cr <> 1000 OR v_ccy <> v_base OR v_fx <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 104A 失败:1300 应当贷本位币 1000.00 @1,实得 % % @%', v_cr, v_ccy, v_fx;
    END IF;
    SELECT count(*) INTO v_n FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_entry AND a.code = '7100';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 104A 失败:本位币冲抵不该产生已实现汇兑,7100 却有 % 条行', v_n;
    END IF;
    SELECT amount_base, currency, amount_ccy INTO v_dr, v_ccy, v_cr
      FROM prepayment_applications WHERE id = v_app;
    IF v_dr <> 1000 OR v_ccy <> v_base OR v_cr <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 104A 失败:落库的三元组应当是 (1000, %, 1000),实得 (%, %, %)', v_base, v_dr, v_ccy, v_cr;
    END IF;

    -- 【C 的基线在这里量】断言的是 B 造成的【变化量】,不是绝对值 ——
    -- 这一份 fixture 在重建库里跑(那里 2000 一行都没有),但迭代时跑在有历史数据
    -- 的线上;把绝对值写死会让它只在其中一边成立,而那种断言证明不了任何东西。
    SELECT COALESCE((SELECT (value->>'native')::numeric
        FROM jsonb_array_elements(preview_revalue_foreign_balances(DATE '2027-03-31')->'rows') t(value)
        WHERE value->>'account' = '2000' AND value->>'currency' = 'USD'), 0)
    INTO v_native0;

    -- ══════════ B · R1 设备链,两侧汇率不同 ═════════════════════════════════
    -- 定金:USD PO 于 2027-02-01 建单 ⇒ po.fx_rate = 当日 tt_sell = 1.30,
    --       核销行 allocated_base = 10,000 × 1.30 = 13,000 ⇒ 加权平均率 1.30。
    -- 发票:2027-03-01 的 tt_sell = 1.35 ⇒ 应付 USD 50,000,本位币 67,500。
    -- 冲抵 10,000 USD ⇒ 借 2000 13,500 / 贷 1300 13,000 / 贷 7100 500(益)。
    v_res := create_purchase_order(v_sup, DATE '2027-02-01', DATE '2027-04-01', 'USD', NULL,
        NULL, NULL, 'fixture 104 B equipment PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1000,
                                             'unit', 'kg', 'estimated_unit_price', 50)));
    po2 := (v_res->>'purchase_order_id')::uuid;
    PERFORM record_payment('out', v_sup, 10000, 'USD', NULL, NULL, DATE '2027-02-01',
        'fixture 104 B deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', po2, 'amount_doc', 10000)),
        'supplier');

    v_res := record_expense(DATE '2027-03-01', '1500', 50000, 'USD', NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 104 B machine invoice',
        jsonb_build_object('description', 'fixture 104 press', 'useful_life_months', 120), NULL);
    exp2 := (v_res->>'expense_id')::uuid;

    v_res := apply_prepayment(po2, NULL, 10000, 'fixture 104 B release', exp2, DATE '2027-03-01');
    v_app := (v_res->>'application_id')::uuid;
    SELECT id INTO v_entry FROM journal_entries WHERE source_id = v_app;

    SELECT jl.debit, jl.currency, jl.amount_ccy INTO v_dr, v_ccy, v_cr
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = v_entry AND a.code = '2000';
    IF v_ccy <> 'USD' OR v_cr <> 10000 OR v_dr <> 13500 THEN
        RAISE EXCEPTION 'FIXTURE 104B 失败:2000 应当按【自己的币种】借 USD 10,000(本位币 13,500),实得 % % / 本位币 %  —— 用本位币去减一张外币应付,重估会永远以为那 10,000 还欠着', v_cr, v_ccy, v_dr;
    END IF;
    SELECT jl.credit, jl.currency, jl.amount_ccy INTO v_cr, v_ccy, v_dr
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = v_entry AND a.code = '1300';
    IF v_ccy <> 'USD' OR v_dr <> 10000 OR v_cr <> 13000 THEN
        RAISE EXCEPTION 'FIXTURE 104B 失败:1300 应当贷 USD 10,000(按定金加权率 1.30 = 本位币 13,000),实得 % % / 本位币 %', v_dr, v_ccy, v_cr;
    END IF;
    SELECT COALESCE(sum(jl.credit), 0) - COALESCE(sum(jl.debit), 0) INTO v_cr
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = v_entry AND a.code = '7100';
    IF v_cr <> 500 THEN
        RAISE EXCEPTION 'FIXTURE 104B 失败:已实现汇兑应当恰好是 500.00(10,000 × (1.35 − 1.30),两个【历史】汇率之差),实得 %', v_cr;
    END IF;
    -- 1300 在定金币种上净额归零 —— 定金付了 10,000 USD,这次全数用掉
    SELECT COALESCE(sum(jl.debit - jl.credit), 0) INTO v_dr
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '1300' AND jl.currency = 'USD';
    IF v_dr <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 104B 失败:1300 在 USD 上应当净额归零,实得 % —— 定金进来是 USD、冲出去若是别的币种,那个头寸就永远清不掉', v_dr;
    END IF;

    -- ══════════ C · 本刀的目的地:重估读到的是【剩下的】敞口 ════════════════
    SELECT value INTO v_row
    FROM jsonb_array_elements(preview_revalue_foreign_balances(DATE '2027-03-31')->'rows') t(value)
    WHERE value->>'account' = '2000' AND value->>'currency' = 'USD';
    IF v_row IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 104C 失败:重估预览里没有 2000/USD 这一行 —— 空结果上的断言恒真,所以这里先要它在';
    END IF;
    v_native := (v_row->>'native')::numeric - v_native0;
    IF v_native <> -40000 THEN
        RAISE EXCEPTION 'FIXTURE 104C 失败:B 一共该给 2000 的 USD 敞口留下 -40,000 的变化(开票欠 50,000,冲抵还掉 10,000),实得 % —— 若是 -50,000,说明冲抵【没有减到 USD 头寸上】,重估会年复一年地按 50,000 去算汇兑,而那 10,000 早就不欠了', v_native;
    END IF;

    -- ══════════ D · R2:外币定金冲【本位币计价】的进料应付 ═══════════════════
    -- 材料进口的常态:USD 采购单的定金,冲一张以本位币计价的到货批次应付。
    -- 价值对齐 ⇒ 借 2000 本位币 13,000 / 贷 1300 USD 10,000 @1.30 ⇒ 7100 恰好零。
    v_res := create_purchase_order(v_sup, DATE '2027-02-01', DATE '2027-04-01', 'USD', NULL,
        NULL, NULL, 'fixture 104 D import PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1000,
                                             'unit', 'kg', 'estimated_unit_price', 50)));
    po3 := (v_res->>'purchase_order_id')::uuid;
    PERFORM record_payment('out', v_sup, 10000, 'USD', NULL, NULL, DATE '2027-02-01',
        'fixture 104 D deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', po3, 'amount_doc', 10000)),
        'supplier');
    v_res := create_inbound_batch(v_mat, v_sup, 1300, 'kg', DATE '2027-02-10', '待加工',
        10, 'fixture 104 D batch', NULL, NULL, NULL, NULL);
    b3 := (v_res->>'batch_id')::uuid;

    v_res := apply_prepayment(po3, b3, 13000, NULL, NULL, DATE '2027-03-01');
    v_app := (v_res->>'application_id')::uuid;
    SELECT id INTO v_entry FROM journal_entries WHERE source_id = v_app;

    SELECT count(*) INTO v_n FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_entry AND a.code = '7100';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 104D 失败:价值对齐的冲抵不可能产生损益,7100 却有 % 条行 —— 1300 是 is_monetary=false,按定金自己的汇率消耗它,零是【构造出来的】', v_n;
    END IF;
    SELECT jl.credit, jl.currency, jl.amount_ccy INTO v_cr, v_ccy, v_dr
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = v_entry AND a.code = '1300';
    IF v_ccy <> 'USD' OR v_dr <> 10000 OR v_cr <> 13000 THEN
        RAISE EXCEPTION 'FIXTURE 104D 失败:1300 应当贷 USD 10,000 @1.30(本位币 13,000),实得 % % / 本位币 %', v_dr, v_ccy, v_cr;
    END IF;
    SELECT jl.debit, jl.currency INTO v_dr, v_ccy
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = v_entry AND a.code = '2000';
    IF v_ccy <> v_base OR v_dr <> 13000 THEN
        RAISE EXCEPTION 'FIXTURE 104D 失败:进料应付以本位币计价,2000 应当借 % 13,000,实得 % %', v_base, v_dr, v_ccy;
    END IF;
    SELECT COALESCE(sum(jl.debit - jl.credit), 0) INTO v_dr
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '1300' AND jl.currency = 'USD';
    IF v_dr <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 104D 失败:1300 在 USD 上应当净额归零(B 与 D 的定金都恰好用尽),实得 %', v_dr;
    END IF;

    -- ══════════ E · R3 两边都是外币且不同 → 按名拒绝 ════════════════════════
    v_res := create_purchase_order(v_sup, DATE '2027-02-01', DATE '2027-04-01', 'USD', NULL,
        NULL, NULL, 'fixture 104 E PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1000,
                                             'unit', 'kg', 'estimated_unit_price', 50)));
    po4 := (v_res->>'purchase_order_id')::uuid;
    PERFORM record_payment('out', v_sup, 5000, 'USD', NULL, NULL, DATE '2027-02-01',
        'fixture 104 E deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', po4, 'amount_doc', 5000)),
        'supplier');
    v_res := record_expense(DATE '2027-03-05', '6300', 20000, 'CNY', NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 104 E CNY invoice', NULL, NULL);
    exp4 := (v_res->>'expense_id')::uuid;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM apply_prepayment(po4, NULL, 1000, NULL, exp4, DATE '2027-03-01');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PREPAY_TWO_FOREIGN_CURRENCIES' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 104E 失败:USD 定金冲 CNY 应付应当按名拒 PREPAY_TWO_FOREIGN_CURRENCIES,实得 denied=% msg=%', v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F · 目的地 XOR 两个方向,直插 ═══════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO prepayment_applications (purchase_order_id, amount_base, currency, amount_ccy)
        VALUES (po1, 1, v_base, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('prepayment_applications_one_destination' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 104F 失败:两个目的地都空的行应当被 prepayment_applications_one_destination 拒,实得 denied=% msg=%', v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO prepayment_applications (purchase_order_id, inbound_batch_id, expense_id,
                                             amount_base, currency, amount_ccy)
        VALUES (po1, b1, exp2, 1, v_base, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('prepayment_applications_one_destination' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 104F 失败:两个目的地都给的行应当被 prepayment_applications_one_destination 拒,实得 denied=% msg=%', v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ G · 币种三元组:新行必须带,而机制是 NOT VALID ═══════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO prepayment_applications (purchase_order_id, inbound_batch_id, amount_base)
        VALUES (po1, b1, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('prepayment_applications_currency_stated' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 104G 失败:漏掉币种三元组的新行应当被 prepayment_applications_currency_stated 拒,实得 denied=% msg=%', v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    SELECT convalidated INTO v_denied FROM pg_constraint
     WHERE conrelid = 'public.prepayment_applications'::regclass
       AND conname = 'prepayment_applications_currency_stated';
    IF v_denied IS NULL OR v_denied THEN
        RAISE EXCEPTION 'FIXTURE 104G 失败:那条 CHECK 必须是 NOT VALID(convalidated = false),实得 % —— 它一旦被 VALIDATE,线上那条 2026-07-31 的历史行就会挡住迁移,而那一行是刻意不回填的', v_denied;
    END IF;

    -- ══════════ H · 可用预付必须在【本位币空间】数 ══════════════════════════
    -- 造一行与线上那条历史行同形的记录(currency / amount_ccy 皆 NULL)。
    -- 它当初之所以能是 NULL,是因为它记于约束【存在之前】—— 所以这里走同一条路:
    -- 先摘掉约束、插入、再原样按 NOT VALID 挂回去。事务结束即回滚。
    v_res := create_purchase_order(v_sup, DATE '2027-02-01', DATE '2027-04-01', 'USD', NULL,
        NULL, NULL, 'fixture 104 H legacy-shaped PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1000,
                                             'unit', 'kg', 'estimated_unit_price', 50)));
    po5 := (v_res->>'purchase_order_id')::uuid;
    PERFORM record_payment('out', v_sup, 5000, 'USD', NULL, NULL, DATE '2027-02-01',
        'fixture 104 H deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', po5, 'amount_doc', 5000)),
        'supplier');
    v_res := create_inbound_batch(v_mat, v_sup, 1000, 'kg', DATE '2027-02-10', '待加工',
        10, 'fixture 104 H batch', NULL, NULL, NULL, NULL);
    b5 := (v_res->>'batch_id')::uuid;

    -- 定金 5,000 USD @1.30 = 本位币 6,500,全数已被这条【历史形状】的行冲掉
    ALTER TABLE public.prepayment_applications DROP CONSTRAINT prepayment_applications_currency_stated;
    INSERT INTO prepayment_applications (purchase_order_id, inbound_batch_id, amount_base)
    VALUES (po5, b5, 6500);
    ALTER TABLE public.prepayment_applications
        ADD CONSTRAINT prepayment_applications_currency_stated
        CHECK (currency IS NOT NULL AND amount_ccy IS NOT NULL) NOT VALID;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM apply_prepayment(po5, b5, 1, NULL, NULL, DATE '2027-03-01');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PREPAY_INSUFFICIENT' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 104H 失败:这张单的定金已经全额冲抵完,再冲应当报 PREPAY_INSUFFICIENT,实得 denied=% msg=% —— 若守卫改成 Σ amount_ccy,那条 NULL 的历史行会被静默跳过,一笔用完的定金会读成还能再用一次',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- 【SET CONSTRAINTS 放在最后,不能放在开头】journal_lines 的借贷平衡是
    -- DEFERRABLE 的约束触发器,它【必须】等一支分录的所有行都写完才判。
    -- 放在开头会让它在第一条行之后就开火,于是 record_payment 自己都过不去
    -- (实测:JOURNAL_UNBALANCED|JE-2027-0004|1000.00|0)。放在这里,是为了让
    -- 任何一支不平的分录【在块内】报出来 —— 否则它要到 COMMIT 才报,而这里 ROLLBACK。
    SET CONSTRAINTS ALL IMMEDIATE;

    RAISE NOTICE 'FIXTURE 104 八臂全部通过';
END $$;
ROLLBACK;
