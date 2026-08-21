-- 67 订单流开票(SO-3a):发票过账、敞口跟着走,而【面板与闸是同一个数】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的五件事】
--   ① 订单流发票【过账】:借 1100 / 贷 2500,单据币种,按【订单存下来的】汇率
--      (非 1 的汇率 —— 两边一致时断言什么都证明不了,INV-1 的老课)。
--      entry_id 回写、kind 一致性、直接销售那条路一个字不变(现有 fixture 管)。
--   ② 一条订单行只能挂在一张在册发票上,而挡住它的是【索引】——
--      注入证明:拿掉友好检查仍被 unique_violation 拒;再拿掉索引,重复开票
--      当场通过。两层各自证明。
--   ③ 敞口包含已过账未结清的订单发票,且【面板与闸读同一处推导】——
--      目录断言:ar_open_items 与 customer_ar_exposure_base 都引用
--      order_invoice_open_all;行为断言:开票后 exposure 恰好涨 open_base。
--   ④ 收款核销直指发票,按【存下来的】汇率解除 —— 已实现汇兑(7100)
--      = (结算日牌价 − 存下来的汇率) × 金额,数字亲手算。
--   ⑤ 作废是一次【冲销】:分录对冲、余额归零、行重新可开;有活核销按名拒。
--
-- 各臂:
--   A 前提 + 目录(2500 的四个旗子;source_type 认 'invoice';两个消费者引用内层视图)
--   B 开票:JE 两行两边、金额与汇率、entry_id、行、历史、发票头一致性
--   C 拒绝面:草稿单、日期空、行子集混入外单行、重复开票(友好检查)
--   D 注入:友好检查拿掉 → 索引拒;索引拿掉 → 通过(证明 ② 的两层)
--   E 信用:超限按名拒(消息四个数);面板=闸(行为:exposure 恰好涨 open_base)
--   F 应收账龄:第二支出现、kind 判别、按 issue_date 计龄;两支不相交
--   G 收款:核销直指发票、发票结清、7100 = 亲手算的差额
--   H 作废:有活核销拒;冲收款后作废通过、分录对冲、余额归零、行可再开;
--      sale 头传冲销日按名拒
--   I 角色:无 finance.view 读不到第二支(缺席,不是零)
--
-- 期间锁显式设 NULL(README 第 5 条)。自带数据(第 2 条)。汇率自己插(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    u_nofin uuid := gen_random_uuid();   -- 只有 module.sales.view(没有 finance)
    r_all uuid; r_nofin uuid;
    v_cust uuid; v_cust2 uuid; v_mat uuid; v_ccy text;
    so1 uuid; so2 uuid; so3 uuid; L1 uuid; L2 uuid; L3 uuid; LX uuid;
    inv jsonb; inv_id uuid; inv_code text; je_id uuid; rev_code text;
    v_n int; v_amt numeric; v_exp0 numeric; v_exp1 numeric; v_open numeric;
    v_pay jsonb; v_msg text; v_ok boolean;
    d date := CURRENT_DATE;
    FX constant numeric := 1.25;    -- 订单存下来的入账汇率(非 1,刻意)
    BANK_FX constant numeric := 1.30;  -- 结算日 tt_buy(与入账汇率不同,刻意)
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-67', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-67-nofin', 'f', 'f', true) RETURNING id INTO r_nofin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_nofin, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_nofin, r_nofin);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;

    -- 结算日的 USD 牌价(README 第 4 条:要什么自己插;部分唯一索引做冲突目标)
    -- 已有今天的行就软删掉再插(整段回滚,不影响任何人)—— 比部分唯一索引的
    -- ON CONFLICT 目标写法可靠。
    UPDATE fx_rates SET deleted_at = now()
     WHERE currency = 'USD' AND rate_date = d AND rate_type = 'tt_buy' AND deleted_at IS NULL;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', d, 'tt_buy', BANK_FX);

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ67-C1', 'fixture 67 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO customers (code, legal_name, country, credit_limit_base)
    VALUES ('ZZ67-C2', 'fixture 67 limited', 'SG', 1000) RETURNING id INTO v_cust2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZFIX67-M', 'f67 material', 'battery_material', true, 'kg') RETURNING id INTO v_mat;

    -- 订单一:USD @ 1.25,两行(100×5 + 60×5 = 800 USD)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO so1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so1, 1, v_mat, 100, 5) RETURNING id INTO L1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so1, 2, v_mat, 60, 5) RETURNING id INTO L2;
    PERFORM set_sales_order_status(so1, 'confirmed');

    -- 订单二:草稿(拒绝面用)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO so2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so2, 1, v_mat, 10, 5) RETURNING id INTO LX;

    -- 订单三:限额客户(信用臂用),本位币,1200 > 限额 1000
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust2, d, v_ccy, 1) RETURNING id INTO so3;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so3, 1, v_mat, 120, 10) RETURNING id INTO L3;
    PERFORM set_sales_order_status(so3, 'confirmed');

    -- ══════════ A. 前提 + 目录 ═══════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM accounts
     WHERE code = '2500' AND account_type = 'liability' AND is_system
       AND NOT is_monetary AND NOT is_cash AND cash_flow_section IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 67A 失败:2500 必须是 liability + is_system + 非货币 + 非现金 + 无现金流量段(四个旗子都是决定,不是默认)';
    END IF;
    -- 【面板与闸读同一处】—— 目录断言:两个消费者都引用 order_invoice_open_all。
    -- 将来有人把推导抄回某一边,这一条当场红,不等两边的数字漂开才被人发现。
    IF pg_get_viewdef('public.ar_open_items'::regclass) NOT LIKE '%order_invoice_open_all%' THEN
        RAISE EXCEPTION 'FIXTURE 67A 失败:ar_open_items 不再引用 order_invoice_open_all —— 账龄与敞口从此各说各话';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'customer_ar_exposure_base') NOT LIKE '%order_invoice_open_all%' THEN
        RAISE EXCEPTION 'FIXTURE 67A 失败:customer_ar_exposure_base 不再引用 order_invoice_open_all';
    END IF;
    -- 内层视图对 authenticated 不可读(不带门,读得到就是绕过门)
    IF has_table_privilege('authenticated', 'public.order_invoice_open_all', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 67A 失败:order_invoice_open_all 不该对 authenticated 可读';
    END IF;

    -- ══════════ B. 开票:过账、金额、汇率、回写 ═══════════════════════════════
    SELECT customer_ar_exposure_base(v_cust) INTO v_exp0;
    inv := create_order_invoice(so1, d);
    inv_id := (inv->>'invoice_id')::uuid;
    inv_code := inv->>'code';

    SELECT i.entry_id INTO je_id FROM invoices i
     WHERE i.id = inv_id AND i.kind = 'order' AND i.sales_order_id = so1
       AND i.fx_rate = FX AND i.currency = 'USD' AND i.status = 'issued';
    IF je_id IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 67B 失败:发票头不完整(kind/订单/汇率/币种/entry_id 有一样不对)';
    END IF;

    -- JE:恰两行 —— 借 1100 / 贷 2500,原币 800 USD,汇率 = 存下来的 1.25
    SELECT count(*) INTO v_n FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = je_id
       AND ((a.code = '1100' AND l.debit > 0) OR (a.code = '2500' AND l.credit > 0))
       AND l.currency = 'USD' AND l.amount_ccy = 800 AND l.fx_rate = FX;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 67B 失败:开票分录应当恰好两行(借 1100 / 贷 2500,USD 800 @ 1.25),实得 % 行合格', v_n;
    END IF;
    SELECT source_type INTO v_msg FROM journal_entries WHERE id = je_id;
    IF v_msg <> 'invoice' THEN
        RAISE EXCEPTION 'FIXTURE 67B 失败:开票分录的 source_type 应当是 invoice,实得 %', v_msg;
    END IF;
    -- 行:两行,各指订单行,金额生成列 500/300
    SELECT count(*) INTO v_n FROM invoice_lines il
     WHERE il.invoice_id = inv_id AND il.sales_record_id IS NULL
       AND il.sales_order_line_id IN (L1, L2);
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 67B 失败:应当写出两行、各指订单行、不指销售记录,实得 %', v_n;
    END IF;
    -- 历史
    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = so1 AND change_type = 'invoiced' AND detail = inv_code;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 67B 失败:开票要进订单历史(invoiced),实得 %', v_n;
    END IF;

    -- ══════════ C. 拒绝面(各按名 + 正向对照已在 B)═══════════════════════════
    BEGIN
        PERFORM create_order_invoice(so2, d);
        RAISE EXCEPTION 'FIXTURE 67C 失败:草稿单不该开得出票';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_INVOICE_ORDER_NOT_CONFIRMED%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM create_order_invoice(so1, NULL);
        RAISE EXCEPTION 'FIXTURE 67C 失败:开票日空着不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'INVOICE_DATE_REQUIRED%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM create_order_invoice(so3, d, NULL, NULL, NULL, ARRAY[LX]);  -- LX 是别的单的行
        RAISE EXCEPTION 'FIXTURE 67C 失败:混进外单行的子集不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_INVOICE_LINE_INVALID%' THEN RAISE; END IF;
    END;
    -- 重复开票:全部行都已开 → NOTHING_TO_BILL;点名开已开的行 → ALREADY
    BEGIN
        PERFORM create_order_invoice(so1, d);
        RAISE EXCEPTION 'FIXTURE 67C 失败:整单已开,不该还有可开的东西';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_INVOICE_NOTHING_TO_BILL%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM create_order_invoice(so1, d, NULL, NULL, NULL, ARRAY[L1]);
        RAISE EXCEPTION 'FIXTURE 67C 失败:点名开已开的行不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_LINE_ALREADY_INVOICED%' THEN RAISE; END IF;
    END;

    -- ══════════ E. 信用:闸按名拒,面板与闸同一个数 ═══════════════════════════
    -- so3:1200 > 限额 1000 → 拒,消息四个数
    BEGIN
        PERFORM create_order_invoice(so3, d);
        RAISE EXCEPTION 'FIXTURE 67E 失败:超限的订单发票不该过账';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'CREDIT_LIMIT_EXCEEDED%' THEN RAISE; END IF;
        IF split_part(v_msg, '|', 2) <> 'ZZ67-C2' OR split_part(v_msg, '|', 5)::numeric <> 1200 THEN
            RAISE EXCEPTION 'FIXTURE 67E 失败:拒绝要说全四个数(客户/限额/敞口/本票),实得 %', v_msg;
        END IF;
    END;
    -- 敞口的行为断言:开票后恰好涨 open_base(= 800 × 1.25 = 1000)
    SELECT customer_ar_exposure_base(v_cust) INTO v_exp1;
    IF v_exp1 - v_exp0 <> round(800 * FX, 2) THEN
        RAISE EXCEPTION 'FIXTURE 67E 失败:开票后敞口应当恰好涨 %(= 800 × 1.25),实涨 %',
            round(800 * FX, 2), v_exp1 - v_exp0;
    END IF;

    -- ══════════ F. 应收账龄:第二支、判别、计龄、不相交 ═══════════════════════
    SELECT count(*) INTO v_n FROM ar_open_items
     WHERE doc_kind = 'invoice' AND invoice_id = inv_id AND sales_record_id IS NULL
       AND doc_code = inv_code AND open_ccy = 800 AND open_base = round(800 * FX, 2)
       AND days_outstanding = 0;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 67F 失败:账龄里应当有恰好一行订单发票(open 800 / % / 按 issue_date 计龄),实得 %',
            round(800 * FX, 2), v_n;
    END IF;
    -- 不相交:这张发票不以 sale 支出现
    SELECT count(*) INTO v_n FROM ar_open_items WHERE doc_kind = 'sale' AND invoice_id = inv_id;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 67F 失败:同一笔债在 sale 支里又出现了 % 次 —— 两支必须按构造不相交', v_n;
    END IF;

    -- ══════════ G. 收款:核销直指发票,7100 按存下来的汇率算 ══════════════════
    -- 收 USD 800,当日 tt_buy 1.30 → 银行借方 1040;贷 1100 按存的 1.25 → 1000;
    -- 差 40 是【已实现汇兑收益】(贷 7100)。数字亲手算,两率不同所以这条臂
    -- 不可能靠"两边一致"混过(INV-1 的老课)。
    v_pay := record_payment('in', v_cust, 800, 'USD', NULL, '1010', d, NULL,
        jsonb_build_array(jsonb_build_object('invoice_id', inv_id, 'amount_doc', 800)));
    SELECT count(*) INTO v_n
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
      JOIN journal_entries je ON je.id = l.entry_id
     WHERE je.code = v_pay->>'journal_code' AND a.code = '7100'
       AND l.credit = round(800 * (BANK_FX - FX), 2);
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 67G 失败:已实现汇兑应当是贷 7100 恰好 %(=800×(1.30−1.25)),没找到',
            round(800 * (BANK_FX - FX), 2);
    END IF;
    -- 发票结清:账龄第二支消失、invoice_status 读作已付
    SELECT count(*) INTO v_n FROM ar_open_items WHERE invoice_id = inv_id AND doc_kind = 'invoice';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 67G 失败:结清后的发票不该还挂在账龄上,实得 %', v_n;
    END IF;
    SELECT payment_state INTO v_msg FROM invoice_status WHERE invoice_id = inv_id;
    IF v_msg <> 'paid' THEN
        RAISE EXCEPTION 'FIXTURE 67G 失败:invoice_status 应当读作 paid(order 头走发票自己的核销行),实得 %', v_msg;
    END IF;
    -- 敞口回到起点
    SELECT customer_ar_exposure_base(v_cust) INTO v_exp1;
    IF v_exp1 <> v_exp0 THEN
        RAISE EXCEPTION 'FIXTURE 67G 失败:结清后敞口应当回到 %,实得 %', v_exp0, v_exp1;
    END IF;

    -- ══════════ H. 作废 ═════════════════════════════════════════════════════
    -- 有活核销 → 按名拒(先冲收款)
    BEGIN
        PERFORM void_invoice(inv_id, 'fixture 67 void attempt', d);
        RAISE EXCEPTION 'FIXTURE 67H 失败:有活核销的发票不该作废得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'INVOICE_HAS_SETTLEMENTS%' THEN RAISE; END IF;
    END;
    -- 冲掉收款 → 作废通过,分录对冲,行可再开
    PERFORM reverse_payment((v_pay->>'payment_id')::uuid, 'fixture 67');
    PERFORM void_invoice(inv_id, 'fixture 67 void', d);
    SELECT je.status, rev.code INTO v_msg, rev_code
      FROM journal_entries je LEFT JOIN journal_entries rev ON rev.id = je.reversed_by
     WHERE je.id = je_id;
    IF v_msg <> 'reversed' OR rev_code IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 67H 失败:作废应当把开票分录冲销掉(status=reversed 且有冲销凭证),实得 % / %', v_msg, rev_code;
    END IF;
    -- 余额归零:1100 与 2500 在这张票一开一冲之后净额为 0(只看这两张分录)
    SELECT COALESCE(sum(l.debit - l.credit), 0) INTO v_amt
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE a.code IN ('1100', '2500')
       AND l.entry_id IN (je_id, (SELECT id FROM journal_entries WHERE code = rev_code));
    IF v_amt <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 67H 失败:一开一冲之后 1100+2500 的净额应当归零,实得 %', v_amt;
    END IF;
    -- 敞口不再含它
    SELECT customer_ar_exposure_base(v_cust) INTO v_exp1;
    IF v_exp1 <> v_exp0 THEN
        RAISE EXCEPTION 'FIXTURE 67H 失败:作废后敞口应当回到 %,实得 %', v_exp0, v_exp1;
    END IF;
    -- 行重新可开:同一张单再开一张,通过
    inv := create_order_invoice(so1, d);
    IF (inv->>'line_count')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 67H 失败:作废后两行都该重新可开,实开 %', inv->>'line_count';
    END IF;
    -- sale 头传冲销日 → 按名拒(收下再忽略是在骗调用方)
    BEGIN
        PERFORM void_invoice((SELECT id FROM invoices WHERE kind = 'sale' AND status = 'issued' LIMIT 1), 'x', d);
        RAISE EXCEPTION 'FIXTURE 67H 失败:sale 头带冲销日不该被收下';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'REVERSAL_DATE_NOT_ACCEPTED%' AND SQLERRM NOT LIKE 'INVOICE_NOT_FOUND%' THEN RAISE; END IF;
    END;

    -- ══════════ I. 角色:第二支对无 finance.view 的读者【缺席】═══════════════
    -- README 第 6 条:postgres 跑 fixture,RLS/属主视图的门要切角色才有意义。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_nofin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM ar_open_items;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 67I 失败:没有 module.finance.view 的读者不该看见任何应收行(两支都是),实得 %', v_n;
    END IF;
    -- ══════════ D(收尾跑). 注入:证明挡住重复开票的是【索引】═══════════════
    -- 【为什么排在最后】第二层会给发票插进一行脏数据(而行不可变,删不掉),
    -- 它会污染 E–I 各臂的金额;整段最后回滚,所以放到所有金额断言之后。
    -- 第一层:绕过友好检查直插一行(postgres 直插,连 kind 触发器都在)——
    -- 必须被 uq_invoice_lines_live_order_line 拒。
    v_ok := false;
    BEGIN
        INSERT INTO invoice_lines (invoice_id, sales_order_line_id, line_no, description,
                                   quantity, unit, unit_price, amount_base)
        VALUES (inv_id, L1, 99, 'dup', 1, 'kg', 1, 1);
        v_ok := true;
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    IF v_ok THEN
        RAISE EXCEPTION 'FIXTURE 67D 失败:绕过友好检查直插重复行【通过了】—— 索引没有在挡';
    END IF;
    -- 第二层:把索引拿掉,同一次直插【必须通过】—— 证明第一层拒的确实是它。
    DROP INDEX uq_invoice_lines_live_order_line;
    INSERT INTO invoice_lines (invoice_id, sales_order_line_id, line_no, description,
                               quantity, unit, unit_price, amount_base)
    VALUES (inv_id, L1, 99, 'dup-after-drop', 1, 'kg', 1, 1);
    -- (整段回滚,索引与脏行都不会留下)


END $$;
ROLLBACK;
