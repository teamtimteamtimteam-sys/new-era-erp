-- 28 同一个期间,损益表【剔除】年结分录,资产负债表【包含】它 —— 而两边都自洽
--
-- 【为什么值得常设(OPS-16)】这条不对称此前只活在两个页面的注释里,靠"改任何一边
-- 前先读两边"这句话维持。OPS-16 把两张表搬进数据库(pnl_statement / balance_sheet),
-- 而【搬家最容易弄丢的就是这种不对称】:它看起来像是两处不一致,顺手"修平"就没了。
--
-- 【它错了会怎样,两个方向都不报错】
--   * 损益表若不剔除:结转分录把损益科目冲成零,【已结年度的损益表整表归零】——
--     去年的报表从此不可复现,而屏幕上只是一堆 0.00,不是错误。
--   * 资产负债表若剔除:权益里 3100 那一行消失,金额跑回"本期损益"合成行 ——
--     【合计仍然相等、仍然平】,所以看总数永远发现不了。这就是本 fixture 必须
--     断言【拆分】而不是断言合计的原因(见 C 臂)。
--
-- 【断言的是不变量,不是数字】本期损益 + 权益科目合计,在结转前后【相等】;
-- 变的只是这笔钱记在哪一行。金额由插入值算出来,不写死。
--
-- 【权限断言不空转】E 臂用一个没有 module.finance.view 的主体调用,必须被拒。
-- fixture 以 postgres 跑、绕过 RLS,但这两个函数是 SECURITY DEFINER +
-- require_permission(),读的是 request.jwt.claims —— 与角色无关,所以这一臂有效。
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();   -- 有 module.finance.view
    v_none  uuid := gen_random_uuid();   -- 什么都没有
    r_fin uuid; r_none uuid;
    a_cash uuid; a_rev uuid; a_cogs uuid; a_eq uuid;
    e_sale uuid; e_cogs uuid; e_close uuid;
    v_ccy text;
    v_rev_amt  numeric := 5000.00;   -- 一笔销售
    v_cogs_amt numeric := 2000.00;   -- 对应成本
    v_net      numeric;              -- = 5000 − 2000,由上面两个算出来
    p  jsonb;   -- pnl_statement 的答复
    b  jsonb;   -- balance_sheet 的答复(结转后)
    b0 jsonb;   -- balance_sheet 的答复(结转前)
    v_eq_row  numeric;
    v_before  numeric;
    v_after   numeric;
    v_denied  boolean := false;
