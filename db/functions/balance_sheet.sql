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