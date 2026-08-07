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

    -- 期初 / 期末余额:【资产负债表口径】—— 全部已过账分录,含 year_close。
    -- 与 app/finance/balance-sheet/page.tsx 同一条规矩(那边的注释解释了为什么含)。
    SELECT COALESCE(sum(l.debit - l.credit), 0) INTO v_opening
    FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
    JOIN accounts a ON a.id = l.account_id
    WHERE a.is_cash AND e.status = 'posted' AND e.entry_date < p_from;

    SELECT COALESCE(sum(l.debit - l.credit), 0) INTO v_closing_bs
    FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
    JOIN accounts a ON a.id = l.account_id
    WHERE a.is_cash AND e.status = 'posted' AND e.entry_date <= p_to;

    -- 区间内每一笔【碰了现金的】分录,连同它的归类。
    -- 净额跨【全部现金科目】合计 —— 于是银行间调拨(1000 → 1010)自然抵为 0,
    -- 不必特判:它本来就不是现金流,只是现金换了个地方。
    WITH mv AS (
        SELECT e.id, e.code, e.entry_date, e.source_type, e.memo,
               sum(l.debit - l.credit) AS net
        FROM journal_lines l
        JOIN journal_entries e ON e.id = l.entry_id
        JOIN accounts a ON a.id = l.account_id
        WHERE a.is_cash AND e.status = 'posted'
          AND e.entry_date BETWEEN p_from AND p_to
          -- 年结分录不碰现金,且【不该出现在现金流量表里】(同损益表剔除它的理由)
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
        -- 【自检】按资产负债表口径独立算一遍同一批科目的期末余额。
        -- 两者不等 = 这张表是错的,页面照实说,不印一个对不上的数。
        'closing_cash_balance_sheet', round(v_closing_bs, 2),
        'ties', (v_computed = round(v_closing_bs, 2)),
        'entries', v_rows
    );
END;
$function$;