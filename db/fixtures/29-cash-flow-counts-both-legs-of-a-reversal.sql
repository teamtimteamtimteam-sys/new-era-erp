-- 29 冲销对的【两条腿都算】—— 现金流量表不按 status 过滤
--
-- 【为什么值得常设(OPS-17)】冲销对 = 原分录 status='reversed' + 一张 status='posted'
-- 的等额反向分录。只留 posted 会【丢原分录、留冲销分录】,净额刚好错成 -原分录。
-- cash_flow_statement 曾经就是这么写的,live 上把现金口径错了 1,166.98,而它自己的
-- ties 自检【出自同一段算术】,从来没有报过 false。
--
-- 【这一条极易被"修回去"】"报表只看已过账的分录"听起来天经地义,而且改回去之后
-- 屏幕上仍然是个像模像样的负数。所以断言写成【三方对照】:
--   A 冲销对对现金的净贡献 = 0(不是 -原分录)
--   B 同一时点,cash_flow 的期末现金 = balance_sheet 的现金合计(两个独立实现)
--   C 明写"只留 posted 会得到什么",并断言实得【不等于】那个数 ——
--     没有 C,一个 posted-only 的实现在"恰好没有冲销对"的数据上照样全绿。
--
-- 【B 臂就是 OPS-17 给 ties 换的那个来源】ties 之所以现在能报 false,是因为两侧
-- 分别来自 cash_flow_statement 与 balance_sheet;本臂把这件事钉成行为断言,
-- 而不是只存在于一句注释里。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_fin uuid;
    a_cash uuid; a_ap uuid;
    e_orig uuid; e_rev uuid;
    v_ccy text;
    v_amt numeric := 1750.00;         -- 一笔付款
    v_posted_only numeric;            -- "只留 posted"会得到的那个数
    cf jsonb; bs jsonb;
    v_cash_bs numeric;
    v_pair_net numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT id INTO a_cash FROM accounts WHERE code = '1000';   -- is_cash
    SELECT id INTO a_ap   FROM accounts WHERE code = '2000';   -- 应付,非现金
    IF a_cash IS NULL OR a_ap IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 29 前置失败:缺 1000 / 2000';
    END IF;
    IF NOT (SELECT is_cash FROM accounts WHERE id = a_cash) THEN
        RAISE EXCEPTION 'FIXTURE 29 前置失败:1000 不是 is_cash —— 本 fixture 整个断言都挂在这上面';
    END IF;
    IF (SELECT is_cash FROM accounts WHERE id = a_ap) THEN
        RAISE EXCEPTION 'FIXTURE 29 前置失败:2000 竟然是 is_cash,对手方必须是非现金科目';
    END IF;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-29-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_fin, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_fin);

    -- ── 原分录:付款 —— 现金减少 ────────────────────────────────────────────
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX29-PAY', '2027-05-10', 'fixture 29 payment', 'payment') RETURNING id INTO e_orig;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_orig, a_ap,   v_amt, 0, v_ccy, v_amt, 1),
           (e_orig, a_cash, 0, v_amt, v_ccy, v_amt, 1);

    -- ── 冲销分录:等额反向,status 保持 'posted' ─────────────────────────────
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX29-REV', '2027-05-12', 'fixture 29 reversal', 'payment') RETURNING id INTO e_rev;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_rev, a_cash, v_amt, 0, v_ccy, v_amt, 1),
           (e_rev, a_ap,   0, v_amt, v_ccy, v_amt, 1);

    -- 原分录翻成 reversed 并挂上冲销单 —— 这是 guard_journal_entry_mutation
    -- 允许的唯一一种 UPDATE(posted → reversed 且首次挂 reversed_by)。
    UPDATE journal_entries SET status = 'reversed', reversed_by = e_rev WHERE id = e_orig;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    cf := cash_flow_statement('2027-01-01', '2027-12-31');
    bs := balance_sheet('2027-12-31');

    -- ══════════ A. 冲销对对现金的净贡献 = 0 ═════════════════════════════════
    v_pair_net := (cf->>'closing_cash')::numeric - (cf->>'opening_cash')::numeric;
    IF v_pair_net <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 29A 失败:一进一出的冲销对对现金的净贡献应为 0,实得 % —— 若为 % 就是按 status 过滤了,丢了原分录只留冲销分录',
            v_pair_net, v_amt;
    END IF;

    -- ══════════ B. 期末现金 = balance_sheet 的现金合计(两个独立实现)═════════
    SELECT COALESCE(sum((x->>'net')::numeric), 0) INTO v_cash_bs
      FROM jsonb_array_elements(bs->'asset'->'rows') x
     WHERE (x->>'code') IN (SELECT code FROM accounts WHERE is_cash);

    IF (cf->>'closing_cash')::numeric <> v_cash_bs THEN
        RAISE EXCEPTION 'FIXTURE 29B 失败:cash_flow 期末现金 % 与 balance_sheet 现金合计 % 不等',
            cf->>'closing_cash', v_cash_bs;
    END IF;
    IF NOT (cf->>'ties')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 29B 失败:ties 应为 true,实得 false(期末 % / 资产负债表口径 %)',
            cf->>'closing_cash', cf->>'closing_cash_balance_sheet';
    END IF;

    -- ══════════ C. 与"只留 posted"的答案【必须不同】═════════════════════════
    -- 只留 posted:原分录(-v_amt)被丢掉,冲销分录(+v_amt)留下 → 净 +v_amt。
    -- 没有这一臂,一个 posted-only 的实现只要碰上没有冲销对的数据就照样通过。
    v_posted_only := v_amt;
    IF v_pair_net = v_posted_only THEN
        RAISE EXCEPTION 'FIXTURE 29C 失败:实得净贡献 % 与"只留 posted"的答案 % 相同 —— 这一臂无法区分两种实现,换个金额',
            v_pair_net, v_posted_only;
    END IF;

    -- 而且冲销分录确实【在期间里、也确实碰了现金】—— 否则上面三臂都是空转的
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(cf->'entries') x
         WHERE x->>'code' = 'FIX29-REV' AND (x->>'net')::numeric = v_amt) THEN
        RAISE EXCEPTION 'FIXTURE 29 失败:冲销分录没有出现在现金流量表的明细里 —— 前面几臂是空转的';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(cf->'entries') x
         WHERE x->>'code' = 'FIX29-PAY' AND (x->>'net')::numeric = -v_amt) THEN
        RAISE EXCEPTION 'FIXTURE 29 失败:被冲销的【原分录】没有出现在现金流量表的明细里 —— 这正是 status 过滤会丢掉的那一条';
    END IF;
END $$;
ROLLBACK;
