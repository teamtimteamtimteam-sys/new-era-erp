-- FXREV-1(2026-08-27):期末重估的取数改走 journal_activity_lines —— 两处,不是一处。
-- NOTE: apply with ./db/apply_migration.sh
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这是同一个机制在本仓库的第四处,而它是唯一一处【会过账】的】
-- 前三处:cash_flow_statement(OPS-17)、f5_return/f5_box_detail(GST-2)、
-- bank_reconciliation_status(BANK-REC)—— 都只是屏幕上的错数字。
-- 这一处不同:revalue_foreign_balances 直接拿 preview 的结果去发分录,
-- 于是错的基数会【真的进总账】。
--
-- ★【它已经咬了,而且量得出来】★ 线上唯一一张已过账的重估分录
-- JE-2026-0024(期末 2026-07-31)算错了 **SGD 56,532.48**(未实现汇兑损失多记)。
-- 三张原分录(JE-2026-0001/0003/0006)在跑那次重估【之前】就已经是 reversed,
-- 所以这不是"事后改了历史",是当时就算错了。完整的复现证据与逐科目数字
-- 记在 docs/fx-revaluation-misstatement-2026-07.md。
--
-- 【两处过滤,不是一处 —— 而它们坏的方向不同】
--   ① 主聚合(原第 50 行):e.status='posted' 污染 native 与 carry_fx,
--      也就是外币净额与它的本位币承载额;
--   ② 承载额子查询(原第 62 行):e2.status='posted' 污染【既往重估调整】那一项。
--   一份只注入普通分录的 fixture 会漏掉 ②:它要靠一张【被冲销的重估分录】才踩得到。
--   db/fixtures/133 因此有三条臂,②那条单独一条。
--
-- 【source_type='revaluation' 这个过滤【保留】—— 它不是同一类东西】
-- 它问的是"这一行是不是既往的重估调整",是一个【语义】选择,不是"分录还活着吗"。
-- 坏的只有 status 那一半。
--
-- 【复用,不是再实现一遍】行的取舍(不过滤 status、日期上界、年结开关)
-- 整个交给 journal_activity_lines —— 与 balance_sheet / account_ledger /
-- bank_book_balance_asof 同一份。本函数只保留它自己的投影:
-- 外币原币净额(amount_ccy)与本位币承载额(debit-credit)。
-- (NULL, p_period_end, true) 逐字是 balance_sheet 的调用:重估是一个【截至日】
-- 的资产负债表式计算,年结开关与那张表一致 —— 一个科目的"截至 X 日余额"
-- 在系统里只能有一个意思。年结分录本来也不落在外币货币性科目上,
-- 传 true 同时保住了改动前的行为。
--
-- 【只动取数,不动任何算术】target = round(native × rate, 2)、
-- adjustment = target − carry、缺牌价不抛只记 missing_rates —— 一个字节都没改。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.preview_revalue_foreign_balances(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base    text;   -- OPS-8:本位币从 currencies.is_base 读
    v_row     record;
    v_rate    numeric;
    v_rate_asof date;   -- FIN-19:这个牌价【取自哪一天】
    v_target  numeric;
    v_adj     numeric;
    v_carry   numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_missing jsonb := '[]'::jsonb;
    v_total   numeric := 0;
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    FOR v_row IN
        -- 【①(FXREV-1)】原来这里是 `JOIN journal_entries e ... WHERE e.status='posted'`。
        -- 冲销的形状是:原分录翻成 reversed,另发一张等额反向的 posted 冲销分录 ——
        -- 只留 posted 就是丢原分录、留冲销分录,净额错成 −原分录。
        -- 行的取舍现在整个由 journal_activity_lines 回答,本函数不再自己挑行。
        SELECT act.account_code AS code, jl.currency,
               round(sum(CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END), 2) AS native,
               round(sum(jl.debit - jl.credit), 2) AS carry_fx
        FROM journal_activity_lines(NULL, p_period_end, true) act
        JOIN journal_lines jl ON jl.id = act.line_id
        JOIN accounts a ON a.id = act.account_id
        WHERE a.is_monetary AND jl.currency <> v_base
        GROUP BY act.account_code, jl.currency
        ORDER BY act.account_code, jl.currency
    LOOP
        -- 既往重估调整行(本币行,挂在 revaluation 分录上)也算进承载额
        -- 【②(FXREV-1)】这里原来还有一句 `e2.status = 'posted'`,与 ① 同病:
        -- 一张【被冲销的重估分录】会被算成 −原调整额。source_type 那一半留着 ——
        -- 它问的是"这是不是既往重估调整",是语义选择,不是"分录还活着吗"。
        SELECT v_row.carry_fx + COALESCE(round(sum(jl2.debit - jl2.credit), 2), 0)
        INTO v_carry
        FROM journal_activity_lines(NULL, p_period_end, true) act2
        JOIN journal_lines jl2 ON jl2.id = act2.line_id
        WHERE act2.account_code = v_row.code AND jl2.currency = v_base
          AND act2.source_type = 'revaluation';

        -- FIN-19:问 fx_rate_asof 而不是 fx_rate_for —— 要的是【牌价取自哪一天】。
        -- 期末常常落在周末(月末约 2/7 的机会),那时用周五的中间价是对的,
        -- 但屏幕上必须说出来:回溯当初就是以"说得出取自哪天"为条件被接受的。
        -- 缺牌价时 fx_rate_asof 返回空行(不抛),所以这里不再需要 EXCEPTION 兜。
        v_rate := NULL; v_rate_asof := NULL;
        SELECT x.rate, x.as_of INTO v_rate, v_rate_asof
        FROM fx_rate_asof(v_row.currency, p_period_end, 'mid') x;
        IF v_rate IS NULL AND NOT (v_missing @> to_jsonb(v_row.currency)) THEN
            v_missing := v_missing || to_jsonb(v_row.currency);
        END IF;

        IF v_rate IS NULL THEN
            v_target := NULL; v_adj := NULL;
        ELSE
            v_target := round(v_row.native * v_rate, 2);
            v_adj    := round(v_target - v_carry, 2);
            v_total  := v_total + v_adj;
        END IF;

        v_rows := v_rows || jsonb_build_object(
            'account', v_row.code, 'currency', v_row.currency,
            'native', v_row.native, 'carry_base', v_carry,
            'rate', v_rate, 'rate_as_of', v_rate_asof,
            'target_base', v_target, 'adjustment', v_adj);
    END LOOP;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'rows', v_rows,
        'total_adjustment', v_total,
        'missing_rates', v_missing);
END;
$function$;

COMMIT;
