-- 137 对账单:签发那一刻【冻住】,而且它与账龄【对得上】(STATEMENT-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉两件事,而它们的方向相反】
--   · **对得上** —— 期初 + 发生 − 贷记 − 核销 = 期末。期初/期末读 ar_aging_asof,
--     发生/贷记/核销走基表,**两份独立推导**;对不上按名拒,不寄给客户。
--   · **冻得住** —— 签发之后底下的数据再动,已签发的那一行【一个字不动】。
--     这一条只能靠"改了底下的数据再去读那一行"来证,而且必须断言
--     **重算出来的数与冻住的数确实不同** —— 否则"冻住了"与"什么都没发生"
--     在断言里长得一模一样。
--
-- ★【每一臂如何做到【按构造】非空】★
--   本仓库有过两次"检查对着空集通过"的账,其中一次那条检查正是为防这个而写的。
--   所以这里每一条断言都先证明【它测的那件事真的发生了】:
--   等式的每一项都非零、冻结前后的重算值确实分开、拒绝臂都先证明它拒的不是空。
--
-- 自带数据(README 第 2 条);期间锁、GST 开关自己设(第 4/5 条)。
-- 日期一律相对 CURRENT_DATE 之前 —— customer_statement_data 拒绝未来期末。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    r_all   uuid;
    v_ccy   text;
    v_bank  text;
    v_cust  uuid; v_mat uuid; v_ob uuid; v_sale uuid; v_sale2 uuid;
    v_st1   uuid; v_st2 uuid; v_res jsonb; v_d jsonb;
    d_from  date := CURRENT_DATE - 40;
    d_to    date := CURRENT_DATE - 10;
    v_open0 numeric; v_close0 numeric; v_recv0 numeric; v_appl0 numeric; v_onacct0 numeric;
    v_close1 numeric; v_frozen numeric; v_recomputed numeric;
    v_n int; v_n2 int; v_msg text; v_denied boolean; v_txt text;
    v_lines jsonb;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-137', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 前提显式设定(README 第 5 条)。这一份【两个都要设】,而且第二个是被
    -- 一次失败教出来的:
    --   · 期间锁 —— 会挡住 record_payment 的分录;
    --   · **GST 开关 —— 已注册时,一笔【挂账】的客户收款根本写不进去**
    --     (`GST_UNALLOCATED_RECEIPT_UNSUPPORTED`,GST-2 立的那条「孰早」的另一半:
    --      收款那一刻没有任何东西说得出这笔钱对应哪一项供应,所以按名拦住)。
    --     而本 fixture 的 A 臂【正是】要一笔挂账收款来把"收款 ≠ 核销"分开。
    --     所以它是一个真前提,不是顺手设的。
    -- 【线上关不掉,而这不影响本 fixture】线上有在册的带税发票时 guard_gst_switch
    -- 会正确地拒绝关闭;fixture 跑在【重建库】上,那里一张带税发票都没有。
    UPDATE finance_settings SET locked_before = NULL,
                                gst_registered = false, gst_registration_no = NULL;

    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    v_bank := bank_account_for_currency(v_ccy);

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ-F137-C', 'fixture 137 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-F137-M', 'fixture 137 material', 'battery_material', true,
            'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'ZZ-F137-OB', 500, 500, 'kg', d_from - 5, '库存中', v_cust) RETURNING id INTO v_ob;

    -- 期间【之前】的一笔销售 → 它构成期初余额(否则期初恒为 0,A 臂就是 0=0)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 100, 10, v_ccy, 1, 1000, d_from - 3) RETURNING id INTO v_sale;

    -- 期间【之内】的一笔销售 → 发生额
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 200, 10, v_ccy, 1, 2000, d_from + 5) RETURNING id INTO v_sale2;

    -- 期间之内的一笔【有核销的】收款 → 核销额
    PERFORM record_payment('in', v_cust, 600, v_ccy, NULL, v_bank, d_from + 10, 'fixture 137 收款',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 600)));

    -- 期间之内的一笔【完全挂账】的收款 → 收款额有它,核销额没有它
    PERFORM record_payment('in', v_cust, 150, v_ccy, NULL, v_bank, d_from + 12, 'fixture 137 挂账');

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 等式成立,而且【每一项都非零】—— 否则这条勾稽是 0 = 0
    -- ══════════════════════════════════════════════════════════════════════
    v_d := customer_statement_data(v_cust, d_from, d_to);

    v_open0   := (v_d->>'opening_base')::numeric;
    v_close0  := (v_d->>'closing_base')::numeric;
    v_recv0   := (v_d->>'receipts_base')::numeric;
    v_appl0   := (v_d->>'applied_base')::numeric;
    v_onacct0 := (v_d->>'on_account_base')::numeric;

    IF (v_d->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 137A 失败:等式不成立,差 % —— 期初 % 发生 % 贷记 % 核销 % 期末 %',
            (v_d->>'tie_difference'), v_open0, (v_d->>'charges_base'),
            (v_d->>'credits_base'), v_appl0, v_close0;
    END IF;

    -- ★ 自证非空:每一项都必须真的有数,否则"对得上"什么都没证明
    IF v_open0 = 0 OR (v_d->>'charges_base')::numeric = 0 OR v_appl0 = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137A 失败(空转):期初/发生/核销里有 0 —— 这条等式退化成了 0 = 0(期初 % 发生 % 核销 %)',
            v_open0, (v_d->>'charges_base'), v_appl0;
    END IF;

    -- ★【收款 ≠ 核销】那一条要真的分开:挂账的 150 在收款里、不在核销里
    IF v_recv0 <= v_appl0 THEN
        RAISE EXCEPTION 'FIXTURE 137A 失败(空转):收款(%)没有大于核销(%) —— 那笔挂账收款没有成立,「收款≠核销」这一半没被测到',
            v_recv0, v_appl0;
    END IF;
    IF v_onacct0 <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 137A 失败:挂账余额应当为正,实得 %', v_onacct0;
    END IF;
    -- 挂账【不进】期末余额(期末是各单据未结额之和),但要进净欠
    IF (v_d->>'net_due_base')::numeric <> round(v_close0 - v_onacct0, 2) THEN
        RAISE EXCEPTION 'FIXTURE 137A 失败:净欠应为 期末 − 挂账 = %,实得 %',
            round(v_close0 - v_onacct0, 2), (v_d->>'net_due_base');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · 签发,然后【改底下的数据】,冻住的那一行必须一个字不动
    --
    -- ★ 这一臂断言的是【存下来的那一行】,不是函数的返回值 ★
    -- ══════════════════════════════════════════════════════════════════════
    v_res := issue_customer_statement(v_cust, d_from, d_to);
    v_st1 := (v_res->>'statement_id')::uuid;

    SELECT closing_base, lines INTO v_frozen, v_lines
      FROM customer_statements WHERE id = v_st1;
    IF v_frozen IS DISTINCT FROM v_close0 THEN
        RAISE EXCEPTION 'FIXTURE 137B 布景不成立:冻下来的期末(%)与算出来的(%)应当相同', v_frozen, v_close0;
    END IF;
    IF jsonb_array_length(v_lines) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137B 失败(空转):冻下来的明细是空的 —— 后面"明细也冻住了"就无从谈起';
    END IF;

    -- 【改底下的数据】:期间【之内】再收一笔并核销掉,期末余额必然变小
    PERFORM record_payment('in', v_cust, 400, v_ccy, NULL, v_bank, d_from + 20, 'fixture 137 事后收款',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale2, 'amount_doc', 400)));

    -- 重算:同一段期间,现在应当给出【不同的】期末
    v_recomputed := (customer_statement_data(v_cust, d_from, d_to)->>'closing_base')::numeric;

    -- ★ 自证非空:重算值必须真的变了,否则"冻住了"与"什么都没发生"分不开
    IF v_recomputed = v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 137B 失败(空转):改了数据之后重算值仍是 % —— 这一臂根本没有把两者分开,冻结无从证明', v_frozen;
    END IF;

    -- ★ 而【存下来的那一行】必须还是老样子
    SELECT closing_base INTO v_close1 FROM customer_statements WHERE id = v_st1;
    IF v_close1 IS DISTINCT FROM v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 137B 失败:已签发的那一行被后来的数据改动了 —— 冻住的是 %,现在读到 %',
            v_frozen, v_close1;
    END IF;
    -- 明细也没动
    SELECT lines INTO v_lines FROM customer_statements WHERE id = v_st1;
    IF (SELECT count(*) FROM jsonb_array_elements(v_lines)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137B 失败:冻下来的明细不见了';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · 同一段期间再出一次 = 【新的一行】+ 旧的被标掉,而理由是必填的
    -- ══════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM issue_customer_statement(v_cust, d_from, d_to);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('STATEMENT_SUPERSEDE_REASON_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137C 失败:重出必须按名要理由(STATEMENT_SUPERSEDE_REASON_REQUIRED),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;

    v_res := issue_customer_statement(v_cust, d_from, d_to, 'fixture 137 更正:事后收到一笔款');
    v_st2 := (v_res->>'statement_id')::uuid;
    IF v_st2 = v_st1 THEN
        RAISE EXCEPTION 'FIXTURE 137C 失败:重出应当是【新的一行】,实得同一个 id';
    END IF;
    -- 旧行被标掉,但【没有被改数】
    SELECT superseded_at IS NOT NULL, closing_base INTO v_denied, v_close1
      FROM customer_statements WHERE id = v_st1;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 137C 失败:旧的那一份应当落 superseded_at';
    END IF;
    IF v_close1 IS DISTINCT FROM v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 137C 失败:被取代【不等于】被改写 —— 旧行的期末应仍是 %,实得 %',
            v_frozen, v_close1;
    END IF;
    -- 新行拿到的是【现在】的数
    SELECT closing_base INTO v_close1 FROM customer_statements WHERE id = v_st2;
    IF v_close1 IS DISTINCT FROM v_recomputed THEN
        RAISE EXCEPTION 'FIXTURE 137C 失败:新的那一份应当是重算值 %,实得 %', v_recomputed, v_close1;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · 签发档:一行对账单的 PDF 版本自成一层,而且只可追加
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM record_statement_issue(v_st2, 'statement-documents/zz-f137-v1.pdf',
                                   repeat('a', 64));
    PERFORM record_statement_issue(v_st2, 'statement-documents/zz-f137-v2.pdf',
                                   repeat('b', 64));
    SELECT count(*), max(version) INTO v_n, v_n2 FROM statement_issues WHERE statement_id = v_st2;
    IF v_n <> 2 OR v_n2 <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 137D 失败:两次签发应当是 v1/v2 两行,实得 % 行 最大版本 %', v_n, v_n2;
    END IF;
    -- 只可追加
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE statement_issues SET file_path = 'x' WHERE statement_id = v_st2 AND version = 1;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 137D 失败:签发档必须只可追加 —— 改得动 v1';
    END IF;

    -- 【被取代的那一份不再签发新版】
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_statement_issue(v_st1, 'statement-documents/zz-f137-old.pdf', repeat('c', 64));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('STATEMENT_SUPERSEDED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137D 失败:被取代的对账单不该再出新版(STATEMENT_SUPERSEDED),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 ·【这一臂【不在】fixture 里,而这句话本身就是结论】
    --
    -- 勾稽拦不拦得住,只能靠【让它算错】来证。而本刀试过三条"用合法数据把它
    -- 弄不平"的路,三条都失败了,原因值得写下来:
    --   · 改一张销售记录的金额 → `SALE_IMMUTABLE`,库直接拒(销售记录不可改);
    --   · 期间外的收款去核销 → 它同时减少期初【与】期末,等式照样成立;
    --   · 别的客户的收款核销到本客户单据 → 两边都按【单据归属】算,照样成立。
    -- **也就是说:这条等式用合法数据很难弄不平 —— 那是它的一个好性质,
    --   而不是它没被测到。** 它的故障注入因此放在【函数那一层】,与 AGING-1、
    --   PROBATION-1 两刀的做法一致:把 customer_statement_data 的某一项改错,
    --   再断言 issue_customer_statement 按名拒 STATEMENT_DOES_NOT_TIE。
    -- 那一次注入的结果记在本刀的报告里;这里留下这段话,是为了让下一个
    -- 读这份 fixture 的人不会以为"这条拒绝没有人验过"。
    -- ══════════════════════════════════════════════════════════════════════

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · 三条按名拒绝(查无此人 / 期间倒置 / 期末在未来)
    -- ══════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM customer_statement_data(gen_random_uuid(), d_from, d_to);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('CUSTOMER_NOT_FOUND' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137F① 失败:查无此人必须按名拒,实得:%', COALESCE(v_msg,'(通过了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM customer_statement_data(v_cust, d_to, d_from);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('STATEMENT_PERIOD_INVALID' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137F② 失败:期间倒置必须按名拒,实得:%', COALESCE(v_msg,'(通过了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM customer_statement_data(v_cust, d_from, CURRENT_DATE + 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('STATEMENT_PERIOD_FUTURE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 137F③ 失败:未来的期末必须按名拒,实得:%', COALESCE(v_msg,'(通过了)');
    END IF;
    -- 而【今天】必须不被拒 —— 否则一个"什么都拒"的实现也能通过上面三条
    PERFORM customer_statement_data(v_cust, d_from, CURRENT_DATE);

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · 期间内什么都没发生,是【一个有名字的状态】,不是一张空表
    -- ══════════════════════════════════════════════════════════════════════
    v_d := customer_statement_data(v_cust, d_to + 1, d_to + 2);
    IF (v_d->>'no_movement')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 137G 失败:这一小段期间里什么都没发生,no_movement 应为真';
    END IF;
    -- ★ 自证非空:它【不是】因为这个客户什么都没有 —— 期初必须仍然是正的,
    --   也就是说"没有发生额"与"没有余额"确实是两件事
    IF (v_d->>'opening_base')::numeric <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 137G 失败(空转):期初是 % —— 这一臂测的是"没有发生额但有余额",而这里连余额都没有',
            (v_d->>'opening_base');
    END IF;
    IF (v_d->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 137G 失败:没有发生额的期间同样必须对得上';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 · 期初/期末【真的读 ar_aging_asof】,不是自己又算了一遍
    --
    -- 【先剥注释再比调用】上一刀的教训:直接对 functiondef 做 LIKE,会匹配到
    -- 解释性注释里的同名字样 —— 那样的断言读到的是注释,不是代码,而它会被信。
    -- ══════════════════════════════════════════════════════════════════════
    IF regexp_replace(pg_get_functiondef('public.customer_statement_data(uuid,date,date)'::regprocedure),
                      '--[^' || chr(10) || ']*', '', 'g')
         NOT LIKE '%ar_aging_asof(%' THEN
        RAISE EXCEPTION 'FIXTURE 137H 失败:customer_statement_data 没有【调用】ar_aging_asof —— 期初期末被另算了一遍,而那是客户会拿来跟你对的那个数';
    END IF;
    -- 签发那一支也必须读【同一支算法】,不许自己再算
    IF regexp_replace(pg_get_functiondef('public.issue_customer_statement(uuid,date,date,text)'::regprocedure),
                      '--[^' || chr(10) || ']*', '', 'g')
         NOT LIKE '%customer_statement_data(%' THEN
        RAISE EXCEPTION 'FIXTURE 137H 失败:issue_customer_statement 没有调用 customer_statement_data —— 预览与签发成了两份实现';
    END IF;
END $$;
ROLLBACK;
