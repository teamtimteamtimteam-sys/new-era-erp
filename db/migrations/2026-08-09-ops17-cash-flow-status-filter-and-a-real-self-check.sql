-- OPS-17:现金流量表的两个毛病 —— 数字是小的那一半,自检才是大的那一半
--
-- 【1 · status='posted' 过滤是错的】冲销对由【原分录 status='reversed'】加上一张
-- 【status='posted' 的等额反向分录】组成(实测 JE-2026-0029/0030 逐行相反)。
-- 只留 posted 会丢掉原分录、留下冲销分录,净额刚好错成 -原分录。
-- 损益表与资产负债表从来没有过滤过 status,这是对的;现金流量表过滤了,这是错的。
-- live 上这一条让现金口径差 1,166.98(资产负债表 -45,648.37 / 本函数 -44,481.39)。
--
-- 【三处一起去掉,不是两处】期初、期末【和期间发生额】必须取同一个总体,否则
--   期末 = 期初 + 发生额
-- 这条恒等式立刻不成立,ties 会对所有含冲销对的期间报 false。只改"资产负债表口径"
-- 那两处、留下 mv 里的过滤,等于把一个错误换成另一个错误。
--
-- 【2 · 真正的缺陷:自检是拿自己比自己】FIN-30 写下 ties 时说它让这张表"自检",
-- 但 closing_cash 与 closing_cash_balance_sheet 【出自同一个函数体、同一段算术】——
-- 两侧同时错就同时错,它【从来没有可能报 false】。live 上五个期间全部 ties=true,
-- 包括 2026-07-30..07-31 这种冲销对被期间切开的区间。
-- OPS-16 建了 balance_sheet(as_of),于是"另一份独立实现"第一次真的存在:
-- 现在 closing_cash_balance_sheet 【由 balance_sheet() 算出来】,ties 比的是
-- 两个不同函数、不同聚合路径得到的同一个数。这才是自检。
--
-- 【为什么从 balance_sheet 里挑现金科目而不是自己再算一遍】金额【整个来自】
-- balance_sheet 的返回值;这里只用 accounts.is_cash 这张目录去挑行。挑行是目录查询,
-- 不是重新推导 —— 一旦自己再 sum 一次 journal_lines,就又变回拿自己比自己了。
--
-- 【year_close 仍然从发生额里剔除,而 balance_sheet 含它】这不是新的不一致,而是
-- 保住 fixture 23 的那一臂:一张【碰了现金的】年结分录是畸形的,它会让两侧真的不等,
-- ties 必须报 false。换了自检来源之后这条依然成立(balance_sheet 看得见它,mv 看不见)。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