BEGIN
    v_net := v_rev_amt - v_cogs_amt;

    SELECT code INTO v_ccy FROM currencies WHERE is_base;      -- 币种是数据,不是常量
    SELECT id INTO a_cash FROM accounts WHERE code = '1000';
    SELECT id INTO a_rev  FROM accounts WHERE code = '4000';
    SELECT id INTO a_cogs FROM accounts WHERE code = '5000';
    SELECT id INTO a_eq   FROM accounts WHERE code = '3100';
    IF a_cash IS NULL OR a_rev IS NULL OR a_cogs IS NULL OR a_eq IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 28 前置失败:科目表缺 1000/3100/4000/5000 之一 —— 这四个都是 is_system 的引导科目';
    END IF;

    -- ── 角色:自建,不借引导角色(README 第 2 条)──────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-28-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_fin, 'module.finance.view');
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-28-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_fin), (v_none, r_none);

    -- ── 数据:2027 年整年,本 fixture 自己的三笔 ──────────────────────────
    -- 用 2027 是为了【与任何引导数据无关】,也不碰 locked_before 之类随月末移动的状态。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX28-SALE', '2027-06-15', 'fixture 28 sale', 'sale') RETURNING id INTO e_sale;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_sale, a_cash, v_rev_amt, 0, v_ccy, v_rev_amt, 1),
           (e_sale, a_rev,  0, v_rev_amt, v_ccy, v_rev_amt, 1);

    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX28-COGS', '2027-03-10', 'fixture 28 cost', 'processing_cost') RETURNING id INTO e_cogs;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_cogs, a_cogs, v_cogs_amt, 0, v_ccy, v_cogs_amt, 1),
           (e_cogs, a_cash, 0, v_cogs_amt, v_ccy, v_cogs_amt, 1);

    -- 年结:把损益科目冲平,净额落到 3100。落在财年末日 —— 这正是它会掉进
    -- 损益表期间的原因,也是必须剔除它的原因。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX28-CLOSE', '2027-12-31', 'fixture 28 year close', 'year_close') RETURNING id INTO e_close;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_close, a_rev,  v_rev_amt, 0, v_ccy, v_rev_amt, 1),
           (e_close, a_cogs, 0, v_cogs_amt, v_ccy, v_cogs_amt, 1),
           (e_close, a_eq,   0, v_net,     v_ccy, v_net,     1);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ A. 损益表【剔除】年结 ═══════════════════════════════════════
    p := pnl_statement('2027-01-01', '2027-12-31');

    IF (p->>'net_profit')::numeric <> v_net THEN
        RAISE EXCEPTION 'FIXTURE 28A 失败:期间含年结分录时,净利应为 %(=%−%,年结被剔除),实得 % —— 若为 0 就是没有剔除,已结年度的损益表被结转清成了零',
            v_net, v_rev_amt, v_cogs_amt, p->>'net_profit';
    END IF;
    IF (p->'revenue'->>'subtotal')::numeric <> v_rev_amt
       OR (p->'cogs'->>'subtotal')::numeric <> v_cogs_amt THEN
        RAISE EXCEPTION 'FIXTURE 28A 失败:收入/成本应为 % / %,实得 % / %',
            v_rev_amt, v_cogs_amt, p->'revenue'->>'subtotal', p->'cogs'->>'subtotal';
    END IF;

    -- 【这一臂不能靠两个答案碰巧相等而通过】把年结算进去会得到 0;
    -- 断言"正确答案 ≠ 错误答案",与 FIN-18 / FIN-27 同一个做法。
    IF v_net = 0 THEN
        RAISE EXCEPTION 'FIXTURE 28A 无效:构造的净利恰好是 0,剔除与不剔除给出同一个答案 —— 换个金额';
    END IF;

    -- ══════════ B. 资产负债表【包含】年结 ═══════════════════════════════════
    b := balance_sheet('2027-12-31');

    SELECT COALESCE(sum((x->>'net')::numeric), 0) INTO v_eq_row
      FROM jsonb_array_elements(b->'equity'->'rows') x WHERE x->>'code' = '3100';

    IF v_eq_row <> v_net THEN
        RAISE EXCEPTION 'FIXTURE 28B 失败:结转后 3100 应有一行 %,实得 % —— 若为 0 就是资产负债表也把年结剔除了',
            v_net, v_eq_row;
    END IF;
    IF (b->>'current_earnings')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 28B 失败:结转后"本期损益"合成行应归零(损益科目已被冲平),实得 %',
            b->>'current_earnings';
    END IF;

    -- ══════════ C. 不对称本身:同一个期末,两张表【必须】给出不同的数 ═════════
    -- 损益表说这一年赚了 v_net(它看不见结转);资产负债表说本期损益为 0
    -- (它看得见结转,钱已经进了 3100)。两个都对,而且【必须不同】——
    -- 相同就说明有一边把年结处理成了另一边的口径。
    IF (p->>'net_profit')::numeric = (b->>'current_earnings')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 28C 失败:损益表净利(%)与资产负债表本期损益(%)相同 —— 不对称丢了,两边现在是同一个口径',
            p->>'net_profit', b->>'current_earnings';
    END IF;

    -- ══════════ D. 不变量:结转搬的是【位置】,不是【金额】═══════════════════
    -- 结转前:钱在"本期损益"合成行,3100 还是空的。
    -- 结转后:钱在 3100,合成行归零。两者之和【相等】—— 这是不变量,不是字面值。
    b0 := balance_sheet('2027-12-30');   -- 结转分录的前一天
    v_before := (b0->>'current_earnings')::numeric + (b0->'equity'->>'subtotal')::numeric;
    v_after  := (b ->>'current_earnings')::numeric + (b ->'equity'->>'subtotal')::numeric;

    IF v_before <> v_after THEN
        RAISE EXCEPTION 'FIXTURE 28D 失败:结转前后 本期损益+权益科目 应相等(结转只搬位置),前 % 后 %',
            v_before, v_after;
    END IF;
    -- 而【拆分确实变了】—— 否则上面那条恒等式在"什么都没发生"时也成立
    IF (b0->>'current_earnings')::numeric = (b->>'current_earnings')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 28D 失败:结转前后"本期损益"没有变化(前 %,后 %)—— 恒等式通过了,但它是空转的',
            b0->>'current_earnings', b->>'current_earnings';
    END IF;

    IF NOT (b->>'balanced')::boolean OR NOT (b0->>'balanced')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 28D 失败:资产负债表在结转前后都必须平,实得 前 % 后 %',
            b0->>'balanced', b->>'balanced';
    END IF;

    -- ══════════ E. 权限断言不空转 ═══════════════════════════════════════════
    -- 换成一个没有 module.finance.view 的主体,两个函数都必须拒绝。
    -- 没有这一臂,require_permission 那行被删掉本 fixture 照样全绿。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_none), true);
    BEGIN
        PERFORM pnl_statement('2027-01-01', '2027-12-31');
    EXCEPTION WHEN OTHERS THEN
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 28E 失败:没有 module.finance.view 的主体调用 pnl_statement 竟然成功了';
    END IF;

    v_denied := false;
    BEGIN
        PERFORM balance_sheet('2027-12-31');
    EXCEPTION WHEN OTHERS THEN
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 28E 失败:没有 module.finance.view 的主体调用 balance_sheet 竟然成功了';
    END IF;
END $$;
ROLLBACK;
