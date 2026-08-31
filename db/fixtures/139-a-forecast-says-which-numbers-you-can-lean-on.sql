-- 139 现金预测:每一行【说得出它是哪一种】,而看不见的那部分【也在纸上】(CASHFLOW-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉五件事】
--   · **周界与复用** —— 周一起算;期初【就是】bank_book_balance_asof 那个数,
--     AR/AP 走 ar/ap_aging_asof。一份自己算 AR 合计的预测,是对账单印的那个数
--     的第二份实现。
--   · **三档 confidence 真的分得开** —— 合同日 / 有主的估计 / 手工录入。
--     一份把三者印成一个样子的预测,它最大的价值(哪个数字能靠)就没了。
--   · **看不见的那部分在纸上** —— AP 实测一个日期都没有(0/13、429,537.62)。
--     一份悄悄漏掉大半应付的预测,是一个会被人当真的数字。
--   · **承诺备查、不计入** —— 承诺与 AR 是同一笔钱,而系统说不出它盖的是哪几行。
--   · **冻得住** —— 冻下来之后底下的数据再动,那一行一个字不动。
--
-- ★【本仓库记过的两个陷阱,这份 fixture 都刻意躲开】★
--   ① **靠"两个实现碰巧一致"通过**(FIN-18):所以复用那一臂不比"两个数相等",
--      它比【重算做不到的那一项】—— 按币种拆开、以及跨币种合计不可得。
--   ② **目录断言匹配到一句注释而不是一次调用**(fixture 136):所以 J 臂先剥注释,
--      而且匹配的是【带参数的调用形状】,不是函数名出现过。
--
-- 自带数据(README 第 2 条);期间锁、汇率自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_base   text; v_fgn text;
    v_bank_b text; v_bank_f text;
    v_cust   uuid; v_sup uuid; v_mat uuid; v_ob uuid; v_sale uuid; v_sale_f uuid;
    v_po     uuid; v_t_ship uuid; v_t_arr uuid; v_t_assay uuid; v_t_fixed uuid;
    v_line_m uuid; v_line_o uuid;
    v_chase  jsonb; v_promise uuid;
    v_ws     date := date_trunc('week', CURRENT_DATE)::date;
    v_d      jsonb; v_d2 jsonb;
    v_res    jsonb; v_fc uuid; v_fc2 uuid;
    v_n int; v_msg text; v_src text;
    v_open_b numeric; v_open_f numeric;
    v_undated numeric; v_ap_undated numeric;
    v_frozen jsonb; v_recomputed numeric; v_frozen_close numeric;
    v_opex1 numeric; v_opex2 numeric;
    v_conf  text[];
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-139', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;

    SELECT code INTO v_base FROM currencies WHERE is_base;
    -- ★【外币要从【有现金账户的】那些里挑,不是从 currencies 里挑第一个】★
    -- 第一版写的是 `FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1`,
    -- 挑中了 CNY —— 而 CNY 【没有现金账户】(is_cash 只有 1000 SGD 与 1010 USD),
    -- 于是期初里根本没有那一格,B 臂的自证非空当场把它抓了出来。
    -- 记在这里:这一条正是"按构造非空"要防的东西 —— 少了那句自证,
    -- 这一臂会在一个【不存在的币种】上安静地通过。
    SELECT bank_native_currency(a.code) INTO v_fgn
      FROM accounts a WHERE a.is_cash AND bank_native_currency(a.code) <> v_base
     ORDER BY a.code LIMIT 1;
    IF v_fgn IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 139 前提不成立:一个非本位币的现金账户都没有,按币种分开这件事无从测起';
    END IF;
    v_bank_b := bank_account_for_currency(v_base);
    v_bank_f := bank_account_for_currency(v_fgn);

    -- 汇率:只给【过去】的,故意【不给今天的 mid】——
    -- 那正是线上的实况(mid 停在 2026-07-31),而 B 臂要靠它证明
    -- "跨币种合计不可得"是被说出来的,不是被编出来的。
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit) VALUES
        (v_fgn, v_ws - 30, 'tt_buy', 1.30),
        (v_fgn, v_ws - 30, 'tt_sell', 1.32),
        (v_fgn, v_ws - 30, 'mid', 1.31);

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ-F139-C', 'fixture 139 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F139-S', 'fixture 139 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-F139-M', 'fixture 139 material', 'battery_material', true,
            'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'ZZ-F139-OB', 500, 500, 'kg', v_ws - 40, '库存中', v_cust) RETURNING id INTO v_ob;

    -- 一笔销售 + 一笔【本位币】收款 → 期初里本位币那一格非零
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 100, 50, v_base, 1, 5000, v_ws - 35) RETURNING id INTO v_sale;
    PERFORM record_payment('in', v_cust, 3000, v_base, NULL, v_bank_b, v_ws - 30, 'fixture 139 本位币收款',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 3000)));
    -- 一笔【外币】销售 + 对着它的外币收款 → 期初里外币那一格也非零(两个币种,B 臂要的)
    -- 【为什么要有那笔销售:收款必须核销到单据上】已注册 GST 时,一笔挂账的
    -- 客户收款根本写不进去(GST_UNALLOCATED_RECEIPT_UNSUPPORTED,GST-2 立的
    -- 「孰早」的另一半)。本 fixture 不需要挂账,所以【不去动 GST 开关】——
    -- 把收款核销掉就行。少一个前提,就少一件会在别处出错的事。
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 50, 20, v_fgn, 1.30, 1300, v_ws - 35) RETURNING id INTO v_sale_f;
    -- 【汇率传 NULL,由它自己查牌价】record_payment 只在【跨币种结算】时接受
    -- 一个显式汇率(那是银行真实成交的价);同币种结算传汇率会被按名拒
    -- (FX_RATE_NOT_ACCEPTED)。上面那三条 fx_rates 就是给它查的。
    PERFORM record_payment('in', v_cust, 800, v_fgn, NULL, v_bank_f, v_ws - 30, 'fixture 139 外币收款',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale_f, 'amount_doc', 800)));

    -- 一张【未结】PO,四条分期:三种要估计的 + 一条 fixed_date(它自带真日期)
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate,
                                 estimated_total_ccy, status)
    VALUES ('ZZ-F139-PO', v_sup, v_ws - 20, v_base, 1, 100000, 'confirmed') RETURNING id INTO v_po;
    -- EQP-PAY-1:这张单要有【一条明细行】,否则判不出它是材料单还是设备单,
    -- 而 guard_payment_term_applicable 会按名拒(PO_TERM_KIND_UNKNOWN)——
    -- 判不出种类就判不出下面那几期里程碑用不用得上。
    -- 【这不是为了迁就一条新规矩而改测试】一张【没有明细行的采购单】本来就不是
    -- 一份真实单据:create_purchase_order 自己就拒(NO_LINES)。这一行补的是
    -- 本来就该有的东西,而下面四期(含 post_assay)在材料单上照旧全部适用,
    -- 所以本 fixture 的每一条断言都不受影响。
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit,
                                      estimated_unit_price, estimated_amount_ccy)
    VALUES (v_po, 1, v_mat, 1000, 'kg', 100, 100000);
    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage, trigger_event)
    VALUES (v_po, 1, 'shipment', 30, 'on_shipment') RETURNING id INTO v_t_ship;
    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage, trigger_event)
    VALUES (v_po, 2, 'arrival', 30, 'on_arrival') RETURNING id INTO v_t_arr;
    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage, trigger_event)
    VALUES (v_po, 3, 'assay', 20, 'post_assay') RETURNING id INTO v_t_assay;
    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              trigger_event, due_date)
    VALUES (v_po, 4, 'balance', 20, 'fixed_date', v_ws + 20) RETURNING id INTO v_t_fixed;

    -- 手工行:一条【经常性】(算固定 OPEX)+ 一条【一次性】(不算)
    INSERT INTO cash_forecast_lines (label, direction, amount_ccy, currency, cadence, start_date)
    VALUES ('rent', 'out', 6000, v_base, 'monthly', v_ws + 3) RETURNING id INTO v_line_m;
    INSERT INTO cash_forecast_lines (label, direction, amount_ccy, currency, cadence, start_date)
    VALUES ('one-off equipment balance', 'out', 45000, v_base, 'once', v_ws + 10) RETURNING id INTO v_line_o;

    -- 一条催收 + 一个承诺(H 臂:备查、不计入)
    v_chase := record_collection_chase(
        p_customer_id => v_cust, p_chased_on => CURRENT_DATE, p_channel => 'phone',
        p_reached => true, p_summary => 'fixture 139:他答应下周付',
        p_promise => jsonb_build_object('amount', 1500, 'currency', v_base,
                                        'promised_date', (v_ws + 8)::text));
    v_promise := (v_chase->>'promise_id')::uuid;

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 周界是【周一】,而非周一按名拒
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 自证非空:先证明 v_ws 真的是周一,再证明 v_ws+1 真的【不是】——
    --   否则"拒绝了非周一"这句话可能是在拒绝一个本来就合法的日子。
    IF EXTRACT(ISODOW FROM v_ws) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 139A 失败(空转):date_trunc(week) 给的不是周一(%),这一臂的前提就不成立', v_ws;
    END IF;
    IF EXTRACT(ISODOW FROM v_ws + 1) = 1 THEN
        RAISE EXCEPTION 'FIXTURE 139A 失败(空转):v_ws+1 也是周一?那这一臂拒的不是"非周一"';
    END IF;
    v_d := cash_forecast_data(v_ws);
    IF (v_d->>'week_start')::date <> v_ws THEN
        RAISE EXCEPTION 'FIXTURE 139A 失败:周一起算没生效,实得 %', v_d->>'week_start';
    END IF;
    IF (v_d->>'week_end')::date <> v_ws + 90 THEN
        RAISE EXCEPTION 'FIXTURE 139A 失败:13 周应当覆盖 91 天(到 %),实得 %', v_ws+90, v_d->>'week_end';
    END IF;
    BEGIN
        PERFORM cash_forecast_data(v_ws + 1);
        RAISE EXCEPTION 'FIXTURE 139A 失败:非周一的起点没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'FORECAST_WEEK_START_NOT_MONDAY%' THEN
            RAISE EXCEPTION 'FIXTURE 139A 失败:应报 FORECAST_WEEK_START_NOT_MONDAY,实得 %', v_msg;
        END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · 期初【就是】bank_book_balance_asof,而且【按币种分开】
    -- ══════════════════════════════════════════════════════════════════════
    -- ★★【这一臂刻意【不】只比"两个数相等"】★★
    -- 一个"自己 sum 一遍 journal_lines"的重写今天会给出一样的合计 ——
    -- FIN-18 那条:能靠两个答案碰巧一致通过的断言什么都没证明。
    -- 证得死的是【重写做不到的那两件事】:① 按各账户【自己的币种】分开;
    -- ② 跨币种合计【不可得】,而且它说得出缺哪个币种的汇率。
    SELECT (e->>'amount')::numeric INTO v_open_b FROM jsonb_array_elements(v_d->'opening') e
     WHERE e->>'currency' = v_base LIMIT 1;
    SELECT (e->>'amount')::numeric INTO v_open_f FROM jsonb_array_elements(v_d->'opening') e
     WHERE e->>'currency' = v_fgn LIMIT 1;

    -- ★ 自证非空:两个币种都要真的有钱动过,否则下面全是 0 = 0
    IF COALESCE(v_open_b,0) = 0 OR COALESCE(v_open_f,0) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 139B 失败(空转):期初 本位币=% 外币=% —— 至少一格是 0,按币种分开这件事就没被测到',
            v_open_b, v_open_f;
    END IF;
    IF v_open_b <> bank_book_balance_asof(v_bank_b, v_ws - 1) THEN
        RAISE EXCEPTION 'FIXTURE 139B 失败:期初(本位币)% 与 bank_book_balance_asof 的 % 不一致 —— 预测自己算了一遍',
            v_open_b, bank_book_balance_asof(v_bank_b, v_ws - 1);
    END IF;
    IF v_open_f <> bank_book_balance_asof(v_bank_f, v_ws - 1) THEN
        RAISE EXCEPTION 'FIXTURE 139B 失败:期初(外币)% 与 bank_book_balance_asof 的 % 不一致',
            v_open_f, bank_book_balance_asof(v_bank_f, v_ws - 1);
    END IF;
    -- ② 跨币种合计【不可得】,并且点得出是哪个币种 —— 本 fixture 只给了 30 天前的汇率
    IF (v_d->>'base_total_available')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 139B 失败:今天没有 % 的 mid 汇率,却报告跨币种合计【可得】—— 那个合计只能是编出来的', v_fgn;
    END IF;
    IF NOT (v_d->'base_total_missing_fx' @> to_jsonb(ARRAY[v_fgn])) THEN
        RAISE EXCEPTION 'FIXTURE 139B 失败:合计不可得,却没说是缺了 % 的汇率 —— 一个不说原因的缺席读起来就是 0', v_fgn;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · ★【看不见的那部分【在纸上】】★
    -- ══════════════════════════════════════════════════════════════════════
    -- 实测线上 AP 13 行 429,537.62 【一个日期都没有】。一份把它们静静丢掉的
    -- 预测,会让人对着一个漏掉大半应付的数字做决定。
    SELECT COALESCE(sum((e->>'amount')::numeric),0) INTO v_undated
      FROM jsonb_array_elements(v_d->'undated') e;
    SELECT COALESCE(sum((e->>'amount')::numeric),0) INTO v_ap_undated
      FROM jsonb_array_elements(v_d->'undated') e WHERE e->>'source' = 'ap';
    -- ★ 自证非空:必须真的有一笔无日期的钱,否则这一臂在测一张空表
    IF v_undated = 0 THEN
        RAISE EXCEPTION 'FIXTURE 139C 失败(空转):无日期那一段合计是 0 —— 这一臂要证的正是"有钱、但落不进任何一周"';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'undated') e
                    WHERE e->>'why' = 'no_date') THEN
        RAISE EXCEPTION 'FIXTURE 139C 失败:无日期那一段里没有一条 why=no_date —— 说不出"为什么落不进去"';
    END IF;
    -- 而且它【不】被塞进任何一周
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'lines') e WHERE e->>'due' IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 139C 失败:有一条没有日期的行混进了周明细 —— 那等于替它编了一个日子';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · 三档 confidence 真的分得开
    -- ══════════════════════════════════════════════════════════════════════
    -- 先给 on_shipment 设一个预计日 → 它应当是 estimated;
    -- 而 fixed_date 那一条自带真日期 → committed;手工行 → manual。
    PERFORM set_payment_term_expected_date(v_t_ship, v_ws + 12);
    v_d := cash_forecast_data(v_ws);

    SELECT array_agg(DISTINCT e->>'confidence' ORDER BY e->>'confidence') INTO v_conf
      FROM jsonb_array_elements(v_d->'lines') e;
    -- ★ 自证非空:三档必须都真的出现过,否则"分得开"是一句空话
    IF NOT (v_conf @> ARRAY['committed','estimated','manual']) THEN
        RAISE EXCEPTION 'FIXTURE 139D 失败(空转):三档 confidence 没有都出现(实得 %) —— 分不分得开无从谈起', v_conf;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'lines') e
                    WHERE e->>'source'='po_instalment' AND e->>'ref'='ZZ-F139-PO'
                      AND e->>'confidence'='estimated' AND (e->>'due')::date = v_ws + 12) THEN
        RAISE EXCEPTION 'FIXTURE 139D 失败:设了预计日的 on_shipment 那一期没有以 estimated 出现在 % 那一周', v_ws+12;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'lines') e
                    WHERE e->>'source'='po_instalment' AND e->>'confidence'='committed'
                      AND (e->>'due')::date = v_ws + 20) THEN
        RAISE EXCEPTION 'FIXTURE 139D 失败:fixed_date 那一期应当是 committed 且落在 %', v_ws+20;
    END IF;
    -- 【有主】:估计那一行要说得出保管人是谁
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'lines') e
                    WHERE e->>'confidence'='estimated' AND COALESCE(e->>'owner_name','') <> '') THEN
        RAISE EXCEPTION 'FIXTURE 139D 失败:估计那一行没有保管人 —— 一个没人拥有的估计会停止被维护';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · 预计日期:三种可设、两种按名拒、过去的按名拒
    -- ══════════════════════════════════════════════════════════════════════
    BEGIN
        PERFORM set_payment_term_expected_date(v_t_fixed, v_ws + 30);
        RAISE EXCEPTION 'FIXTURE 139E 失败:给 fixed_date 那一期设预计日,居然过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPECTED_DATE_NOT_APPLICABLE%' THEN
            RAISE EXCEPTION 'FIXTURE 139E 失败:应报 EXPECTED_DATE_NOT_APPLICABLE,实得 %', v_msg;
        END IF;
    END;
    BEGIN
        PERFORM set_payment_term_expected_date(v_t_arr, CURRENT_DATE - 1);
        RAISE EXCEPTION 'FIXTURE 139E 失败:一个"预计在昨天"的日期居然过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPECTED_DATE_IN_PAST%' THEN
            RAISE EXCEPTION 'FIXTURE 139E 失败:应报 EXPECTED_DATE_IN_PAST,实得 %', v_msg;
        END IF;
        -- 拒绝的话里要带上保管人 —— 否则没人知道该去找谁改
        IF v_msg NOT LIKE '%Fu Sheng Wong%' THEN
            RAISE EXCEPTION 'FIXTURE 139E 失败:拒绝里没有点出保管人的名字,实得 %', v_msg;
        END IF;
    END;
    -- 三种都设得上
    PERFORM set_payment_term_expected_date(v_t_arr,   v_ws + 40);
    PERFORM set_payment_term_expected_date(v_t_assay, v_ws + 60);
    IF (SELECT count(*) FROM purchase_order_payment_terms
         WHERE purchase_order_id = v_po AND expected_date IS NOT NULL) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 139E 失败:三条该设得上的预计日,没有都设上';
    END IF;
    -- 【出处】谁设的、什么时候设的,要留下来
    IF EXISTS (SELECT 1 FROM purchase_order_payment_terms
                WHERE purchase_order_id = v_po AND expected_date IS NOT NULL
                  AND (expected_date_set_by IS NULL OR expected_date_set_at IS NULL)) THEN
        RAISE EXCEPTION 'FIXTURE 139E 失败:有预计日却没有出处 —— 下一个人无从判断它是上周想的还是三个月前想的';
    END IF;

    RAISE NOTICE 'fixture 139 · 现金预测 —— A–E 臂通过,继续 F–J';

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · ★【承诺是备查,不计入合计】★
    -- ══════════════════════════════════════════════════════════════════════
    -- 承诺与它指向的那几张 AR 是【同一笔钱】,而 CHASE-1 实测过:未结 AR 里
    -- 绝大多数是未开票的销售,连一个客户认得的单号都没有 —— 系统说不出一个
    -- 承诺盖的是哪几行。加进合计 = 重复计算;不放 = 丢掉唯一"客户自己答应过"
    -- 的日期。所以:列出来,不求和。
    v_d := cash_forecast_data(v_ws);
    -- ★ 自证非空:那个承诺必须真的在备查里,而且金额非零 ——
    --   否则"没被计入"与"根本没有这条承诺"在断言里长得一模一样。
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'promises_memo') e
                    WHERE (e->>'promise_id')::uuid = v_promise
                      AND (e->>'amount')::numeric = 1500) THEN
        RAISE EXCEPTION 'FIXTURE 139F 失败(空转):那个 1500 的承诺不在备查里 —— "没被计入合计"这句话于是什么都没证明';
    END IF;
    -- 而它【不】出现在明细里,也就不会进任何一周的进项
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'lines') e WHERE e->>'source' = 'promise') THEN
        RAISE EXCEPTION 'FIXTURE 139F 失败:承诺混进了明细行 —— 它与 AR 是同一笔钱,加进去就是重复计算';
    END IF;
    -- 【正面证据】把那一周的进项加起来,里面【没有】那 1500
    SELECT COALESCE(sum((e->>'inflow')::numeric),0) INTO v_recomputed
      FROM jsonb_array_elements(v_d->'buckets') e
     WHERE e->>'currency' = v_base AND (e->>'week_no')::int = (v_ws + 8 - v_ws)/7 + 1;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_d->'buckets') e
                WHERE e->>'currency' = v_base
                  AND (e->>'week_no')::int = (v_ws + 8 - v_ws)/7 + 1
                  AND (e->>'inflow')::numeric >= 1500) THEN
        RAISE EXCEPTION 'FIXTURE 139F 失败:承诺那一周的进项是 %,含着那 1500 —— 重复计算了', v_recomputed;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · 固定 OPEX 【不含 once】;覆盖月数按【谷底】,并列出今天的
    -- ══════════════════════════════════════════════════════════════════════
    SELECT (e->>'monthly_fixed_opex')::numeric INTO v_opex1
      FROM jsonb_array_elements(v_d->'buffer') e WHERE e->>'currency' = v_base;
    -- ★ 自证非空:固定 OPEX 必须非零(有一条 monthly 的 rent),
    --   否则"不含 once"这句话是在 0 上做的
    IF COALESCE(v_opex1,0) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 139G 失败(空转):固定 OPEX 是 0 —— "不含一次性"这件事在 0 上证明不了';
    END IF;
    IF v_opex1 <> 6000 THEN
        RAISE EXCEPTION 'FIXTURE 139G 失败:月度固定 OPEX 应当是 6000(那条 monthly 的 rent),实得 % —— 45000 那条一次性被算进去了?', v_opex1;
    END IF;
    -- 再加一条【一次性】的大额,固定 OPEX 必须【纹丝不动】
    INSERT INTO cash_forecast_lines (label, direction, amount_ccy, currency, cadence, start_date)
    VALUES ('another one-off', 'out', 99999, v_base, 'once', v_ws + 15);
    v_d2 := cash_forecast_data(v_ws);
    SELECT (e->>'monthly_fixed_opex')::numeric INTO v_opex2
      FROM jsonb_array_elements(v_d2->'buffer') e WHERE e->>'currency' = v_base;
    IF v_opex2 <> v_opex1 THEN
        RAISE EXCEPTION 'FIXTURE 139G 失败:加了一条 99999 的【一次性】之后,固定 OPEX 从 % 变成了 % —— 覆盖月数会随便一条一次性录入就跳一下',
            v_opex1, v_opex2;
    END IF;
    -- 覆盖月数:谷底那个【不高于】今天那个(这一份预测里净流出为主)
    IF (SELECT (e->>'months_cover_min')::numeric > (e->>'months_cover_today')::numeric
          FROM jsonb_array_elements(v_d2->'buffer') e WHERE e->>'currency' = v_base) THEN
        RAISE EXCEPTION 'FIXTURE 139G 失败:谷底覆盖月数【高于】今天的 —— 那不是谷底';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 · 冻得住:冻完之后改底下的数据,那一行一个字不动
    -- ══════════════════════════════════════════════════════════════════════
    v_res := freeze_cash_forecast(v_ws, NULL);
    v_fc  := (v_res->>'forecast_id')::uuid;
    SELECT buckets INTO v_frozen FROM cash_forecasts WHERE id = v_fc;
    SELECT (e->>'closing')::numeric INTO v_frozen_close
      FROM jsonb_array_elements(v_frozen) e
     WHERE e->>'currency' = v_base AND (e->>'week_no')::int = 13;

    -- 改数据:再加一条大额手工行,今天重算一定不同
    INSERT INTO cash_forecast_lines (label, direction, amount_ccy, currency, cadence, start_date)
    VALUES ('after the freeze', 'out', 77777, v_base, 'once', v_ws + 5);
    SELECT (e->>'closing')::numeric INTO v_recomputed
      FROM jsonb_array_elements((cash_forecast_data(v_ws))->'buckets') e
     WHERE e->>'currency' = v_base AND (e->>'week_no')::int = 13;

    -- ★ 自证非空:两个数必须真的分开,否则"冻住了"与"什么都没发生"一样
    IF v_recomputed = v_frozen_close THEN
        RAISE EXCEPTION 'FIXTURE 139H 失败(空转):改了数据之后重算仍是 % —— 这一臂没把两者分开,冻结无从证明', v_frozen_close;
    END IF;
    SELECT (e->>'closing')::numeric INTO v_undated
      FROM jsonb_array_elements((SELECT buckets FROM cash_forecasts WHERE id = v_fc)) e
     WHERE e->>'currency' = v_base AND (e->>'week_no')::int = 13;
    IF v_undated <> v_frozen_close THEN
        RAISE EXCEPTION 'FIXTURE 139H 失败:底下的数据变了之后,冻下来的那一行从 % 变成了 % —— 它没有被冻住',
            v_frozen_close, v_undated;
    END IF;
    -- 明细也冻了(偏差分析要问"哪一行动了")
    IF jsonb_array_length((SELECT lines FROM cash_forecasts WHERE id = v_fc)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 139H 失败:冻下来的那一份没有明细 —— 偏差分析问的是哪一行动了,冻合计答不出';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- I 臂 · 同一周重冻 = 新行 + 旧行 superseded,而理由必填
    -- ══════════════════════════════════════════════════════════════════════
    BEGIN
        PERFORM freeze_cash_forecast(v_ws, NULL);
        RAISE EXCEPTION 'FIXTURE 139I 失败:同一周重冻,没给理由却过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'FORECAST_SUPERSEDE_REASON_REQUIRED%' THEN
            RAISE EXCEPTION 'FIXTURE 139I 失败:应报 FORECAST_SUPERSEDE_REASON_REQUIRED,实得 %', v_msg;
        END IF;
    END;
    v_res := freeze_cash_forecast(v_ws, '周中又录了一笔大额一次性');
    v_fc2 := (v_res->>'forecast_id')::uuid;
    IF (SELECT superseded_at FROM cash_forecasts WHERE id = v_fc) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 139I 失败:旧的那一份没有被标成 superseded';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cash_forecasts WHERE id = v_fc) THEN
        RAISE EXCEPTION 'FIXTURE 139I 失败:旧的那一份被【删掉】了 —— 它正是 T1 的偏差要比的那个基准';
    END IF;
    IF (SELECT superseded_by FROM cash_forecasts WHERE id = v_fc) <> v_fc2 THEN
        RAISE EXCEPTION 'FIXTURE 139I 失败:旧行没有指向取代它的那一份';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- J 臂 · 目录断言:它【真的调】那三支,不是自己又算了一遍
    -- ══════════════════════════════════════════════════════════════════════
    -- ★【先剥注释,而且匹配【带参数的调用形状】】★ fixture 136 曾经匹配到一句
    -- 【注释】而绿;CHASE-1 那次更细一层 —— 只匹配函数名也不够,因为函数名会
    -- 出现在别处(注释剥掉之后仍可能出现在另一处调用里)。所以钉的是调用形状。
    SELECT string_agg(l, E'\n') INTO v_src
      FROM (SELECT regexp_replace(l, '--.*$', '') AS l
              FROM regexp_split_to_table(
                     pg_get_functiondef('public.cash_forecast_data(date)'::regprocedure), E'\n') AS l) q;
    IF v_src NOT LIKE '%bank_book_balance_asof(a.code, v_asof)%' THEN
        RAISE EXCEPTION 'FIXTURE 139J 失败:期初【不是】bank_book_balance_asof 算的 —— 而在它之前 ledger_balance 在线上差过 USD 1,585.00';
    END IF;
    IF v_src NOT LIKE '%ar_aging_asof(v_asof)%' THEN
        RAISE EXCEPTION 'FIXTURE 139J 失败:AR 不是 ar_aging_asof 来的 —— 那就是对账单印的那个数的第二份实现';
    END IF;
    IF v_src NOT LIKE '%ap_aging_asof(v_asof)%' THEN
        RAISE EXCEPTION 'FIXTURE 139J 失败:AP 不是 ap_aging_asof 来的';
    END IF;

    RAISE NOTICE 'fixture 139 · 现金预测 —— 十臂全部通过';
END $$;
ROLLBACK;
