-- 138 催收:一条【发生过的对话】,以及一个【清得掉】的承诺(CHASE-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉四件事】
--   · **冻得住** —— 催收那一刻我们告诉他欠多少,记下来之后底下的数据再动,
--     那一行一个字不动。与 137 同一条,而这里的证法也一样:必须断言
--     **重算出来的数与冻住的数确实不同**,否则"冻住了"与"什么都没发生"
--     在断言里长得一模一样。
--   · **同一个数** —— 冻下来的欠款【就是】对账单那一支函数给的数,不是
--     另一份算法算出来的相同结果。目录断言钉住它真的在调那支函数。
--   · **清得掉** —— 承诺逾期会上仪表盘;记下结局之后那一支【消失】。
--     一个清不掉的告警会教会人忽略告警(hr_alerts 那次)。
--     所以本 fixture 必须先断言它【真的响过】,再断言它没了。
--   · **拒绝要按名,而且拒完什么都没写** —— 六条。
--
-- ★【每一臂如何做到【按构造】非空】★ 逐臂写在臂里,而不是在这里许诺一遍。
--
-- 自带数据(README 第 2 条);期间锁、GST 开关、汇率自己设(第 4/5 条)。
-- 日期一律相对 CURRENT_DATE —— 未来的催收日期按名拒。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_ccy    text;   -- 本位币
    v_fgn    text;   -- 一个非本位币,C 臂用
    v_bank   text;
    v_cust   uuid; v_cust0 uuid; v_mat uuid; v_ob uuid; v_sale uuid;
    v_inv    uuid;
    v_res    jsonb; v_ctx jsonb;
    v_chase  uuid; v_chase2 uuid; v_promise uuid; v_promise2 uuid;
    d_chase  date := CURRENT_DATE - 20;
    d_due    date := CURRENT_DATE - 5;    -- 已经过期的承诺日
    d_today  date := CURRENT_DATE;        -- 今天到期 —— 【不】算逾期
    v_frozen numeric; v_recomputed numeric; v_owed numeric;
    v_n int; v_n2 int; v_msg text; v_txt text;
    v_rate   numeric;
    v_before int; v_after int;
    v_src    text;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-138', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 前提显式设定,两个都是真前提:
    --   · 期间锁 —— 会挡住 record_payment 的分录(B 臂要一笔收款);
    --   · **GST 开关 —— 已注册时,一笔【挂账】的客户收款根本写不进去**
    --     (GST_UNALLOCATED_RECEIPT_UNSUPPORTED)。而 A 臂【正是】要一笔挂账收款:
    --     那是"欠款不能自己算一遍"唯一证得死的地方(见 A 臂里的说明)。
    UPDATE finance_settings SET locked_before = NULL,
                                gst_registered = false, gst_registration_no = NULL;

    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT code INTO v_fgn FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1;
    v_bank := bank_account_for_currency(v_ccy);

    -- ★【只给催收当天的汇率,【不】给承诺日的】★ —— C 臂正是要证明
    -- "按承诺日折算"这条路【走不通】,而它走不通是因为未来那天没有汇率。
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES (v_fgn, d_chase, 'tt_buy', 1.30);

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ-F138-C', 'fixture 138 customer', 'SG') RETURNING id INTO v_cust;
    -- 【第二个客户:一分钱都不欠】—— H 臂用
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ-F138-C0', 'fixture 138 owes nothing', 'SG') RETURNING id INTO v_cust0;

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-F138-M', 'fixture 138 material', 'battery_material', true,
            'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'ZZ-F138-OB', 500, 500, 'kg', d_chase - 10, '库存中', v_cust) RETURNING id INTO v_ob;

    -- 催收【之前】的一笔销售 → 它就是被催的那笔钱(否则欠款恒为 0,A 臂是 0=0)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 100, 30, v_ccy, 1, 3000, d_chase - 5) RETURNING id INTO v_sale;

    -- 催收之前的一笔【完全挂账】的收款 —— A 臂的关键道具,理由见 A 臂
    PERFORM record_payment('in', v_cust, 400, v_ccy, NULL, v_bank, d_chase - 2, 'fixture 138 挂账');

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 冻下来的欠款【就是】对账单那一支函数给的数
    -- ══════════════════════════════════════════════════════════════════════
    -- ★★【这一臂第一版是【假的】,记在这里因为它是本仓库记过的那个病】★★
    -- 第一版只断言两件事:欠款非零,且 owed = customer_statement_data 的 closing。
    -- 故障注入把 customer_collection_context 换成"自己 sum 一遍 ar_aging_asof",
    -- **fixture 全绿** —— 因为那个重写今天给出【一样的 closing】。
    -- 这正是 FIN-18 立的那条:**一条能靠"两个答案碰巧一致"通过的断言什么都没证明。**
    --
    -- 证得死的地方是【挂账的钱】:ar_aging_asof 加的是各单据的未结额,
    -- 一笔没核销任何单据的收款【一张单据都不冲】,所以任何"sum 一遍 open_base"
    -- 的重写都必然得到 on_account = 0、net_due = owed。而对账单那一支函数
    -- 知道这笔钱(STATEMENT-1 就是在这里栽过一次,线上两个客户对不上)。
    -- 于是这一臂断言的是【那个重写做不到的部分】。
    v_ctx := customer_collection_context(v_cust, d_chase);
    v_owed := (v_ctx->>'owed_base')::numeric;

    -- ★ 自证非空 ①:欠 0 块钱的催收证明不了"两个数一样"
    IF v_owed = 0 THEN
        RAISE EXCEPTION 'FIXTURE 138A 失败(空转):催收当天欠款是 0 —— 这一臂要证的是"冻的那个数就是对账单那个数",而 0 = 0 什么都不证明';
    END IF;
    -- ★ 自证非空 ②:挂账的钱必须真的存在,否则下面那条断言退化成 0 = 0
    IF (v_ctx->>'on_account_base')::numeric = 0 THEN
        RAISE EXCEPTION 'FIXTURE 138A 失败(空转):挂账额是 0 —— 而它正是"重写一遍必然答错"的那一项,没有它这一臂又变回一条能碰巧通过的断言';
    END IF;

    -- 它必须与【对账单那一支函数】的单日窗口逐分逐厘相等 —— 三个数,不是一个
    IF v_owed <> (customer_statement_data(v_cust, d_chase, d_chase)->>'closing_base')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 138A 失败:催收上下文说欠 %,而对账单那一支函数说 % —— 同一个客户被报出两个数字,这正是本刀要杜绝的那件事',
            v_owed, (customer_statement_data(v_cust, d_chase, d_chase)->>'closing_base')::numeric;
    END IF;
    IF (v_ctx->>'on_account_base')::numeric
       <> (customer_statement_data(v_cust, d_chase, d_chase)->>'on_account_base')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 138A 失败:挂账额与对账单那一支函数不一致(% vs %)—— 欠款被【重新算了一遍】,而重算的那份看不见没核销的钱',
            (v_ctx->>'on_account_base')::numeric,
            (customer_statement_data(v_cust, d_chase, d_chase)->>'on_account_base')::numeric;
    END IF;
    -- 净应收 = 欠款 − 挂账。重写一遍的那份会让这两个数相等,而这里它们【必须分开】。
    IF (v_ctx->>'net_due_base')::numeric <> round(v_owed - (v_ctx->>'on_account_base')::numeric, 2) THEN
        RAISE EXCEPTION 'FIXTURE 138A 失败:净应收 % 不等于 欠款 % − 挂账 %',
            (v_ctx->>'net_due_base')::numeric, v_owed, (v_ctx->>'on_account_base')::numeric;
    END IF;

    v_res := record_collection_chase(
        p_customer_id => v_cust, p_chased_on => d_chase, p_channel => 'phone',
        p_reached => true, p_summary => '打给财务,对方说这周会安排',
        p_contacted_person => 'Ms Lim');
    v_chase := (v_res->>'chase_id')::uuid;

    SELECT owed_base INTO v_frozen FROM collection_chases WHERE id = v_chase;
    IF v_frozen <> v_owed THEN
        RAISE EXCEPTION 'FIXTURE 138A 失败:冻下来的是 %,而当时上下文给的是 %', v_frozen, v_owed;
    END IF;
    IF (SELECT code FROM collection_chases WHERE id = v_chase) NOT LIKE 'CHASE-%' THEN
        RAISE EXCEPTION 'FIXTURE 138A 失败:取号不对 —— %',
            (SELECT code FROM collection_chases WHERE id = v_chase);
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · 记完之后【改底下的数据】,冻住的那一行一个字不动
    -- ══════════════════════════════════════════════════════════════════════
    -- 收一笔钱并核销掉一半 —— 今天再算,欠款就变了
    PERFORM record_payment('in', v_cust, 1200, v_ccy, NULL, v_bank, d_chase + 1, 'fixture 138 收款',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1200)));

    v_recomputed := (customer_statement_data(v_cust, d_chase, CURRENT_DATE)->>'closing_base')::numeric;

    -- ★ 自证非空:两个数必须真的分开,否则"冻住了"与"什么都没发生"没法区分
    IF v_recomputed = v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 138B 失败(空转):改了数据之后重算仍是 % —— 这一臂根本没把两者分开,冻结无从证明', v_frozen;
    END IF;

    SELECT owed_base INTO v_owed FROM collection_chases WHERE id = v_chase;
    IF v_owed <> v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 138B 失败:底下的数据变了之后,冻住的那一行从 % 变成了 % —— 它没有被冻住',
            v_frozen, v_owed;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · 承诺按【催收当天】折算 —— 而按承诺日折算这条路【走不通】
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 自证非空:两个日期必须真的不同,而且承诺日那天【真的没有汇率】,
    --   否则这一臂证明的只是"两条路碰巧一样"
    IF d_due <= d_chase THEN
        RAISE EXCEPTION 'FIXTURE 138C 失败(空转):承诺日与催收日没有分开';
    END IF;
    IF EXISTS (SELECT 1 FROM fx_rates WHERE currency = v_fgn AND rate_date = d_due
                 AND rate_type = 'tt_buy' AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 138C 失败(空转):承诺日那天居然有汇率 —— 这一臂要证的正是"那天没有汇率,所以口径只能是催收日"';
    END IF;

    v_res := record_collection_chase(
        p_customer_id => v_cust, p_chased_on => d_chase, p_channel => 'email',
        p_reached => true, p_summary => '对方回邮件,答应付一笔美金',
        p_contacted_person => 'Mr Ong',
        p_promise => jsonb_build_object('amount', 1000, 'currency', v_fgn,
                                        'promised_date', d_due::text));
    v_promise := (v_res->>'promise_id')::uuid;
    IF v_promise IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 138C 失败:给了承诺,却没有建出承诺行';
    END IF;

    SELECT fx_rate, promised_amount_base INTO v_rate, v_owed
      FROM collection_promises WHERE id = v_promise;
    IF v_rate <> 1.30 OR v_owed <> 1300.00 THEN
        RAISE EXCEPTION 'FIXTURE 138C 失败:本位币等值应当按【催收当天】的 1.30 折成 1300.00,实得 rate=% base=%',
            v_rate, v_owed;
    END IF;
    -- 而且要证明"按承诺日折算"确实是【不可能】的,不是我们懒得做
    BEGIN
        v_rate := fx_rate_for(v_fgn, d_due, 'tt_buy');
        RAISE EXCEPTION 'FIXTURE 138C 失败:承诺日 % 居然折算得出来(%) —— 那这一臂选的口径就没有理由了', d_due, v_rate;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'FX_RATE_MISSING%' THEN
            RAISE EXCEPTION 'FIXTURE 138C 失败:按承诺日折算应当报 FX_RATE_MISSING,实得 %', v_msg;
        END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · 逾期从承诺日的【第二天】起 —— 今天到期的今天【不】逾期
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_collection_chase(
        p_customer_id => v_cust, p_chased_on => CURRENT_DATE, p_channel => 'whatsapp',
        p_reached => true, p_summary => '今天到期的那一笔,他说今天会打',
        p_promise => jsonb_build_object('amount', 500, 'currency', v_ccy,
                                        'promised_date', d_today::text));
    v_promise2 := (v_res->>'promise_id')::uuid;

    -- ★ 自证非空:两个承诺都要在,而且一个过期一个今天到期
    IF v_promise IS NULL OR v_promise2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 138D 失败(空转):两个承诺没有都建出来';
    END IF;
    IF NOT (SELECT is_overdue FROM collection_promise_status WHERE promise_id = v_promise) THEN
        RAISE EXCEPTION 'FIXTURE 138D 失败:承诺日 %(已过)应当算逾期', d_due;
    END IF;
    IF (SELECT is_overdue FROM collection_promise_status WHERE promise_id = v_promise2) THEN
        RAISE EXCEPTION 'FIXTURE 138D 失败:承诺日是【今天】的那一笔被算成了逾期 —— 今天到期的承诺今天还没有被辜负';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · ★【清得掉】★ 仪表盘那一支要先【真的响过】,再消失
    -- ══════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_before FROM operations_now
     WHERE item_type = 'promise_overdue' AND item_id = v_promise;
    -- ★ 自证非空:它必须先响。只断言"记完结局之后是 0",一个【从来不响】的
    --   实现照样全绿 —— 而那正是这一支存在的理由被架空的样子。
    IF v_before <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 138E 失败(空转):逾期的承诺没有出现在 operations_now 上(实得 % 行)—— 还没开始证"清得掉",它就没响过', v_before;
    END IF;

    PERFORM record_promise_outcome(v_promise, 'broken', '到期没到账');

    SELECT count(*) INTO v_after FROM operations_now
     WHERE item_type = 'promise_overdue' AND item_id = v_promise;
    IF v_after <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 138E 失败:记下结局之后那一支还在(% 行)—— 一个清不掉的告警会教会人忽略告警', v_after;
    END IF;

    -- 结局记下之后不可改
    BEGIN
        PERFORM record_promise_outcome(v_promise, 'kept', '改主意');
        RAISE EXCEPTION 'FIXTURE 138E 失败:同一个承诺的结局被改了第二次';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PROMISE_OUTCOME_ALREADY_RECORDED%' THEN
            RAISE EXCEPTION 'FIXTURE 138E 失败:应当报 PROMISE_OUTCOME_ALREADY_RECORDED,实得 %', v_msg;
        END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · 六条按名拒,而且【拒完什么都没写】
    -- ══════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM collection_chases;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 138F 失败(空转):此刻一条催收都没有 —— "拒完没多出行"这句话要有一个非零的基线才有意义';
    END IF;

    -- ① 未来的催收日
    BEGIN
        PERFORM record_collection_chase(v_cust, CURRENT_DATE + 1, 'phone', true, '明天打的');
        RAISE EXCEPTION 'FIXTURE 138F① 失败:未来的催收日没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'CHASE_DATE_FUTURE%' THEN
            RAISE EXCEPTION 'FIXTURE 138F① 失败:应报 CHASE_DATE_FUTURE,实得 %', v_msg;
        END IF;
    END;
    -- ② 没有内容 —— 「对方说了什么」是这条记录存在的理由
    BEGIN
        PERFORM record_collection_chase(v_cust, d_chase, 'phone', true, '   ');
        RAISE EXCEPTION 'FIXTURE 138F② 失败:空白 summary 没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'CHASE_SUMMARY_REQUIRED%' THEN
            RAISE EXCEPTION 'FIXTURE 138F② 失败:应报 CHASE_SUMMARY_REQUIRED,实得 %', v_msg;
        END IF;
    END;
    -- ③ 没联系上人,却带着一个承诺
    BEGIN
        PERFORM record_collection_chase(v_cust, d_chase, 'phone', false, '没人接',
            NULL, '[]'::jsonb,
            jsonb_build_object('amount', 100, 'currency', v_ccy, 'promised_date', d_due::text));
        RAISE EXCEPTION 'FIXTURE 138F③ 失败:"没人接电话但他答应了付款"没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PROMISE_REQUIRES_CONTACT%' THEN
            RAISE EXCEPTION 'FIXTURE 138F③ 失败:应报 PROMISE_REQUIRES_CONTACT,实得 %', v_msg;
        END IF;
    END;
    -- ④ 承诺日早于通话日
    BEGIN
        PERFORM record_collection_chase(v_cust, d_chase, 'phone', true, '打错字的那一条',
            NULL, '[]'::jsonb,
            jsonb_build_object('amount', 100, 'currency', v_ccy,
                               'promised_date', (d_chase - 1)::text));
        RAISE EXCEPTION 'FIXTURE 138F④ 失败:承诺日早于通话日没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PROMISE_DATE_BEFORE_CHASE%' THEN
            RAISE EXCEPTION 'FIXTURE 138F④ 失败:应报 PROMISE_DATE_BEFORE_CHASE,实得 %', v_msg;
        END IF;
    END;
    -- ⑤ 引用【别人家的】单据
    BEGIN
        PERFORM record_collection_chase(v_cust0, d_chase, 'phone', true, '谈了一张不属于他的单据',
            NULL,
            jsonb_build_array(jsonb_build_object('subject_type', 'sales_record',
                                                 'subject_id', v_sale::text)));
        RAISE EXCEPTION 'FIXTURE 138F⑤ 失败:引用别人家的单据没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'CHASE_DOCUMENT_NOT_THIS_CUSTOMER%' THEN
            RAISE EXCEPTION 'FIXTURE 138F⑤ 失败:应报 CHASE_DOCUMENT_NOT_THIS_CUSTOMER,实得 %', v_msg;
        END IF;
    END;
    -- ⑥ 不认识的币种
    BEGIN
        PERFORM record_collection_chase(v_cust, d_chase, 'phone', true, '用一个不存在的币种承诺',
            NULL, '[]'::jsonb,
            jsonb_build_object('amount', 100, 'currency', 'ZZZ', 'promised_date', d_due::text));
        RAISE EXCEPTION 'FIXTURE 138F⑥ 失败:未知币种没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PROMISE_CURRENCY_UNKNOWN%' THEN
            RAISE EXCEPTION 'FIXTURE 138F⑥ 失败:应报 PROMISE_CURRENCY_UNKNOWN,实得 %', v_msg;
        END IF;
    END;

    -- 【拒完什么都没写】—— 六次拒绝之后,行数必须与拒之前一模一样
    SELECT count(*) INTO v_n2 FROM collection_chases;
    IF v_n2 <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 138F 失败:六次拒绝之后催收行数从 % 变成了 % —— 一次拒绝留下了半条记录', v_n, v_n2;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · 更正 = 新起一行 + 旧行标掉;而【已记结局的承诺】上的更正按名拒
    -- ══════════════════════════════════════════════════════════════════════
    -- 先证明那个前提真的成立:v_promise 的结局在 E 臂已经记下了
    IF (SELECT outcome FROM collection_promises WHERE id = v_promise) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 138G 失败(空转):那个承诺没有结局 —— 这一臂拒的正是"有结局的不许被抹掉"';
    END IF;
    -- 找到 v_promise 挂着的那条催收
    SELECT chase_id INTO v_chase2 FROM collection_promises WHERE id = v_promise;
    BEGIN
        PERFORM record_collection_chase(v_cust, d_chase, 'phone', true, '其实我记错了',
            NULL, '[]'::jsonb, NULL, v_chase2, '记错了对方的名字');
        RAISE EXCEPTION 'FIXTURE 138G 失败:一条【承诺已有结局】的催收被更正掉了 —— 那会抹掉一件关于世界的事实';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'CHASE_SUPERSEDE_OUTCOME_RECORDED%' THEN
            RAISE EXCEPTION 'FIXTURE 138G 失败:应报 CHASE_SUPERSEDE_OUTCOME_RECORDED,实得 %', v_msg;
        END IF;
    END;
    -- 理由必填
    BEGIN
        PERFORM record_collection_chase(v_cust, d_chase, 'phone', true, '更正但不给理由',
            NULL, '[]'::jsonb, NULL, v_chase, NULL);
        RAISE EXCEPTION 'FIXTURE 138G 失败:更正没给理由却过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'CHASE_SUPERSEDE_REASON_REQUIRED%' THEN
            RAISE EXCEPTION 'FIXTURE 138G 失败:应报 CHASE_SUPERSEDE_REASON_REQUIRED,实得 %', v_msg;
        END IF;
    END;
    -- 正路:新起一行,旧行标掉、【不删】
    v_res := record_collection_chase(v_cust, d_chase, 'phone', true, '更正:接电话的是 Ms Lee',
        'Ms Lee', '[]'::jsonb, NULL, v_chase, '把接电话的人记错了');
    IF (SELECT superseded_at FROM collection_chases WHERE id = v_chase) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 138G 失败:旧行没有被标成 superseded';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM collection_chases WHERE id = v_chase) THEN
        RAISE EXCEPTION 'FIXTURE 138G 失败:旧行被【删掉】了 —— 更正是留痕,不是抹除';
    END IF;
    IF (SELECT superseded_by FROM collection_chases WHERE id = v_chase)
       <> (v_res->>'chase_id')::uuid THEN
        RAISE EXCEPTION 'FIXTURE 138G 失败:旧行没有指向取代它的那一行';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 · ★【规则的主语可以缺席】★ 一分钱都不欠的客户,照样催得了
    -- ══════════════════════════════════════════════════════════════════════
    -- AGENTS.md 记着 fixture 39 那次:每一条断言都传了一个客户,没有一条问
    -- 「根本没有客户会怎样」。这里的主语是【欠款】,而它可以是 0 ——
    -- 催在到期之前、或者他在通话中把钱付清了,都是真事。
    -- 这一臂的断言【不是"它拒绝"】,而是明写它【允许】,并且那个 0 是真的 0。
    v_owed := (customer_collection_context(v_cust0, d_chase)->>'owed_base')::numeric;
    IF v_owed <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 138H 失败(空转):这个客户欠 % —— 这一臂要的正是"欠款为零"这个缺席的主语', v_owed;
    END IF;
    v_res := record_collection_chase(v_cust0, d_chase, 'letter', false,
        '寄了一封提醒函,还没有回音');
    IF (v_res->>'chase_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 138H 失败:欠款为零的客户催不了 —— 而催在到期之前是一件真事';
    END IF;
    IF (SELECT owed_base FROM collection_chases WHERE id = (v_res->>'chase_id')::uuid) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 138H 失败:欠款为零,冻下来的却不是 0';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- I 臂 · 目录断言:它【真的在调】对账单那一支函数,不是自己又算了一遍
    -- ══════════════════════════════════════════════════════════════════════
    -- 【先把注释剥掉再匹配】fixture 136 曾经匹配到了一句【注释】而不是一次调用,
    -- 于是那条断言在实现被换掉之后照样绿。这里逐字沿用那次的教训。
    SELECT string_agg(l, E'\n') INTO v_src
      FROM (SELECT regexp_replace(l, '--.*$', '') AS l
              FROM regexp_split_to_table(
                     pg_get_functiondef('public.customer_collection_context(uuid,date)'::regprocedure),
                     E'\n') AS l) q;
    -- ★【断言的是【那一次赋值】,不是"文件里提到过它"】★
    -- 第一版写的是 LIKE '%customer_statement_data(%',而故障注入证明它【抓不住】:
    -- 把欠款那一行换成自己算,函数体里【别处】(承诺证据那一段)仍然在调它,
    -- 于是子串还在、断言照绿。与 fixture 136 匹配到一句【注释】是同一个病 ——
    -- 一条"提到过就算数"的断言,守的是措辞,不是行为。
    IF v_src NOT LIKE '%v_data := customer_statement_data(p_customer_id, p_as_of, p_as_of)%' THEN
        RAISE EXCEPTION 'FIXTURE 138I 失败:customer_collection_context 里那个欠款数【不是】customer_statement_data 单日窗口赋值来的 —— 它被重新算了一遍,而两份实现一定会漂开';
    END IF;

    SELECT string_agg(l, E'\n') INTO v_src
      FROM (SELECT regexp_replace(l, '--.*$', '') AS l
              FROM regexp_split_to_table(
                     pg_get_functiondef('public.record_collection_chase(uuid,date,text,boolean,text,text,jsonb,jsonb,uuid,text)'::regprocedure),
                     E'\n') AS l) q;
    IF v_src NOT LIKE '%customer_collection_context(%' THEN
        RAISE EXCEPTION 'FIXTURE 138I 失败:record_collection_chase 里【没有】调用 customer_collection_context —— 冻下来的数不是对账单那个数';
    END IF;

    RAISE NOTICE 'fixture 138 · 催收 —— 九臂全部通过';
END $$;
ROLLBACK;
