-- 131 银行与账面对不上时,对账单对不了账 —— 而差额【说得清】就还是对得了(BANK-REC)
--
-- 【这份 fixture 钉住的五件事】
--   (A) **余额一致是一道独立的闸。** 所有行都处理完了 —— 行覆盖率这一关已经过 ——
--       而银行的期末余额与账面余额仍然不等,对账必须按名拒,并把【两个数字与差额】
--       都说出来。这正是 BANK-REC 之前缺的那一条:「已对账」曾经只断言行覆盖率。
--   (B) **两个数字相等时照常对得上。** 否则(A)可能只是"什么都拒"。
--   (C) **差额说得清 → 带着差额对账。** 合法的差额真实存在(未兑现的支票、时点差),
--       一道只会拒、不给出路的闸,人会绕过去。
--   (D) **说明的金额必须【恰好】等于差额。** 差一点也不行 —— 否则"这是原因"
--       只是一句放在差额旁边的注解,金额那一栏会退化成装饰。
--   (E) **没有差额就没有要解释的东西。** 反向的自相矛盾同样要拒。
--   (H) 记录与说明【都不可改、不可删】。
--
-- ★【每一臂的故障注入方向,以及它为什么不可能空转】★
--   (A) 注入的是【一条银行有、账上没有的钱】(120 的银行利息)。它必须先被
--       ignore 掉,否则拒绝会来自 LINES_OUTSTANDING —— 那就是"因为错的理由通过"。
--       所以 A 臂在调用之前【先断言未处理行数 = 0】:行这一关确实已经过了,
--       挡住它的只可能是余额那一关。
--   (D) 注入的是【少报 20】的说明。它走的是"有说明"那一支,BALANCE_DISAGREES
--       够不着它,所以这一臂只能由 VARIANCE_UNEXPLAINED 自己接住。
--   (C) 断言存下来的 difference **不是 0** —— 说明【不许把两个数字抹平】。
--       一份"解释完就相等了"的记录正是这条规矩要禁止的东西。
--
-- 自带数据(README 第 2 条)。locked_before 与 GST 开关自己设(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_fin uuid;
    v_maxyc date; d0 date; e1 date; e2 date;
    v_base text;
    v_s1 jsonb; v_s2 jsonb; v_s1_id uuid; v_s2_id uuid;
    v_l1 uuid; v_l2 uuid; v_l3 uuid;
    v_je_a jsonb; v_je_b jsonb; v_je_i jsonb;
    v_jl_a uuid; v_jl_b uuid;
    v_out integer; v_book numeric; v_diff numeric;
    v_res jsonb; v_recon uuid; v_item uuid;
    v_denied boolean; v_msg text;
    rep jsonb := '{}'::jsonb;
BEGIN
    -- ══════════ 布景 ══════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-131','f','f',true)
      RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_fin, unnest(ARRAY['module.finance.view','module.finance.edit']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_fin);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;
    d0 := GREATEST(DATE '2025-03-03', v_maxyc + 400);
    e1 := d0 + 27;
    e2 := e1 + 28;

    -- 前提显式设定(README 第 5 条):不继承任何运行时状态
    UPDATE finance_settings SET locked_before = NULL,
                                gst_registered = false, gst_registration_no = NULL;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ 第一期:账上 5000,银行 5120(差 120 的银行利息还没记) ══════════
    v_je_a := post_journal_entry(d0, 'fixture131 收款', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1000','side','debit', 'currency',v_base,'amount_ccy',5000),
        jsonb_build_object('account_code','4000','side','credit','currency',v_base,'amount_ccy',5000)));
    SELECT l.id INTO v_jl_a FROM journal_lines l JOIN accounts a ON a.id=l.account_id
     WHERE l.entry_id = (v_je_a->>'entry_id')::uuid AND a.code='1000';

    v_s1 := import_bank_statement('1000', d0, e1, 0, 5120, 'fixture131-a.csv', jsonb_build_array(
        jsonb_build_object('line_date', d0,   'description','收款',       'reference','R1','amount',5000),
        jsonb_build_object('line_date', d0+5, 'description','银行利息',   'reference','R2','amount',120)));
    v_s1_id := (v_s1->>'statement_id')::uuid;
    SELECT id INTO v_l1 FROM bank_statement_lines WHERE statement_id=v_s1_id AND line_no=1;
    SELECT id INTO v_l2 FROM bank_statement_lines WHERE statement_id=v_s1_id AND line_no=2;

    PERFORM match_bank_line(v_l1, ARRAY[v_jl_a]);
    -- 【故障注入就在这里】银行有、账上没有的 120:先把它 ignore 掉,
    -- 于是行这一关【确实过了】,而余额仍然差 120。
    PERFORM ignore_bank_line(v_l2, '银行利息,本期账上还没记');

    -- ══════════ A · 行都处理完了,余额仍然不等 → 必须按名拒 ══════════
    -- 【先证明行这一关已经过】否则 A 臂可能只是撞上了 LINES_OUTSTANDING,
    -- 那样它会因为一个与被测规则无关的理由变绿。
    SELECT count(*) FILTER (WHERE match_status='unmatched') INTO v_out
      FROM bank_statement_lines WHERE statement_id = v_s1_id;
    IF v_out <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 131 A 前提失败:未处理行应为 0(否则本臂测的是 LINES_OUTSTANDING 而不是余额),实得 %', v_out;
    END IF;
    v_book := bank_book_balance_asof('1000', e1);
    IF v_book <> 5000 THEN
        RAISE EXCEPTION 'FIXTURE 131 A 前提失败:账面余额应为 5000,实得 %', v_book;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM reconcile_statement(v_s1_id);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'BALANCE_DISAGREES|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 131 A 失败:行全部处理完、而银行 5120 与账面 5000 不等时,对账必须按名拒(BALANCE_DISAGREES)。实得 %',
            COALESCE(v_msg,'(对账成功了 —— 「已对账」又变回只断言行覆盖率)');
    END IF;
    -- 【拒绝要把两个数字与差额都说出来】只说"对不上"等于把人推回去自己算。
    -- 【按【数值】断言,不按字符串】numeric 的标度会让同一个数印成 5120 或 5120.00,
    -- 而那与被测的规矩毫无关系 —— 断言字面量就是在断言一个会漂的东西(README 第 1 条)。
    IF (split_part(v_msg,'|',2))::numeric <> 5120
       OR (split_part(v_msg,'|',3))::numeric <> 5000
       OR (split_part(v_msg,'|',4))::numeric <> -120 THEN
        RAISE EXCEPTION 'FIXTURE 131 A 失败:拒绝必须带上银行余额(5120)、账面余额(5000)与差额(-120),实得 %', v_msg;
    END IF;
    rep := rep || jsonb_build_object('A_refuses_on_unexplained_difference', v_msg);

    -- ══════════ D · 说明少报了 20 → 由 VARIANCE_UNEXPLAINED 自己接住 ══════════
    -- 【这一臂只能被它自己那条规矩接住】有说明 → 走不到 BALANCE_DISAGREES;
    -- 差额不为 0 → 走不到 VARIANCE_NOT_APPLICABLE。
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM reconcile_statement(v_s1_id, jsonb_build_array(
            jsonb_build_object('kind','bank_interest','amount','-100','note','银行利息(少报了 20)')));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'VARIANCE_UNEXPLAINED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 131 D 失败:逐项金额(-100)与差额(-120)不等时必须按名拒(VARIANCE_UNEXPLAINED),实得 %',
            COALESCE(v_msg,'(对账成功了 —— 金额那一栏成了装饰)');
    END IF;
    IF (split_part(v_msg,'|',2))::numeric <> -120
       OR (split_part(v_msg,'|',3))::numeric <> -100 THEN
        RAISE EXCEPTION 'FIXTURE 131 D 失败:拒绝必须说出差额(-120)与已解释额(-100),实得 %', v_msg;
    END IF;
    rep := rep || jsonb_build_object('D_refuses_when_items_do_not_sum', v_msg);

    -- ══════════ C · 说明【恰好】等于差额 → 带着差额对上 ══════════
    v_res := reconcile_statement(v_s1_id, jsonb_build_array(
        jsonb_build_object('kind','bank_interest','amount','-120','note','银行利息 120,本期账上还没记')));
    IF (v_res->>'difference')::numeric <> -120 THEN
        RAISE EXCEPTION 'FIXTURE 131 C 失败:对账应当【带着】差额 -120 完成,实得 %', v_res->>'difference';
    END IF;
    -- ★ 说明【不许把两个数字抹平】★ 冻下来的那一行必须仍然写着差 120。
    SELECT id, difference INTO v_recon, v_diff
      FROM bank_reconciliations WHERE statement_id = v_s1_id AND superseded_at IS NULL;
    IF v_diff <> -120 THEN
        RAISE EXCEPTION 'FIXTURE 131 C 失败:记录里的差额必须原样留着(-120),实得 % —— 解释把差额抹平了', v_diff;
    END IF;
    IF (SELECT count(*) FROM bank_reconciliation_variance_items WHERE reconciliation_id=v_recon) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 131 C 失败:那一条说明应当被记下来';
    END IF;
    IF (SELECT status FROM bank_statements WHERE id=v_s1_id) <> 'reconciled' THEN
        RAISE EXCEPTION 'FIXTURE 131 C 失败:报表应当是 reconciled —— 带着写明的差额';
    END IF;
    rep := rep || jsonb_build_object('C_reconciles_with_the_difference_stated', v_diff);

    -- ══════════ 第二期:把 120 记上,账面追平银行 ══════════
    v_je_i := post_journal_entry(e1+2, 'fixture131 补记银行利息', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1000','side','debit', 'currency',v_base,'amount_ccy',120),
        jsonb_build_object('account_code','4000','side','credit','currency',v_base,'amount_ccy',120)));
    v_je_b := post_journal_entry(e1+3, 'fixture131 第二期收款', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1000','side','debit', 'currency',v_base,'amount_ccy',300),
        jsonb_build_object('account_code','4000','side','credit','currency',v_base,'amount_ccy',300)));
    SELECT l.id INTO v_jl_b FROM journal_lines l JOIN accounts a ON a.id=l.account_id
     WHERE l.entry_id = (v_je_b->>'entry_id')::uuid AND a.code='1000';

    v_s2 := import_bank_statement('1000', e1+1, e2, 5120, 5420, 'fixture131-b.csv', jsonb_build_array(
        jsonb_build_object('line_date', e1+3, 'description','第二期收款','reference','R3','amount',300)));
    v_s2_id := (v_s2->>'statement_id')::uuid;
    SELECT id INTO v_l3 FROM bank_statement_lines WHERE statement_id=v_s2_id AND line_no=1;
    PERFORM match_bank_line(v_l3, ARRAY[v_jl_b]);

    v_book := bank_book_balance_asof('1000', e2);
    IF v_book <> 5420 THEN
        RAISE EXCEPTION 'FIXTURE 131 B 前提失败:第二期账面余额应为 5420,实得 %', v_book;
    END IF;

    -- ══════════ E · 没有差额,却给了说明 → 反向的自相矛盾也要拒 ══════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM reconcile_statement(v_s2_id, jsonb_build_array(
            jsonb_build_object('kind','timing','amount','-50','note','凭空捏一条')));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'VARIANCE_NOT_APPLICABLE%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 131 E 失败:两个数字本来就相等时,给说明必须按名拒(VARIANCE_NOT_APPLICABLE),实得 %',
            COALESCE(v_msg,'(收下了一份自相矛盾的记录)');
    END IF;
    rep := rep || jsonb_build_object('E_refuses_explanation_without_difference', true);

    -- ══════════ B · 两个数字相等 → 照常对得上 ══════════
    -- 【没有这一臂,(A)可能只是"什么都拒"】一道永远拒绝的闸与一道正确的闸,
    -- 在只测拒绝的 fixture 里长得一模一样。
    v_res := reconcile_statement(v_s2_id);
    IF (v_res->>'difference')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 131 B 失败:相等时差额应为 0,实得 %', v_res->>'difference';
    END IF;
    IF (SELECT status FROM bank_statements WHERE id=v_s2_id) <> 'reconciled' THEN
        RAISE EXCEPTION 'FIXTURE 131 B 失败:银行与账面相等时必须对得上 —— 否则这道闸只是"什么都拒"';
    END IF;
    rep := rep || jsonb_build_object('B_reconciles_when_they_agree', true);

    -- ══════════ H · 记录与说明都不可改、不可删 ══════════
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE bank_reconciliations SET book_balance = 999 WHERE id = v_recon;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'RECONCILIATION_IMMUTABLE%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 131 H1 失败:冻下来的对账记录不许改,实得 %', COALESCE(v_msg,'(改成功了)');
    END IF;

    SELECT id INTO v_item FROM bank_reconciliation_variance_items WHERE reconciliation_id=v_recon;
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM bank_reconciliation_variance_items WHERE id = v_item;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'VARIANCE_ITEM_IMMUTABLE%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 131 H2 失败:已记下的说明不许删,实得 %', COALESCE(v_msg,'(删成功了)');
    END IF;
    rep := rep || jsonb_build_object('H_record_and_items_immutable', true);

    -- 【成功不抛异常】gate 用 ON_ERROR_STOP=1 跑本目录;报告用 NOTICE,回滚在文件末尾。
    RAISE NOTICE 'FIXTURE 131 全部通过 %', rep::text;
END $$;
ROLLBACK;
