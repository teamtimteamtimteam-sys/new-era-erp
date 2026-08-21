-- 71 贷项凭证(CN-1):三条天花板各自点名,而【一处推导】被四个消费方共用
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西,以及为什么每一条都需要一个对照】
--
--   ① 【两种行过的账不同,而这是本刀最要紧的一句】B 臂开一张【混合】凭证:
--      一条 unshipped_cancel(未发的,借 2500)+ 一条 revenue_reduction
--      (已发后减价,借 4000),而两条都贷 1100。一个把两者合成一种的实现
--      会让分录只有两条腿 —— 三条腿、三个科目、三个数,当场分得开。
--   ② 【汇率抄发票的】整张单跑在 fx = 1.25 上(非 1)。两边一致时"折算对不对"
--      这种断言什么都不证明(README 第 4 条的精神);1.25 让本位币那一侧
--      62.50 / 37.50 / 100.00 全都验得出来。
--   ③ 【一处推导,四个消费方】A 臂用目录钉住:order_invoice_open_all、
--      invoice_status、create_credit_note 都读 order_invoice_balance_all,
--      customer_ar_exposure_base 读 order_invoice_open_all。B 臂再从行为上
--      走一遍:开完凭证之后【开放余额、敞口、发票状态】三个数一起下来。
--      注入 1 把那一处推导里的贷记项换成 0 —— 天花板当场失效,证明它读的
--      确实是那一处。
--   ④ 【每一条拒绝都配一个正例】C 臂三条天花板各自"超一分就拒、正好等于放行"。
--      只测拒绝的 fixture 会被一个"什么都不许开"的实现全部通过。
--   ⑤ 【已结清 → 退款,是一个【被停放的】概念,不是一次沉默】D 臂。
--   ⑥ 【sale 型按名拒】E 臂 —— 它什么都不过账,没有分录可冲。
--
-- 【注入臂放在最后】fixture 64/69 付过这笔账:注入种下的行会污染后面各臂。
--   注入 1:balance 视图不再减贷记 → 第二张凭证越过上限却走通(天花板空转)。
--   注入 2:摘掉 guard_credit_note_invoice → sale 型发票也能挂上凭证
--           (证明守卫是【触发器】,不只是函数里的一句客气话)。
--
-- 期间锁显式设 NULL(README 第 5 条)。自带数据(第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_cust uuid; v_mat uuid; v_base text;
    soB uuid; soD uuid; soE uuid;
    L1 uuid; L2 uuid; IL1 uuid; IL2 uuid;
    obB uuid; resB uuid;
    invB uuid; invB_code text; invD uuid; invE uuid;
    v_res jsonb; v_msg text; v_denied boolean; v_n int;
    v_open numeric; v_expo_before numeric; v_expo_after numeric;
    v_2500 numeric; v_4000 numeric; v_1100 numeric;
    v_je uuid; v_cn uuid;
    d date := CURRENT_DATE;
    FX constant numeric := 1.25;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-71', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【牌价自己插】收款那一步要 tt_buy(record_payment:收款 tt_buy / 付款 tt_sell)。
    -- 不指望引导数据里有 —— README 第 4/5 条。
    DELETE FROM fx_rates WHERE currency = 'USD' AND rate_date = d;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', d, 'tt_buy', FX), ('USD', d, 'tt_sell', FX), ('USD', d, 'mid', FX);

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ71-C1', 'fixture 71 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZFIX71-M', 'f71 material', 'battery_material', true, 'kg') RETURNING id INTO v_mat;

    -- ══════════ A. 前提 + 目录:【一处推导,四个消费方】═════════════════════
    IF to_regprocedure('public.create_credit_note(uuid,date,text,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:create_credit_note 不在 —— 它是唯一写入口';
    END IF;
    -- 【取号器靠调不到】无调用者检查,给了 authenticated 就等于任何人能烧号
    IF has_function_privilege('authenticated', 'public.next_credit_note_code(date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:next_credit_note_code 对 authenticated 可执行';
    END IF;
    -- 【余额视图客户端读不到】它不带 has_permission 的门,读得到就等于绕过
    -- module.finance.view 直接读全部客户的应收
    IF has_table_privilege('authenticated', 'public.order_invoice_balance_all', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:order_invoice_balance_all 对 authenticated 可读 —— 它不带门';
    END IF;
    -- 【三个消费方读的是同一处算术】—— 抄一份过去,两边会在写下的那天一致、
    -- 此后各自漂移。这三条断言就是那句话本身。
    IF NOT EXISTS (
        SELECT 1 FROM pg_depend dd
        JOIN pg_rewrite rw ON rw.oid = dd.objid
        JOIN pg_class dep ON dep.oid = rw.ev_class
        JOIN pg_class src ON src.oid = dd.refobjid
        WHERE dep.relname = 'order_invoice_open_all' AND src.relname = 'order_invoice_balance_all') THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:order_invoice_open_all 没有引用 order_invoice_balance_all —— 算术又变回两份了';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_depend dd
        JOIN pg_rewrite rw ON rw.oid = dd.objid
        JOIN pg_class dep ON dep.oid = rw.ev_class
        JOIN pg_class src ON src.oid = dd.refobjid
        WHERE dep.relname = 'invoice_status' AND src.relname = 'order_invoice_balance_all') THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:invoice_status 没有引用 order_invoice_balance_all';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'create_credit_note') NOT LIKE '%order_invoice_balance_all%' THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:create_credit_note 的天花板没有读 order_invoice_balance_all';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'customer_ar_exposure_base') NOT LIKE '%order_invoice_open_all%' THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:customer_ar_exposure_base 没有读 order_invoice_open_all';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_credit_notes_append_only','trg_credit_notes_invoice_guard',
                      'trg_credit_note_lines_belongs') AND NOT tgisinternal;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 71A 失败:三个触发器应当都在,实得 %', v_n;
    END IF;

    -- ══════════ B. 混合凭证:部分发货 + 部分收款 + 非 1 汇率 ═══════════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO soB;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soB, 1, v_mat, 12, 10) RETURNING id INTO L1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soB, 2, v_mat, 20, 10) RETURNING id INTO L2;
    PERFORM set_sales_order_status(soB, 'confirmed');

    -- 两行都开票:发票额 = 120 + 200 = 320 USD,应收 320 × 1.25 = 400 本位币
    v_res := create_order_invoice(soB, d, NULL, NULL, NULL, ARRAY[L1, L2]);
    invB := (v_res->>'invoice_id')::uuid;
    invB_code := v_res->>'code';
    SELECT id INTO IL1 FROM invoice_lines WHERE invoice_id = invB AND sales_order_line_id = L1;
    SELECT id INTO IL2 FROM invoice_lines WHERE invoice_id = invB AND sales_order_line_id = L2;

    -- 第 1 行发 8(共 12):已释放收入 = 8 × 10 = 80;未释放负债 = 120 − 80 = 40
    obB := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    resB := (reserve_stock(L1, obB, 12) ->> 'reservation_id')::uuid;
    PERFORM ship_order(soB, d, jsonb_build_array(
        jsonb_build_object('reservation_id', resB, 'qty', 8)));

    -- 部分收款 100 USD(走 USD 户,不发生兑换)
    PERFORM record_payment('in', v_cust, 100, 'USD', NULL, '1010', d, 'fixture 71',
        jsonb_build_array(jsonb_build_object('invoice_id', invB, 'amount_doc', 100)));

    SELECT open_ccy INTO v_open FROM order_invoice_balance_all WHERE invoice_id = invB;
    IF v_open <> 220 THEN
        RAISE EXCEPTION 'FIXTURE 71B 前置失败:开票 320 − 已收 100 应当剩 220,实得 %', v_open;
    END IF;
    v_expo_before := customer_ar_exposure_base(v_cust);

    -- 【混合凭证】A 行:第 2 行未发的 50(未释放 200 之内);
    --              B 行:第 1 行已发部分减价 30(已释放 80 之内)。合计 80 ≤ 220。
    v_res := create_credit_note(invB, d, '短装收尾 + 质量折让',
        jsonb_build_array(
            jsonb_build_object('invoice_line_id', IL2, 'kind', 'unshipped_cancel', 'qty', 5, 'amount', 50),
            jsonb_build_object('invoice_line_id', IL1, 'kind', 'revenue_reduction', 'amount', 30)));
    v_cn := (v_res->>'credit_note_id')::uuid;
    SELECT entry_id INTO v_je FROM credit_notes WHERE id = v_cn;

    -- 【三条腿,三个科目,三个数 —— 而且都在本位币上验得出来(fx = 1.25)】
    -- 一个把两种行合成一种的实现在这里当场分得开:它只会有两条腿。
    SELECT COALESCE(sum(jl.debit - jl.credit), 0) INTO v_2500
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_je AND a.code = '2500';
    SELECT COALESCE(sum(jl.debit - jl.credit), 0) INTO v_4000
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_je AND a.code = '4000';
    SELECT COALESCE(sum(jl.credit - jl.debit), 0) INTO v_1100
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_je AND a.code = '1100';
    IF v_2500 <> 62.50 THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:未发的那 50 USD 应当借 2500(50 × 1.25 = 62.50 本位币),实得 % —— 它从来没变成收入,借 4000 会把一次正确的交付说成少卖了',
            v_2500;
    END IF;
    IF v_4000 <> 37.50 THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:已发部分减价的 30 USD 应当借 4000(30 × 1.25 = 37.50),实得 %', v_4000;
    END IF;
    IF v_1100 <> 100.00 THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:合计 80 USD 应当贷 1100(80 × 1.25 = 100.00),实得 %', v_1100;
    END IF;
    SELECT count(*) INTO v_n FROM journal_lines WHERE entry_id = v_je;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:混合凭证应当恰有三条腿(2500 / 4000 / 1100),实得 % —— 两条腿说明两种行被合成了一种', v_n;
    END IF;

    -- 【三个数一起下来 —— 因为它们读的是同一处推导】
    SELECT open_ccy INTO v_open FROM order_invoice_balance_all WHERE invoice_id = invB;
    IF v_open <> 140 THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:320 − 已收 100 − 已贷记 80 = 140,实得 %', v_open;
    END IF;
    v_expo_after := customer_ar_exposure_base(v_cust);
    IF round(v_expo_before - v_expo_after, 2) <> 100.00 THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:敞口应当正好降 100.00 本位币(80 × 1.25),实得 % → %',
            v_expo_before, v_expo_after;
    END IF;
    IF (SELECT credited_base FROM invoice_status WHERE invoice_id = invB) <> 100.00
       OR (SELECT open_base FROM invoice_status WHERE invoice_id = invB) <> 175.00 THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:发票状态应当报 已贷记 100.00 / 未结 175.00(400 − 125 − 100),实得 % / %',
            (SELECT credited_base FROM invoice_status WHERE invoice_id = invB),
            (SELECT open_base FROM invoice_status WHERE invoice_id = invB);
    END IF;
    -- 【账龄那一行自己加得起来】金额 − 已结 − 已贷记 = 未结。少了 credited 那一列,
    -- 这三个数就对不上,而读的人会以为页面算错了。
    IF NOT EXISTS (
        SELECT 1 FROM order_invoice_open_all
         WHERE invoice_id = invB
           AND round(amount_ccy - settled_ccy - credited_ccy, 2) = round(open_ccy, 2)) THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:金额 − 已结 − 已贷记 应当正好等于未结';
    END IF;
    -- 【凭证抄的是发票的基准】
    IF (SELECT currency FROM credit_notes WHERE id = v_cn) <> 'USD'
       OR (SELECT fx_rate FROM credit_notes WHERE id = v_cn) <> FX THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:凭证的币种与汇率必须抄自发票';
    END IF;
    -- 订单历史也记了一笔(看订单的人不必去翻发票列表)
    IF NOT EXISTS (SELECT 1 FROM sales_order_history
                    WHERE sales_order_id = soB AND change_type = 'credit_noted') THEN
        RAISE EXCEPTION 'FIXTURE 71B 失败:开凭证应当在订单历史里留下一行 credit_noted';
    END IF;

    -- ══════════ C. 三条天花板:超一分就拒,正好等于放行 ═══════════════════════
    -- ① 未释放的负债:【用第 1 行,不是第 2 行,而这不是随手挑的】
    -- 总额那一条(开放余额 140)排在逐行之前。第 2 行的未释放余量是 150 —— 比
    -- 140 还大,所以在它身上永远【够不到】逐行那一条:超过 150 的数早就先撞上
    -- 总额了。这一臂要测的是逐行天花板,就得挑一条余量【落在开放余额之内】的行:
    -- 第 1 行开票 120、已释放 80,未释放余量 40,41 既超了它、又远在 140 之内。
    -- (挑错行的话,这一臂会因为一条【别的】拒绝而"通过",那正是空转。)
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_credit_note(invB, d, '超未释放一分',
            jsonb_build_array(jsonb_build_object('invoice_line_id', IL1, 'kind', 'unshipped_cancel', 'amount', 41)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'CN_EXCEEDS_UNRELEASED|1|41.00|40.00' THEN
        RAISE EXCEPTION 'FIXTURE 71C 失败:未释放天花板应当点名拒并报出两个数,期望 CN_EXCEEDS_UNRELEASED|1|41.00|40.00,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;
    -- 【正例:正好等于未释放余量放行】—— 把 > 写成 >= 的实现死在这一句上。
    -- 40 也在开放余额之内,所以过的确实是逐行那一关。
    PERFORM create_credit_note(invB, d, '正好等于未释放余量',
        jsonb_build_array(jsonb_build_object('invoice_line_id', IL1, 'kind', 'unshipped_cancel', 'amount', 40)));
    IF (SELECT open_ccy FROM order_invoice_balance_all WHERE invoice_id = invB) <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 71C 失败:再贷记 40 之后应当剩 100,实得 %',
            (SELECT open_ccy FROM order_invoice_balance_all WHERE invoice_id = invB);
    END IF;

    -- ② 已释放的收入:第 1 行 80 − 30(刚才那张)= 50
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_credit_note(invB, d, '超已释放一分',
            jsonb_build_array(jsonb_build_object('invoice_line_id', IL1, 'kind', 'revenue_reduction', 'amount', 51)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'CN_EXCEEDS_RELEASED|1|51.00|50.00' THEN
        RAISE EXCEPTION 'FIXTURE 71C 失败:已释放天花板应当点名拒,期望 CN_EXCEEDS_RELEASED|1|51.00|50.00,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- ③ 整张 ≤ 发票当下的开放余额(此刻 100)。用两行凑 101,而【两行各自都在
    --    自己的天花板之内】(第 2 行未释放余量 150、第 1 行已释放余量 50)——
    --    于是这一臂测的确实是总额那一条,不是被别的先挡住。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_credit_note(invB, d, '超开放余额一分',
            jsonb_build_array(
                jsonb_build_object('invoice_line_id', IL2, 'kind', 'unshipped_cancel', 'amount', 60),
                jsonb_build_object('invoice_line_id', IL1, 'kind', 'revenue_reduction', 'amount', 41)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'CN_EXCEEDS_OPEN|101.00|100.00' THEN
        RAISE EXCEPTION 'FIXTURE 71C 失败:总额天花板应当点名拒,期望 CN_EXCEEDS_OPEN|101.00|100.00,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- 【正例:正好等于天花板放行】—— 一个把 > 写成 >= 的实现死在这一句上。
    -- 【而且这一次的分组也验到了】同一发票行上放两条同类型的行,天花板必须
    -- 按【合计】判:两条各 25 合起来正好 50。
    PERFORM create_credit_note(invB, d, '正好等于已释放上限',
        jsonb_build_array(
            jsonb_build_object('invoice_line_id', IL1, 'kind', 'revenue_reduction', 'amount', 25),
            jsonb_build_object('invoice_line_id', IL1, 'kind', 'revenue_reduction', 'amount', 25)));
    IF (SELECT open_ccy FROM order_invoice_balance_all WHERE invoice_id = invB) <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 71C 失败:再贷记 50 之后应当剩 50,实得 %',
            (SELECT open_ccy FROM order_invoice_balance_all WHERE invoice_id = invB);
    END IF;
    -- 而此刻第 1 行的已释放额度用完了:再要 1 分就该拒
    v_denied := false;
    BEGIN
        PERFORM create_credit_note(invB, d, '额度已用完',
            jsonb_build_array(jsonb_build_object('invoice_line_id', IL1, 'kind', 'revenue_reduction', 'amount', 1)));
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 71C 失败:第 1 行已释放的 80 已经全部贷记完,还能再贷记 1 —— 天花板没有把历史算进去';
    END IF;

    -- ══════════ D. 已结清的发票 → 退款是【被停放的】概念,按名拒 ═══════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO soD;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soD, 1, v_mat, 10, 10);
    PERFORM set_sales_order_status(soD, 'confirmed');
    invD := (create_order_invoice(soD, d, NULL, NULL, NULL, NULL)->>'invoice_id')::uuid;
    PERFORM record_payment('in', v_cust, 100, 'USD', NULL, '1010', d, 'fixture 71 D',
        jsonb_build_array(jsonb_build_object('invoice_id', invD, 'amount_doc', 100)));

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_credit_note(invD, d, '钱都收到了还想冲',
            jsonb_build_array(jsonb_build_object('invoice_line_id',
                (SELECT id FROM invoice_lines WHERE invoice_id = invD LIMIT 1),
                'kind', 'revenue_reduction', 'amount', 10)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'CN_INVOICE_FULLY_SETTLED|%' THEN
        RAISE EXCEPTION 'FIXTURE 71D 失败:全款收到的发票不能再贷记 —— 要还的是【现金】,那是退款,而这个系统还没有客户贷余的落脚点。期望 CN_INVOICE_FULLY_SETTLED,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- ══════════ E. sale 型发票 → 按种类拒 ════════════════════════════════════
    -- 【它什么都不过账】entry_id/fx_rate 按 CHECK 恒为 NULL,应收长在
    -- 不可变的 sales_records 上 —— 没有分录可冲。
    INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, total_base, bill_to_snapshot, kind)
    VALUES ('ZZ71-INV-SALE', v_cust, d, d + 30, 30, v_base, 100, 100,
            jsonb_build_object('code','ZZ71-C1'), 'sale')
    RETURNING id INTO invE;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_credit_note(invE, d, 'sale 型也想冲',
            jsonb_build_array(jsonb_build_object('invoice_line_id', IL1, 'kind', 'revenue_reduction', 'amount', 1)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'CN_INVOICE_NOT_ORDER_KIND|%|sale' THEN
        RAISE EXCEPTION 'FIXTURE 71E 失败:sale 型发票应当按种类拒(它什么都不过账,没有分录可冲),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- ══════════ F. 理由与单据日:两个都必填,而且【永不默认】═══════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_credit_note(invB, d, '   ',
            jsonb_build_array(jsonb_build_object('invoice_line_id', IL2, 'kind', 'unshipped_cancel', 'amount', 10)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'CN_REASON_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 71F 失败:空白理由应当按名拒(三个月后没有人说得出为什么减了账),实得 %',
            COALESCE(v_msg, '(放行了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_credit_note(invB, NULL, '日期空着',
            jsonb_build_array(jsonb_build_object('invoice_line_id', IL2, 'kind', 'unshipped_cancel', 'amount', 10)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'CN_NOTE_DATE_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 71F 失败:单据日空着应当按名拒 —— 它决定冲销落进哪个期间,补一个今天会让留空比填对更容易通过。实得 %',
            COALESCE(v_msg, '(放行了)');
    END IF;

    -- ══════════ G. 签发档:版本、摘要、只增不改 ═══════════════════════════════
    PERFORM record_cn_issue(v_cn, 'p1', repeat('a', 64));
    PERFORM record_cn_issue(v_cn, 'p2', repeat('b', 64));
    IF (SELECT max(version) FROM cn_issues WHERE credit_note_id = v_cn) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 71G 失败:重新签发应当追加第 2 版';
    END IF;
    v_denied := false;
    BEGIN UPDATE cn_issues SET sha256 = repeat('c', 64) WHERE credit_note_id = v_cn AND version = 1;
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 71G 失败:签发档应当只增不改 —— 客户手里那份是某个具体版本';
    END IF;
    v_denied := false;
    BEGIN INSERT INTO cn_issues (credit_note_id, version, file_path, sha256)
          VALUES (v_cn, 1, 'x', repeat('d', 64));
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 71G 失败:同一张凭证的同一版本号应当唯一';
    END IF;

    -- ══════════ H. 凭证只增不改 —— 【两堵墙,而它们是两回事】═══════════════════
    -- 这一臂第一次写的时候把两者混成了一条断言,当场红,而那次红是对的:
    -- 以 authenticated 直连改凭证,【RLS 先把行滤掉了】(本表没有 UPDATE 策略),
    -- 于是那条 UPDATE 命中 0 行、安安静静地"成功"—— 触发器根本没被叫到。
    -- 两堵墙要分开验,否则:
    --   * 只验 authenticated,会把 RLS 的功劳记在触发器头上 —— 哪天有人加一条
    --     UPDATE 策略(完全可能:"财务应该能改理由"),这条断言仍然绿,而凭证
    --     从此改得动;
    --   * 只验属主,又会漏掉"客户端那条路本来就通不到"这半句。
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE credit_notes SET reason = '偷偷改的理由' WHERE id = v_cn;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 71H 失败:以 authenticated 直连改凭证应当一行都命不中(本表没有 UPDATE 策略),实得 % 行', v_n;
    END IF;
    IF (SELECT reason FROM credit_notes WHERE id = v_cn) = '偷偷改的理由' THEN
        RAISE EXCEPTION 'FIXTURE 71H 失败:理由被改掉了';
    END IF;

    -- 【第二堵墙:属主身份也改不动】—— RLS 对表属主不生效,所以这一句问的
    -- 正是"触发器在不在"。少了它,上面那条断言测的只是 RLS。
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE credit_notes SET reason = '属主也想改' WHERE id = v_cn;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'CREDIT_NOTE_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 71H 失败:属主身份改凭证应当被【触发器】按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM credit_note_lines WHERE credit_note_id = v_cn;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'CREDIT_NOTE_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 71H 失败:凭证行也应当删不掉,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(删掉了)');
    END IF;
    -- 【没有 INSERT 策略】唯一写入口是 create_credit_note —— 留着侧门,下一个人
    -- 照样能插一张没有分录、不受任何天花板约束的凭证。
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN INSERT INTO credit_notes (code, invoice_id, reason, note_date, entry_id, currency, fx_rate)
          VALUES ('ZZ71-SIDE', invB, 'side door', d, v_je, 'USD', FX);
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 71H 失败:直连插一张凭证应当被 RLS 拒(没有 INSERT 策略)—— 那会是一张没有分录、不受天花板约束的凭证';
    END IF;

    -- ══════════ 注入 1:那一处推导不再减贷记 ══════════════════════════════════
    -- B/C 两臂的天花板全靠 order_invoice_balance_all 把【已贷记】减掉。把那一项
    -- 换成 0,一张早该被拒的凭证必须当场走通 —— 走不通就说明天花板一直靠别的
    -- 东西成立,那些断言在空转。
    EXECUTE $inj$
        CREATE OR REPLACE VIEW public.order_invoice_balance_all WITH (security_invoker = off) AS
         SELECT i.id AS invoice_id, i.code, i.customer_id, i.issue_date, i.due_date,
            i.currency, i.fx_rate, l.amount_ccy,
            round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
            -- 【被换掉的那一项】:已贷记不算
            round(l.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
            round((l.amount_ccy - COALESCE(s.settled, 0::numeric)) * i.fx_rate, 2) AS open_base,
            0::numeric AS credited_ccy,
            0::numeric AS credited_base
           FROM invoices i
             JOIN LATERAL ( SELECT COALESCE(sum(il.amount_ccy), 0::numeric) AS amount_ccy
                   FROM invoice_lines il WHERE il.invoice_id = i.id) l ON true
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.invoice_id = i.id) s ON true
          WHERE i.kind = 'order'::text AND i.status = 'issued'::text;
    $inj$;

    v_denied := false;
    BEGIN
        -- 第 1 行的已释放额度在 C 臂已经用完了(80 全部贷记)。真实推导下这必拒;
        -- 注入之后【总额】那一条也松了,而逐行那一条读的是 credit_note_lines 的
        -- 历史,所以这里挑一个只被【总额】挡住的量:再来 100(真实开放余额只剩 90)。
        -- 真实开放余额此刻是 50,而第 2 行的未释放余量还有 150 —— 所以 90 只被
        -- 【总额】那一条挡着。注入之后总额那一条读到的是"没有减过贷记"的数,
        -- 于是它必须放行。
        PERFORM create_credit_note(invB, d, '注入:总额天花板应当失效',
            jsonb_build_array(jsonb_build_object('invoice_line_id', IL2, 'kind', 'unshipped_cancel', 'amount', 90)));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 71 注入1 失败:把那一处推导里的【已贷记】换成 0 之后,一张超出真实开放余额的凭证【仍然】被拒(%)—— 说明总额天花板一直靠别的东西成立,B/C 两臂在空转',
            v_msg;
    END IF;

    -- ══════════ 注入 2:摘掉发票种类守卫 ═════════════════════════════════════
    -- E 臂靠的是函数里那一句【和】触发器两道。摘掉触发器之后,直连插一张挂在
    -- sale 型发票上的凭证必须当场走通 —— 证明守卫确实是触发器,不只是函数里的
    -- 一句客气话(fixture 52 C 臂为这条区别写过一整段)。
    DROP TRIGGER trg_credit_notes_invoice_guard ON public.credit_notes;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO credit_notes (code, invoice_id, reason, note_date, entry_id, currency, fx_rate)
        VALUES ('ZZ71-INJ2', invE, '注入2:sale 型', d, v_je, v_base, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 71 注入2 失败:摘掉 guard_credit_note_invoice 之后,挂在 sale 型发票上的凭证【仍然】插不进去(%)—— 说明 E 臂那条拒绝不是触发器给的',
            v_msg;
    END IF;
END $$;
ROLLBACK;
