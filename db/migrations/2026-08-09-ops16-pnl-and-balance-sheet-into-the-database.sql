-- OPS-16:把损益表与资产负债表从页面搬进数据库,并给 journal_entries.entry_date 建索引
--
-- 【为什么搬】app/finance/pnl/page.tsx 与 app/finance/balance-sheet/page.tsx 各自用
-- 一条 PostgREST select 把分录行拉回 Node,再在 TypeScript 里聚合。AGENTS.md
-- §"预览过账的屏幕要【问】数据库" 已经点名过这个形状四次(化验影响预览、GrantRunner
-- 假期公式、重估预览、/finance/payments)。仪表盘要做期间对比,那会是第五次 ——
-- 而且这一次两份实现会同时上屏,漂了就是两个都印在同一页上。
--
-- 【这是一次搬家,不是一次改写】两个函数逐条复刻页面的算术,包括那些不好看的地方
-- (见各自函数体里的注释)。证明写在 OPS-16 的提交信息里:改动前后六个期间逐分相同。
--
-- 【year_close 的不对称原样保留】损益表【剔除】year_close,资产负债表【包含】它。
-- 两边的注释互指,和搬家之前一样。FIN-23 的理由:不剔除,已结年度的损益表会整表
-- 归零 —— 而合法会计记录里去年的报表必须永远可复现。
--
-- NOTE: apply with ./db/apply_migration.sh(单事务、全有或全无;apply_migration.sh
-- 会在同一事务里补跑 db/views/zzz_function_grants.sql,收回 PUBLIC 的 EXECUTE)。

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 损益表:期间口径
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.pnl_statement(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rev jsonb; v_cogs jsonb; v_exp jsonb;
    v_rev_sub numeric; v_cogs_sub numeric; v_exp_sub numeric;
    v_gross numeric; v_net numeric; v_margin numeric;
BEGIN
    -- 与页面此前的把关等价:journal_entries / journal_lines 的 SELECT 策略就是
    -- has_permission('module.finance.view')(accounts 是 USING (true))。所以这个
    -- definer 函数【不放宽任何东西】—— 它问的是调用者自己那一条,只是问得更早。
    PERFORM require_permission('module.finance.view');
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'PERIOD_REQUIRED';
    END IF;

    WITH agg AS (
        SELECT a.code, a.name_en, a.name_zh, a.account_type,
               sum(l.debit) AS debits, sum(l.credit) AS credits
        FROM journal_lines l
        JOIN journal_entries e ON e.id = l.entry_id
        JOIN accounts a ON a.id = l.account_id
        WHERE a.account_type IN ('revenue', 'cogs', 'expense')
          AND e.entry_date BETWEEN p_from AND p_to
          -- ════════════════════════════════════════════════════════════════
          -- 【FIN-23:剔除年结分录 —— 与资产负债表刻意不对称】本表按日期区间聚合
          -- 分录行,而结转分录恰好落在区间末日(财年末):不剔除,已结年度的损益表
          -- 会整表归零 —— 合法会计记录里【去年的报表必须永远可复现】。
          -- 资产负债表【包含】year_close(下面 balance_sheet(),注释互指):已结年度
          -- 的损益行合计归零,3100 接住结果,合成的"本期损益"行只剩结转后的活动 ——
          -- 自洽。改任何一边前先读两边。db/fixtures/28 把这条不对称钉住。
          -- ════════════════════════════════════════════════════════════════
          --
          -- 【IS DISTINCT FROM,不是 <>】source_type 可空。页面此前写的是 PostgREST
          -- 的 not.eq,展开成 NOT (source_type = 'year_close') —— 对 NULL 求值为
          -- NULL,于是【source_type 为 NULL 的分录会被整条丢掉】。搬家时没有照抄这个
          -- 行为,因为它是个 bug 而不是口径:一张少算了一笔分录的损益表不会报错,只会
          -- 小一点。这【不影响搬家的等值证明】—— live 上 source_type 的 NULL 数为 0
          -- (手工分录由 app/finance/journal/new/actions.ts 写成 'manual'),所以两种
          -- 写法在现有数据上逐分相同;差别只在将来真出现 NULL 时,而那时这一版是对的。
          AND e.source_type IS DISTINCT FROM 'year_close'
          -- 【没有 status 过滤,是照搬,而且是对的】被冲销的原分录 status='reversed',
          -- 冲销分录 status='posted' 且金额等额反向。只留 posted 会【丢掉原分录、留下
          -- 冲销分录】,净额刚好错成 -原分录。页面从来没有过滤,所以本函数也没有。
          -- (cash_flow_statement 里那句 e.status='posted' 与此不一致 —— 见 OPS-16
          -- 提交信息里的报告,那是另一件事,本次不动。)
        GROUP BY a.code, a.name_en, a.name_zh, a.account_type
    ), amt AS (
        -- 收入贷正,成本/费用借正。零发生额科目在这里被排除 —— 与页面
        -- (a.debits !== 0 || a.credits !== 0) 同一条。
        SELECT g.code, g.name_en, g.name_zh, g.account_type,
               round(CASE WHEN g.account_type = 'revenue'
                          THEN g.credits - g.debits
                          ELSE g.debits - g.credits END, 2) AS amount
        FROM agg g
        WHERE g.debits <> 0 OR g.credits <> 0
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'amount', amount)
            ORDER BY code) FILTER (WHERE account_type = 'revenue'), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'amount', amount)
            ORDER BY code) FILTER (WHERE account_type = 'cogs'), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'amount', amount)
            ORDER BY code) FILTER (WHERE account_type = 'expense'), '[]'::jsonb),
        -- 小计 = 【已经四舍五入到分的各行】之和,再取一次 —— 与页面同序,不是先合再舍
        COALESCE(round(sum(amount) FILTER (WHERE account_type = 'revenue'), 2), 0),
        COALESCE(round(sum(amount) FILTER (WHERE account_type = 'cogs'), 2), 0),
        COALESCE(round(sum(amount) FILTER (WHERE account_type = 'expense'), 2), 0)
    INTO v_rev, v_cogs, v_exp, v_rev_sub, v_cogs_sub, v_exp_sub
    FROM amt;

    v_gross := round(v_rev_sub - v_cogs_sub, 2);
    v_net   := round(v_gross - v_exp_sub, 2);

    -- 毛利率:收入为零时【返回 NULL 而不是 0】—— 0% 是个断言,"没有收入所以没有比率"
    -- 不是。页面此前就是这么写的(marginPct = ... : null),这里保住它。
    -- floor(x + 0.5) 是 JS Math.round 的精确等价(对负数也是,JS 是向 +∞ 取半),
    -- 写成 round() 会在负毛利率恰好落在半分位时与页面差一档。
    IF v_rev_sub <> 0 THEN
        v_margin := floor(v_gross / v_rev_sub * 1000 + 0.5) / 10;
    ELSE
        v_margin := NULL;
    END IF;

    RETURN jsonb_build_object(
        'period_from', p_from, 'period_to', p_to,
        'revenue', jsonb_build_object('rows', v_rev,  'subtotal', v_rev_sub),
        'cogs',    jsonb_build_object('rows', v_cogs, 'subtotal', v_cogs_sub),
        'expense', jsonb_build_object('rows', v_exp,  'subtotal', v_exp_sub),
        'gross_profit', v_gross,
        'net_profit', v_net,
        'margin_pct', v_margin
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 资产负债表:时点口径
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.balance_sheet(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_asset jsonb; v_liab jsonb; v_eq jsonb;
    v_asset_sub numeric; v_liab_sub numeric; v_eq_sub numeric;
    v_rev numeric; v_cogs numeric; v_exp numeric;
    v_earnings numeric; v_total_le numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;

    WITH agg AS (
        SELECT a.code, a.name_en, a.name_zh, a.account_type,
               sum(l.debit) AS debits, sum(l.credit) AS credits
        FROM journal_lines l
        JOIN journal_entries e ON e.id = l.entry_id
        JOIN accounts a ON a.id = l.account_id
        WHERE e.entry_date <= p_as_of
          -- ════════════════════════════════════════════════════════════════
          -- 【FIN-23:本表【包含】year_close 分录 —— 与损益表刻意不对称】已结年度的
          -- 损益行合计归零,3100 接住净结果,合成的"本期损益"行只剩结转后的活动 ——
          -- 自洽,权益合计不变。损益表相反,【剔除】year_close(上面 pnl_statement(),
          -- 注释互指):否则结转会把已结年度的损益表清成零。改任何一边前先读两边。
          -- 【这里没有 source_type 过滤,不是漏了 —— 那正是"包含"的写法。】
          -- db/fixtures/28 用同一个期间同时问这两个函数,把不对称钉住。
          -- ════════════════════════════════════════════════════════════════
          -- status 同样不过滤,理由与 pnl_statement 相同(冲销对必须成对进出)。
        GROUP BY a.code, a.name_en, a.name_zh, a.account_type
    ), net AS (
        SELECT g.code, g.name_en, g.name_zh, g.account_type, g.debits, g.credits,
               round(CASE WHEN g.account_type = 'asset'
                          THEN g.debits - g.credits
                          ELSE g.credits - g.debits END, 2) AS net
        FROM agg g
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'net', net)
            ORDER BY code) FILTER (WHERE account_type = 'asset' AND (debits <> 0 OR credits <> 0)), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'net', net)
            ORDER BY code) FILTER (WHERE account_type = 'liability' AND (debits <> 0 OR credits <> 0)), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'net', net)
            ORDER BY code) FILTER (WHERE account_type = 'equity' AND (debits <> 0 OR credits <> 0)), '[]'::jsonb),
        COALESCE(round(sum(net) FILTER (WHERE account_type = 'asset'     AND (debits <> 0 OR credits <> 0)), 2), 0),
        COALESCE(round(sum(net) FILTER (WHERE account_type = 'liability' AND (debits <> 0 OR credits <> 0)), 2), 0),
        COALESCE(round(sum(net) FILTER (WHERE account_type = 'equity'    AND (debits <> 0 OR credits <> 0)), 2), 0),
        -- 本期损益三项:【对整型别求和后才取整】—— 页面的 plNet 就是这个顺序
        -- (round2 套在 reduce 外面),与上面各行先取整再合计【不同】,照搬。
        COALESCE(round(sum(credits - debits) FILTER (WHERE account_type = 'revenue'), 2), 0),
        COALESCE(round(sum(debits - credits) FILTER (WHERE account_type = 'cogs'), 2), 0),
        COALESCE(round(sum(debits - credits) FILTER (WHERE account_type = 'expense'), 2), 0)
    INTO v_asset, v_liab, v_eq, v_asset_sub, v_liab_sub, v_eq_sub, v_rev, v_cogs, v_exp
    FROM net;

    -- 本期损益(截至日口径):收入 − 成本 − 费用,合成进权益
    v_earnings := round(v_rev - v_cogs - v_exp, 2);
    v_total_le := round(v_liab_sub + v_eq_sub + v_earnings, 2);

    RETURN jsonb_build_object(
        'as_of', p_as_of,
        'asset',     jsonb_build_object('rows', v_asset, 'subtotal', v_asset_sub),
        'liability', jsonb_build_object('rows', v_liab,  'subtotal', v_liab_sub),
        -- equity 给两个小计:subtotal 是科目行合计,total 额外含本期损益合成行 ——
        -- 屏幕上权益那一段的小计显示的是后者。页面不做算术,所以两个都给。
        'equity',    jsonb_build_object('rows', v_eq, 'subtotal', v_eq_sub,
                                        'total', round(v_eq_sub + v_earnings, 2)),
        'current_earnings', v_earnings,
        'total_assets', v_asset_sub,
        'total_liab_equity', v_total_le,
        -- 【自检】资产合计必须等于 负债+权益 合计。不等 = 这张表是错的,页面照实说。
        'balanced', (v_asset_sub = v_total_le)
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. journal_entries.entry_date 索引
-- ════════════════════════════════════════════════════════════════════════════
-- 【每一个期间问题都走这一列,而它此前没有索引】—— journal_entries 上只有 pkey 与
-- code 的唯一索引。损益表、资产负债表、现金流量表、试算平衡全都按 entry_date 圈期间;
-- 仪表盘一屏要问好几次,做期间对比再翻一倍。
CREATE INDEX idx_journal_entries_entry_date ON public.journal_entries (entry_date);

COMMIT;
