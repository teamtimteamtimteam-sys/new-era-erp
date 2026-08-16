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
        -- ════════════════════════════════════════════════════════════════════
        -- 【推导住在 journal_activity_lines 里】三表连接、不过滤 status、
        -- 以及符号规则,全在那个文件的头部,连同它们为什么是那样的理由。
        -- 此处只剩两个开关:
        --   ① 日期形状 = 期间 (p_from, p_to);
        --   ② 年结分录 = 【剔除】(false)。
        --
        -- 【FIN-23:剔除年结分录 —— 与资产负债表刻意不对称】本表按日期区间
        -- 聚合分录行,而结转分录恰好落在区间末日(财年末):不剔除,已结年度的
        -- 损益表会整表归零 —— 合法会计记录里【去年的报表必须永远可复现】。
        -- 资产负债表【包含】year_close(下面 balance_sheet(),注释互指):
        -- 已结年度的损益行合计归零,3100 接住结果,合成的"本期损益"行只剩
        -- 结转后的活动 —— 自洽。db/fixtures/28 把这条不对称钉住。
        --
        -- 【改任何一边前先读两边】—— 而"两边"现在指的是本函数与
        -- balance_sheet 各自那一个 false/true,不再包括推导本身:
        -- 推导只有一份,在 journal_activity_lines。
        -- ════════════════════════════════════════════════════════════════════
        SELECT j.account_code AS code, j.account_name_en AS name_en,
               j.account_name_zh AS name_zh, j.account_type,
               sum(j.debit) AS debits, sum(j.credit) AS credits,
               sum(j.signed_base) AS signed
        FROM journal_activity_lines(p_from, p_to, false) j
        WHERE j.account_type IN ('revenue', 'cogs', 'expense')
        GROUP BY j.account_code, j.account_name_en, j.account_name_zh, j.account_type
    ), amt AS (
        -- 收入贷正,成本/费用借正 —— 那条规则是共享推导的 signed_base 列。
        -- 零发生额科目在这里被排除 ——(a.debits !== 0 || a.credits !== 0) 同一条。
        SELECT g.code, g.name_en, g.name_zh, g.account_type,
               round(g.signed, 2) AS amount
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
