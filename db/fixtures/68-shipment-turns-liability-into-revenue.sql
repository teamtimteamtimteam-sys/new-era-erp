-- 68 发货(SO-3b):合同负债换成收入,而【应收只创建一次】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的五件事】
--   ① 选项 C 的整条链,在【非 1 汇率】上端到端闭合:开票 → 发货 → 收款之后,
--      2500 精确归零、1100 结清、4000/5000 留在损益上。H 臂。
--      非 1 的汇率是刻意的 —— 两边一致时"负债归零"这种断言什么都证明不了。
--   ② 【应收只创建一次】发货产生的销售记录【不进应收】:账龄行数不变、
--      敞口不变。C 臂是这份 fixture 的心脏 —— 少了那条谓词,同一笔钱会在
--      账龄上出现两次而两次都"看起来对";G 臂用注入证明那条谓词真的在挡。
--   ③ 发货【不查信用】,而直接销售【仍然查】。D 臂两个方向都走 ——
--      只断言"不查"的实现,一个把信用闸整个删掉的改动也能通过。
--   ④ 部分发货:负债按比例释放、订单成 partially_shipped、剩余预留【按行数】
--      数得出来(拆分是"整笔释放 + 重新预留",不是把 qty 改小)。E 臂。
--   ⑤ 发过货的发票作废不了(3a 停放的那条检查),已发的预留释放不了。F 臂。
--
-- 各臂:
--   A 前提 + 目录(2500 在;source_type 认 shipment;活预留判据两个条件)
--   B 全量发货:出库腿从 committed 出、腿表、remaining_qty/state、订单 shipped
--   C 【AR 静默】账龄行数与敞口在发货前后【一模一样】;COGS 补挂看得见这一行
--   D 信用:发货不查(超限客户照发);直接销售仍拒(两个方向)
--   E 部分发货:比例释放、partially_shipped、再发一次 → shipped、剩余按行数
--   F 拒绝面:未开票 / 未预留 / 超预留;发过货的票作废不了;已发的预留放不回
--   G 注入:把 AR 静默那条谓词拿掉 → 账龄当场多一行(证明 C 臂有牙)
--   H 端到端:2500 归零、1100 结清、4000/5000 落账(非 1 汇率)
--   I 角色:sales.edit 发得了货;只有 sales.view 的被拒
--   K COGS 补挂【真的跑一遍】:先发货后分摊,补挂给发货产生的那一行挂上 COGS
--     (C 臂只断言数据形状 —— 它抄了补挂的读法;这一臂调用补挂本身)
--   J closed 只能从 shipped 来且是终态;partially_shipped 没有手动去处
--     (fixture 63 E 臂把这一条让给这里 —— 只有这里走得到 shipped)
--
-- 期间锁显式设 NULL(README 第 5 条)。自带数据(第 2 条)。汇率自己插(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    u_view uuid := gen_random_uuid();   -- 只有 module.sales.view
    r_all uuid; r_view uuid;
    v_cust uuid; v_lim uuid; v_mat uuid; v_ccy text;
    so1 uuid; so2 uuid; soL uuid;
    L1 uuid; L2 uuid; LP uuid; LL uuid;
    ob1 uuid; ob2 uuid; obP uuid; obL uuid;
    res1 uuid; res2 uuid; resP uuid; resL uuid; v_res_left uuid;
    inv1 jsonb; inv2 jsonb; invL jsonb; v_inv_id uuid;
    shp jsonb; shp2 jsonb;
    v_n int; v_n0 int; v_exp0 numeric; v_exp1 numeric; v_amt numeric;
    v_sale uuid; v_msg text; v_pay jsonb; v_ok boolean;
    v_sup uuid; v_ib uuid; v_run uuid; v_matK uuid; obK uuid;
    soK uuid; LK uuid; resK uuid; v_cogs_entry uuid; v_cogs_amt numeric;
    d date := CURRENT_DATE;
    FX constant numeric := 1.25;       -- 订单/发票存下来的入账汇率(非 1,刻意)
    BANK_FX constant numeric := 1.30;  -- 结算日 tt_buy
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-68', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-68-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_view, r_view);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    UPDATE fx_rates SET deleted_at = now()
     WHERE currency = 'USD' AND rate_date = d AND rate_type = 'tt_buy' AND deleted_at IS NULL;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', d, 'tt_buy', BANK_FX);

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ68-C1', 'fixture 68 customer', 'SG') RETURNING id INTO v_cust;
    -- 限额客户:限额 1,已经没有余地 —— 用来证明【发货不查信用】
    INSERT INTO customers (code, legal_name, country, credit_limit_base)
    VALUES ('ZZ68-C2', 'fixture 68 limited', 'SG', 1) RETURNING id INTO v_lim;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX68-M', 'f68 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    ob1  := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob2  := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    obP  := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    obL  := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;

    -- 订单一(USD @ 1.25):行1 40×10 = 400 USD;行2(部分发货用)20×10 = 200 USD
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO so1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so1, 1, v_mat, 40, 10) RETURNING id INTO L1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so1, 2, v_mat, 20, 10) RETURNING id INTO L2;
    PERFORM set_sales_order_status(so1, 'confirmed');

    -- ══════════ A. 前提 + 目录 ═══════════════════════════════════════════════
    IF to_regclass('public.shipments') IS NULL OR to_regclass('public.shipment_lines') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 68A 失败:发货两表不在';
    END IF;
    -- 活预留的判据【必须是两个条件】—— 少一个,已发的预留会被当成还活着。
    -- 【SO-3b fu5 起,这一句问的位置变了,而且它此前问错了地方】原文查的是
    -- reserve_stock 的函数体里有没有 'consumed_at IS NULL',并写着"否则发过的
    -- 货还能再发一次"。那个字符串当时【确实在】那里 —— 而双重发货照样成立,
    -- 因为缺陷正好相反:天花板把已消耗的预留排除得太干净,连它们代表的【已发】
    -- 也一起丢了(实测:12 的行发出 24)。判据现在住在 line_spoken_for 里,
    -- 这一句跟着搬过去;fixture 69 才是这条行为的正主(本臂只做目录)。
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'line_spoken_for') NOT LIKE '%consumed_at IS NULL%' THEN
        RAISE EXCEPTION 'FIXTURE 68A 失败:line_spoken_for 没有把【已消耗】排除在活预留那一半之外';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'reserve_stock') NOT LIKE '%line_spoken_for(%' THEN
        RAISE EXCEPTION 'FIXTURE 68A 失败:reserve_stock 的行天花板没有读 line_spoken_for';
    END IF;
    -- AR 静默那条谓词在不在(G 臂靠拿掉它证明;这里先证明它现在【在】)
    IF pg_get_viewdef('public.ar_open_items'::regclass) NOT LIKE '%sales_order_line_id IS NULL%' THEN
        RAISE EXCEPTION 'FIXTURE 68A 失败:ar_open_items 第一支没有排除订单流发货产生的销售记录';
    END IF;

    -- ══════════ B. 全量发货 ══════════════════════════════════════════════════
    PERFORM reserve_stock(L1, ob1, 40);
    SELECT id INTO res1 FROM sales_order_reservations
     WHERE sales_order_line_id = L1 AND released_at IS NULL AND consumed_at IS NULL;
    inv1 := create_order_invoice(so1, d, NULL, NULL, NULL, ARRAY[L1]);

    -- 发货前:账龄行数与敞口(C 臂的基线)
    SELECT count(*) INTO v_n0 FROM ar_open_items;
    SELECT customer_ar_exposure_base(v_cust) INTO v_exp0;

    shp := ship_order(so1, d, jsonb_build_array(jsonb_build_object('reservation_id', res1)));

    -- 出库腿:从 committed 出,数量对,业务日是发货日
    SELECT count(*) INTO v_n FROM inventory_movements
     WHERE output_batch_id = ob1 AND movement_type = 'sale'
       AND stock_status = 'committed' AND qty_delta = -40 AND business_date = d;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 68B 失败:应当从 committed 桶写出一条 -40 的 sale 腿,实得 %', v_n;
    END IF;
    -- 桶空了(committed 与 available 都不该再有这 40)
    IF derived_stock_qty(NULL, ob1, NULL, 'committed') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 68B 失败:发完之后 committed 应当归零,实得 %',
            derived_stock_qty(NULL, ob1, NULL, 'committed');
    END IF;
    -- 腿表(SO-2b 的形状)
    SELECT count(*) INTO v_n FROM sales_record_movements srm
      JOIN sales_records sr ON sr.id = srm.sales_record_id
     WHERE sr.output_batch_id = ob1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 68B 失败:腿表应当有一行,实得 %', v_n;
    END IF;
    -- 物理缓存与 state(与 record_output_sale 同一套)
    SELECT remaining_qty INTO v_amt FROM output_batches WHERE id = ob1;
    IF v_amt <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 68B 失败:remaining_qty 应当是 60,实得 %', v_amt;
    END IF;
    IF (SELECT state FROM output_batches WHERE id = ob1) <> '部分售出' THEN
        RAISE EXCEPTION 'FIXTURE 68B 失败:state 应当变成【部分售出】';
    END IF;
    -- 收入:借 2500 / 贷 4000,400 USD @ 1.25
    SELECT count(*) INTO v_n
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
      JOIN journal_entries je ON je.id = l.entry_id
     WHERE je.code = shp->>'revenue_journal' AND je.source_type = 'shipment'
       AND ((a.code = '2500' AND l.debit > 0) OR (a.code = '4000' AND l.credit > 0))
       AND l.currency = 'USD' AND l.amount_ccy = 400 AND l.fx_rate = FX;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 68B 失败:发货分录应当是 借2500/贷4000,USD 400 @ 1.25,实得 % 行合格', v_n;
    END IF;
    -- 这张单只发了行1 → partially_shipped
    IF (SELECT status FROM sales_orders WHERE id = so1) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 68B 失败:只发了一行的单应当是 partially_shipped,实得 %',
            (SELECT status FROM sales_orders WHERE id = so1);
    END IF;

    -- ══════════ C. 【AR 静默】—— 这份 fixture 的心脏 ═════════════════════════
    SELECT count(*) INTO v_n FROM ar_open_items;
    IF v_n <> v_n0 THEN
        RAISE EXCEPTION 'FIXTURE 68C 失败:发货【不该】新增任何应收行(那笔债在开票当刻已经记过),行数 % → %', v_n0, v_n;
    END IF;
    SELECT customer_ar_exposure_base(v_cust) INTO v_exp1;
    IF v_exp1 <> v_exp0 THEN
        RAISE EXCEPTION 'FIXTURE 68C 失败:发货【不该】改变敞口(开票时就认下了),% → %', v_exp0, v_exp1;
    END IF;
    -- 标记确实写了(否则上面两条会因为"根本没生成销售记录"而空转通过)
    SELECT count(*) INTO v_n FROM sales_records
     WHERE output_batch_id = ob1 AND sales_order_line_id = L1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 68C 前提失败:发货应当生成一条【带标记】的销售记录,实得 % —— 否则 AR 静默的断言是空转的', v_n;
    END IF;
    -- 这一行【留在"未挂 COGS"那一堆里】等补挂。
    -- 【注意这一条断言的是数据的形状,不是补挂真的看得见它】—— 它把
    -- allocate_processing_costs 的读法在这里抄了一遍,而两份实现今天一致
    -- 不等于将来一致。真正跑一遍补挂、看它给这一行挂上 COGS 的,是 K 臂。
    SELECT count(*) INTO v_n FROM sales_records
     WHERE output_batch_id = ob1 AND cogs_entry_id IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 68C 失败:这批货没有单位成本,所以这一行应当留在【未挂 COGS】那一堆里等补挂,实得 %', v_n;
    END IF;

    -- ══════════ D. 信用:发货不查,直接销售仍查(两个方向)═════════════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_lim, d, v_ccy, 1) RETURNING id INTO soL;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soL, 1, v_mat, 10, 10) RETURNING id INTO LL;
    PERFORM set_sales_order_status(soL, 'confirmed');
    PERFORM reserve_stock(LL, obL, 10);
    SELECT id INTO resL FROM sales_order_reservations
     WHERE sales_order_line_id = LL AND released_at IS NULL AND consumed_at IS NULL;
    -- 开票会撞限额(1),所以先把限额放开、开票、再把限额收回来 ——
    -- 我们要测的是【发货】不查,而不是开票不查。
    UPDATE customers SET credit_limit_base = NULL WHERE id = v_lim;
    invL := create_order_invoice(soL, d, NULL, NULL, NULL, ARRAY[LL]);
    UPDATE customers SET credit_limit_base = 1 WHERE id = v_lim;
    -- 发货:限额只有 1,敞口远超 —— 但【发货不查信用】,必须通过
    PERFORM ship_order(soL, d, jsonb_build_array(jsonb_build_object('reservation_id', resL)));
    -- 另一个方向:同一个超限客户,【直接销售】仍然被拒
    BEGIN
        PERFORM record_output_sale(obL, 1, 10, v_ccy, NULL, v_lim, d, NULL);
        RAISE EXCEPTION 'FIXTURE 68D 失败:直接销售对超限客户【应当】仍然被拒 —— 发货不查信用不等于信用闸被拆了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'CREDIT_LIMIT_EXCEEDED%' THEN RAISE; END IF;
    END;

    -- ══════════ E. 部分发货 ══════════════════════════════════════════════════
    PERFORM reserve_stock(L2, obP, 20);
    SELECT id INTO resP FROM sales_order_reservations
     WHERE sales_order_line_id = L2 AND released_at IS NULL AND consumed_at IS NULL;
    PERFORM create_order_invoice(so1, d, NULL, NULL, NULL, ARRAY[L2]);
    -- 只发 12(预留 20)
    shp2 := ship_order(so1, d, jsonb_build_array(
        jsonb_build_object('reservation_id', resP, 'qty', 12)));
    -- 负债按比例释放:12 × 10 = 120 USD
    SELECT count(*) INTO v_n
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
      JOIN journal_entries je ON je.id = l.entry_id
     WHERE je.code = shp2->>'revenue_journal' AND a.code = '2500'
       AND l.debit > 0 AND l.amount_ccy = 120;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 68E 失败:部分发货应当只释放 120 USD 的负债';
    END IF;
    -- 剩余【按行数】数:拆分是"整笔释放 + 重新预留",不是把 qty 改小 ——
    -- 一个改 qty 的实现在数字上一样,只有行数分得出来。
    SELECT count(*) INTO v_n FROM sales_order_reservations WHERE sales_order_line_id = L2;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 68E 失败:L2 上应当留下两行事实(原 20 已释放、新 12 已消耗),实得 %', v_n;
    END IF;
    SELECT COALESCE(sum(qty), 0) INTO v_amt FROM sales_order_reservations
     WHERE sales_order_line_id = L2 AND consumed_at IS NOT NULL;
    IF v_amt <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 68E 失败:被消耗掉的那条预留应当正好是 12,实得 %', v_amt;
    END IF;
    -- 订单仍是 partially_shipped(行2 还差 8)
    IF (SELECT status FROM sales_orders WHERE id = so1) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 68E 失败:还差 8 没发,应当仍是 partially_shipped';
    END IF;
    -- 再发剩下的 8 → 整单发完 → shipped
    PERFORM reserve_stock(L2, obP, 8);
    SELECT id INTO v_res_left FROM sales_order_reservations
     WHERE sales_order_line_id = L2 AND released_at IS NULL AND consumed_at IS NULL;
    PERFORM ship_order(so1, d, jsonb_build_array(jsonb_build_object('reservation_id', v_res_left)));
    IF (SELECT status FROM sales_orders WHERE id = so1) <> 'shipped' THEN
        RAISE EXCEPTION 'FIXTURE 68E 失败:两行都发完之后应当是 shipped,实得 %',
            (SELECT status FROM sales_orders WHERE id = so1);
    END IF;

    -- ══════════ F. 拒绝面 ════════════════════════════════════════════════════
    -- 未开票的行发不了
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO so2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so2, 1, v_mat, 10, 10) RETURNING id INTO LP;
    PERFORM set_sales_order_status(so2, 'confirmed');
    PERFORM reserve_stock(LP, ob2, 10);
    SELECT id INTO res2 FROM sales_order_reservations
     WHERE sales_order_line_id = LP AND released_at IS NULL AND consumed_at IS NULL;
    BEGIN
        PERFORM ship_order(so2, d, jsonb_build_array(jsonb_build_object('reservation_id', res2)));
        RAISE EXCEPTION 'FIXTURE 68F 失败:没开票的行不该发得出去';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_SHIP_NOT_INVOICED%' THEN RAISE; END IF;
    END;
    -- 正向对照:开了票就发得出去
    inv2 := create_order_invoice(so2, d, NULL, NULL, NULL, ARRAY[LP]);
    v_inv_id := (inv2->>'invoice_id')::uuid;
    -- 未预留 / 不属于本单的预留
    BEGIN
        PERFORM ship_order(so2, d, jsonb_build_array(jsonb_build_object('reservation_id', gen_random_uuid())));
        RAISE EXCEPTION 'FIXTURE 68F 失败:不存在的预留不该发得出去';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_SHIP_NOT_RESERVED%' THEN RAISE; END IF;
    END;
    -- 超预留
    BEGIN
        PERFORM ship_order(so2, d, jsonb_build_array(
            jsonb_build_object('reservation_id', res2, 'qty', 11)));
        RAISE EXCEPTION 'FIXTURE 68F 失败:超过预留量的发货不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_SHIP_EXCEEDS_RESERVATION%' THEN RAISE; END IF;
    END;
    PERFORM ship_order(so2, d, jsonb_build_array(jsonb_build_object('reservation_id', res2)));
    -- 【3a 停放的那条检查在这里落地】发过货的票作废不了
    BEGIN
        PERFORM void_invoice(v_inv_id, 'try after ship', d);
        RAISE EXCEPTION 'FIXTURE 68F 失败:已经有货按它发出的发票不该作废得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'INVOICE_SHIPPED_NOT_VOIDABLE%' THEN RAISE; END IF;
    END;
    -- 已发的预留放不回来
    BEGIN
        PERFORM release_reservation(res2, NULL, 'try after ship');
        RAISE EXCEPTION 'FIXTURE 68F 失败:已经发出去的预留不该释放得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVATION_ALREADY_SHIPPED%' THEN RAISE; END IF;
    END;

    -- ══════════ H. 端到端:2500 归零、1100 结清(非 1 汇率)═════════════════════
    -- so2 这张单:开票 400... 实际 10×10=100 USD;发货已做。现在收款结清。
    SELECT (SELECT COALESCE(sum(l.credit - l.debit), 0)
              FROM journal_lines l JOIN accounts a ON a.id = l.account_id
              JOIN journal_entries je ON je.id = l.entry_id
             WHERE a.code = '2500' AND je.source_id IN (v_inv_id)) INTO v_amt;
    -- 开票贷 2500 100 USD @1.25 = 125;发货借 2500 同额 → 这张票的负债净额 0
    v_pay := record_payment('in', v_cust, 100, 'USD', NULL, '1010', d, NULL,
        jsonb_build_array(jsonb_build_object('invoice_id', v_inv_id, 'amount_doc', 100)));
    -- 这张发票不再挂在账龄上
    SELECT count(*) INTO v_n FROM ar_open_items WHERE invoice_id = v_inv_id;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 68H 失败:收款之后这张发票不该还挂在应收上,实得 %', v_n;
    END IF;
    -- 2500 在这张单的整条链上净额为零(开票贷、发货借)
    SELECT COALESCE(sum(l.debit - l.credit), 0) INTO v_amt
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
      JOIN journal_entries je ON je.id = l.entry_id
     WHERE a.code = '2500'
       AND je.id IN (SELECT entry_id FROM invoices WHERE id = v_inv_id
                     UNION ALL
                     SELECT je2.id FROM journal_entries je2
                      JOIN shipments s ON s.id = je2.source_id
                     WHERE s.sales_order_id = so2 AND je2.source_type = 'shipment');
    IF v_amt <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 68H 失败:开票 → 发货之后,这张单的 2500 应当精确归零,实得 %', v_amt;
    END IF;
    -- 收入落在 4000 上(单据币种 100 USD → 本位币 125)
    SELECT COALESCE(sum(l.credit), 0) INTO v_amt
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
      JOIN journal_entries je ON je.id = l.entry_id
      JOIN shipments s ON s.id = je.source_id
     WHERE a.code = '4000' AND je.source_type = 'shipment' AND s.sales_order_id = so2;
    IF v_amt <> round(100 * FX, 2) THEN
        RAISE EXCEPTION 'FIXTURE 68H 失败:4000 上的本位币收入应当是 %(=100×1.25),实得 %',
            round(100 * FX, 2), v_amt;
    END IF;

    -- ══════════ I. 角色 ══════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_view), true);
    BEGIN
        PERFORM ship_order(so2, d, jsonb_build_array(jsonb_build_object('reservation_id', res2)));
        RAISE EXCEPTION 'FIXTURE 68I 失败:只有 sales.view 的人不该发得了货';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'PERMISSION_DENIED%' THEN RAISE; END IF;
    END;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ K. COGS 补挂【真的跑一遍】,看它挂上发货产生的那一行 ═════════
    -- 【为什么这一臂必须存在】C 臂只断言"这一行留在未挂 COGS 那一堆里",而它
    -- 得出这个结论的方式是把 allocate_processing_costs 的读法【抄了一遍】——
    -- 两份实现今天一致,不等于将来一致。这一臂不抄:它建一炉真的加工单、
    -- 让产出批走完订单流发出去、然后【调用补挂本身】,再看那一行有没有被挂上。
    -- 补挂读的是 sales_records(按 output_batch_id,按 cogs_entry_id 是否为空
    -- 分两堆),而发货产生的正是一条普通的 sales_records —— 这一臂就是那句
    -- "所以它自然看得见"的证明。
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ68-S1', 'fixture 68 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX68-K', 'f68 processed', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_matK;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ68-IB', v_mat, v_sup, 50, 50, 'kg', d) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 2, v_ccy, NULL, 'fixture 68 K price');
    -- 全部投进一炉,产出 50kg —— 单位成本 = 100 / 50 = 2/kg
    -- PROC-3:这一支要投料,所以它的电池料批次得带一条【可投料】的安全状态。
    -- 【为什么是一条带 JOIN 的 SELECT,而不是逐个批次写死】本支里哪些批次【吃】
    -- 状态轴,由 material_kinds 回答 —— 实测 ewaste 可加工却【没有】状态轴,
    -- 所以"可加工"并不蕴含"有状态轴"。而没有状态轴的批次插安全状态会被
    -- PROC-2c 的适用性守卫按名拒,所以这个过滤不是优化,是正确性。
    -- 【它出现在每一次投料之前,而不是只在开头一次】批次是各臂【边跑边造】的,
    -- 开头那一次覆盖不到后面才出生的批次。NOT EXISTS 让它重复执行也不撞主键。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run := commit_processing_run(d, 'fixture 68 K run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', v_matK, 'quantity', 50)), 'weight');
    SELECT po.output_batch_id INTO obK FROM processing_outputs po WHERE po.run_id = v_run LIMIT 1;

    -- 【故意先发货、后分摊】—— 补挂存在的全部理由就是这个顺序:发货当刻
    -- 那批货还没有单位成本,COGS 挂不上;分摊之后才补。
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_ccy, 1) RETURNING id INTO soK;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soK, 1, v_matK, 20, 10) RETURNING id INTO LK;
    PERFORM set_sales_order_status(soK, 'confirmed');
    PERFORM reserve_stock(LK, obK, 20);
    SELECT id INTO resK FROM sales_order_reservations
     WHERE sales_order_line_id = LK AND released_at IS NULL AND consumed_at IS NULL;
    PERFORM create_order_invoice(soK, d, NULL, NULL, NULL, ARRAY[LK]);
    PERFORM ship_order(soK, d, jsonb_build_array(jsonb_build_object('reservation_id', resK)));

    -- 发货当刻:没有单位成本 ⇒ 这一行没有 COGS(前提;否则下面的断言空转)
    SELECT cogs_entry_id INTO v_cogs_entry FROM sales_records
     WHERE output_batch_id = obK AND sales_order_line_id = LK;
    IF v_cogs_entry IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 68K 前提失败:分摊之前这批货不该有单位成本,COGS 不该挂得上 —— 否则本臂在空转';
    END IF;

    -- 【跑补挂本身】
    PERFORM allocate_processing_costs(v_run, 'weight');

    SELECT cogs_entry_id INTO v_cogs_entry FROM sales_records
     WHERE output_batch_id = obK AND sales_order_line_id = LK;
    IF v_cogs_entry IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 68K 失败:补挂【没有看见】发货产生的那一行 —— 订单流的销售记录必须与直接销售的一样被补挂 COGS';
    END IF;
    -- 金额:20kg × 单位成本 2 = 40(借 5000 / 贷 1220 那一对里 5000 的借方)
    SELECT COALESCE(sum(l.debit), 0) INTO v_cogs_amt
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = v_cogs_entry AND a.code = '5000';
    IF v_cogs_amt <> 40 THEN
        RAISE EXCEPTION 'FIXTURE 68K 失败:补挂的 COGS 应当是 40(=20kg × 单位成本 2),实得 %', v_cogs_amt;
    END IF;

    -- ══════════ J. closed 只能从 shipped 来,而且是终态 ═══════════════════════
    -- 【fixture 63 把这一条让给了这里】只有走到 shipped 才谈得上"走完了",
    -- 而 63 里没有发货装置。so1 在 E 臂结束时已经是 shipped。
    PERFORM set_sales_order_status(so1, 'closed');
    IF (SELECT status FROM sales_orders WHERE id = so1) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 68J 失败:shipped → closed 应当允许';
    END IF;
    BEGIN
        PERFORM set_sales_order_status(so1, 'cancelled', 'x');
        RAISE EXCEPTION 'FIXTURE 68J 失败:closed 是终态,不该还能去 cancelled';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_TRANSITION_NOT_ALLOWED|closed|%' THEN RAISE; END IF;
    END;
    -- partially_shipped 没有任何手动去处(发出去的货收不回来)
    BEGIN
        PERFORM set_sales_order_status(so2, 'cancelled', 'x');
        RAISE EXCEPTION 'FIXTURE 68J 失败:发过货的单不该作废得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_TRANSITION_NOT_ALLOWED|%' THEN RAISE; END IF;
    END;

    -- ══════════ G(收尾跑). 注入:拿掉 AR 静默那条谓词 → 账龄当场多一行 ════════
    -- 【为什么排在最后】它把视图改坏,后面每一条读账龄的断言都会跟着不准;
    -- 整段回滚,所以放在所有断言之后(fixture 67 D 臂同一个理由)。
    SELECT count(*) INTO v_n0 FROM ar_open_items;
    EXECUTE 'CREATE OR REPLACE VIEW public.ar_open_items WITH (security_invoker = off) AS ' ||
        replace(pg_get_viewdef('public.ar_open_items'::regclass),
                'AND (sr.sales_order_line_id IS NULL)', 'AND true');
    SELECT count(*) INTO v_n FROM ar_open_items;
    IF v_n <= v_n0 THEN
        RAISE EXCEPTION 'FIXTURE 68G 失败:拿掉 AR 静默那条谓词之后,账龄【没有】多出行(% → %)—— 说明 C 臂一直在空转,那些发货产生的销售记录本来就进不了应收', v_n0, v_n;
    END IF;
END $$;
ROLLBACK;