CREATE OR REPLACE FUNCTION public.cash_flow_statement(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_opening  numeric;
    v_closing_bs numeric;
    v_rows     jsonb;
    v_op       numeric := 0;
    v_inv      numeric := 0;
    v_fin      numeric := 0;
    v_unc      numeric := 0;
    v_fx       numeric := 0;
    v_computed numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'PERIOD_REQUIRED';
    END IF;

    -- 期初:【资产负债表口径】—— 全部分录,不按 status 过滤。
    -- OPS-17:此前这里有 e.status='posted',丢原分录留冲销分录,错成 -原分录。
    SELECT COALESCE(sum(l.debit - l.credit), 0) INTO v_opening
    FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
    JOIN accounts a ON a.id = l.account_id
    WHERE a.is_cash AND e.entry_date < p_from;

    -- 期末:【问 balance_sheet(),不自己算】(OPS-17)。金额全部来自它的返回值,
    -- 这里只按 accounts.is_cash 挑出现金科目那几行 —— 挑行是目录查询,不是重新推导。
    -- 这一行就是 ties 之所以能报 false 的全部原因:比较的两侧现在出自两个函数。
    SELECT COALESCE(sum((x->>'net')::numeric), 0) INTO v_closing_bs
    FROM jsonb_array_elements(balance_sheet(p_to)->'asset'->'rows') x
    WHERE (x->>'code') IN (SELECT code FROM accounts WHERE is_cash);

    -- 区间内每一笔【碰了现金的】分录,连同它的归类。
    -- 净额跨【全部现金科目】合计 —— 于是银行间调拨(1000 → 1010)自然抵为 0,
    -- 不必特判:它本来就不是现金流,只是现金换了个地方。
    WITH mv AS (
        SELECT e.id, e.code, e.entry_date, e.source_type, e.memo,
               sum(l.debit - l.credit) AS net
        FROM journal_lines l
        JOIN journal_entries e ON e.id = l.entry_id
        JOIN accounts a ON a.id = l.account_id
        WHERE a.is_cash
          -- OPS-17:同样没有 status 过滤 —— 期初、发生额、期末必须同一个总体,
          -- 否则 期末 = 期初 + 发生额 不再成立,ties 会对每个含冲销对的期间报 false。
          AND e.entry_date BETWEEN p_from AND p_to
          -- 年结分录不碰现金,且【不该出现在现金流量表里】(同损益表剔除它的理由)。
          -- 一张真的碰了现金的年结分录是畸形的 —— 它会让 ties 报 false,这正是
          -- fixture 23 那一臂在断言的事。
          AND e.source_type IS DISTINCT FROM 'year_close'
        GROUP BY e.id, e.code, e.entry_date, e.source_type, e.memo
    ), cls AS (
        SELECT m.*,
            CASE
                -- 重估:改的是本位币账面值,没有现金动 —— 单列,不进任何一段
                WHEN m.source_type = 'revaluation' THEN 'fx_effect'
                -- 手工分录什么都不带,按构造无法归类 —— 单列,不塞进经营
                WHEN m.source_type = 'manual' THEN 'unclassified'
                WHEN EXISTS (
                    SELECT 1 FROM journal_lines l2 JOIN accounts a2 ON a2.id = l2.account_id
                     WHERE l2.entry_id = m.id AND NOT a2.is_cash
                       AND a2.cash_flow_section = 'investing') THEN 'investing'
                WHEN EXISTS (
                    SELECT 1 FROM journal_lines l2 JOIN accounts a2 ON a2.id = l2.account_id
                     WHERE l2.entry_id = m.id AND NOT a2.is_cash
                       AND a2.cash_flow_section = 'financing') THEN 'financing'
                ELSE 'operating'
            END AS section
        FROM mv m
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'entry_id', c.id, 'code', c.code, 'entry_date', c.entry_date,
               'source_type', c.source_type, 'memo', c.memo,
               'section', c.section, 'net', round(c.net, 2))
           ORDER BY c.entry_date, c.code), '[]'::jsonb)
    INTO v_rows FROM cls c;

    SELECT
        COALESCE(sum(r.net) FILTER (WHERE r.sec = 'operating'), 0),
        COALESCE(sum(r.net) FILTER (WHERE r.sec = 'investing'), 0),
        COALESCE(sum(r.net) FILTER (WHERE r.sec = 'financing'), 0),
        COALESCE(sum(r.net) FILTER (WHERE r.sec = 'unclassified'), 0),
        COALESCE(sum(r.net) FILTER (WHERE r.sec = 'fx_effect'), 0)
    INTO v_op, v_inv, v_fin, v_unc, v_fx
    FROM (SELECT (x->>'section') AS sec, (x->>'net')::numeric AS net
          FROM jsonb_array_elements(v_rows) x) r;

    v_computed := round(v_opening + v_op + v_inv + v_fin + v_unc + v_fx, 2);

    RETURN jsonb_build_object(
        'period_from', p_from, 'period_to', p_to,
        'opening_cash', round(v_opening, 2),
        'operating', round(v_op, 2),
        'investing', round(v_inv, 2),
        'financing', round(v_fin, 2),
        'unclassified', round(v_unc, 2),
        'fx_effect', round(v_fx, 2),
        'closing_cash', v_computed,
        -- 【自检:两个独立实现的同一个数】上面那个是 期初 + 各段发生额 累出来的,
        -- 这个是 balance_sheet() 独立算的。两者不等 = 这张表是错的,页面照实说,
        -- 不印一个对不上的数。(OPS-17 之前这两侧出自同一段算术,永远不可能不等。)
        'closing_cash_balance_sheet', round(v_closing_bs, 2),
        'ties', (v_computed = round(v_closing_bs, 2)),
        'entries', v_rows
    );
END;
$function$;

COMMIT;
