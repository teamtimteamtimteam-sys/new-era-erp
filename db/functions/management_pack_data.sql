-- db/functions/management_pack_data.sql
-- GLEXPORT-1:一个月的管理报表包 —— **它自己一个数都不算。**
--
-- ★【本函数的全部工作是【调用】,而那不是偷懒,是这一刀的要求】★
--   包里的每一个数字都已经有一支函数在算它,而屏幕上也已经印着同一个数。
--   在这里再算一遍 = 第二份实现,两份会在写下来那天一致、之后悄悄分开 ——
--   这个仓库为这个形状付过四次账(AGENTS.md 的预览规则)。
--   所以下面每一段都是一次调用,并在旁边写明【调的是谁】:
--     · 损益      → pnl_statement(start, end)
--     · 资产负债  → balance_sheet(end)
--     · 现金流量  → cash_flow_statement(start, end)
--     · 应收/应付账龄 → ar_aging_asof / ap_aging_asof
--     · 控制科目勾稽 → gl_control_reconciliation
--     · 月末外币就绪 → fx_month_end_readiness(视图)
--     · 银行对账     → bank_reconciliations(已冻结的那些行)
--     · 现金预测     → cash_forecasts(已冻结的那一份,不是现算)
--
-- ★【一份实现,两个调用方】★ 屏幕读它,冻结(freeze_management_pack)也读它。
--   于是"屏幕上看到的"与"冻下来的"不可能是两个数 —— 这正是 reprice_split /
--   preview_revalue_foreign_balances 立下的那个形状。
--
-- ★★【账龄的截止日可能【不是】月末,而这必须说出来】★★
--   ar/ap_aging_asof 对未来的截止日按名拒(AGING_AS_OF_FUTURE)。
--   于是【当月】的实时预览取不到月末账龄 —— 取到今天为止的。
--   本函数因此把 aging_as_of 单独返回,并在 caveats 里点名
--   `aging_capped_at_today`。**冻结的包不会遇到这一条**:只有已关账的月份
--   才冻得下来,而已关账的月份月末必在过去。
--
-- 【为什么 balance_sheet 用 end 而账龄用 LEAST(end, today)】资产负债表是纯总账
--   推导,对未来日期没有意见;账龄要读单据的"那一天是什么状态",而未来那一天
--   还没有发生。两者不同,所以两个日期,而不是把其中一个悄悄改成另一个。

CREATE OR REPLACE FUNCTION public.management_pack_data(p_period_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_aging   date;
    v_base    text;
    v_locked  date;
    v_is_locked boolean;
    v_pnl     jsonb; v_bs jsonb; v_cf jsonb;
    v_ar      jsonb; v_ap jsonb; v_recon jsonb;
    v_fx      jsonb; v_bank jsonb; v_forecast jsonb;
    v_split   jsonb;
    v_unexp   numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    -- 【封顶,而不是拒绝】实时预览要能看当月;拒绝会让当月完全看不见,
    -- 而那比"看到截至今天的账龄并被告知它被封顶了"坏。
    v_aging := LEAST(v_end, CURRENT_DATE);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT locked_before INTO v_locked FROM finance_settings;
    -- 【已关账 = 这个月的每一天都不能再过账】locked_before 是"早于它的都锁了",
    -- 所以判据是 locked_before > period_end,与 file_gst_return 逐字同源。
    v_is_locked := (v_locked IS NOT NULL AND v_locked > v_end);

    -- ── 三张报表:全部是调用 ────────────────────────────────────────────────
    v_pnl := pnl_statement(v_start, v_end);
    v_bs  := balance_sheet(v_end);
    v_cf  := cash_flow_statement(v_start, v_end);

    -- ── 账龄与控制科目勾稽 ──────────────────────────────────────────────────
    v_ar    := ar_aging_asof(v_aging);
    v_ap    := ap_aging_asof(v_aging);
    v_recon := gl_control_reconciliation(v_aging);

    -- ── 月末外币就绪:【读那张视图,不自己判】 ───────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', f.currency, 'has_mid', f.has_mid,
               'mid_rate', f.mid_rate, 'mid_rate_as_of', f.mid_rate_as_of,
               'revalued', f.revalued, 'blocks_close', f.blocks_close) ORDER BY f.currency), '[]'::jsonb)
      INTO v_fx
      FROM fx_month_end_readiness f
     WHERE f.month_end = v_end;

    -- ── 银行对账:这个月有没有对过 ─────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_code', bs.bank_account_code, 'statement_code', bs.code,
               'currency', br.currency, 'as_of', br.as_of,
               'bank_closing_balance', br.bank_closing_balance,
               'book_balance', br.book_balance, 'difference', br.difference,
               'reconciled_at', br.reconciled_at) ORDER BY bs.bank_account_code), '[]'::jsonb)
      INTO v_bank
      FROM bank_reconciliations br
      JOIN bank_statements bs ON bs.id = br.statement_id
     WHERE br.as_of BETWEEN v_start AND v_end
       AND br.superseded_at IS NULL;

    -- ── 现金预测:读【冻下来的那一份】,不现算 ──────────────────────────────
    -- 现算会让"这个包里的预测"与"当时那一份"是两个数,而 CASHFLOW-1 冻结它
    -- 的全部理由就是偏差要拿【过去那一份】比。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'code', cfz.code, 'week_start', cfz.week_start,
               'frozen_at', cfz.frozen_at) ORDER BY cfz.week_start), '[]'::jsonb)
      INTO v_forecast
      FROM cash_forecasts cfz
     WHERE cfz.week_start BETWEEN v_start AND v_end
       AND cfz.superseded_at IS NULL;

    -- ── ★【拆散在两个月的冲销对】★ ─────────────────────────────────────────
    -- 一张分录落在本月、而它的冲销件(或它冲销的那一张)落在【别的月】,
    -- 本月的数字就带着一条没有对手的腿。这【不是错】—— 跨期冲销完全合法,
    -- 年结时尤其常见 —— 但它是「这个月怎么看着不对」最可能的答案,
    -- 而对手件的日期只有一个 join 之遥,所以说出来比让人去猜便宜得多。
    -- 【实测:线上就有三对】JE-2027-0001/2/3(2027-09-05)由
    -- JE-2026-0058/59/60(2026-08-20)冲销 —— 于是 2026-08 带着三条没有原件的
    -- 冲销腿,合计对 2000 影响 −3,703.68,而全时段净额恰好是 0。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'entry_code', x.code, 'entry_date', x.entry_date,
               'counterpart_code', x.cp_code, 'counterpart_date', x.cp_date,
               'amount_base', x.amt) ORDER BY x.entry_date, x.code), '[]'::jsonb)
      INTO v_split
      FROM (
        -- 本月的原件,冲销件在别的月
        SELECT o.code, o.entry_date, r.code AS cp_code, r.entry_date AS cp_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = o.id) AS amt
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE o.entry_date BETWEEN v_start AND v_end
           AND r.entry_date NOT BETWEEN v_start AND v_end
        UNION ALL
        -- 本月的冲销件,原件在别的月
        SELECT r.code, r.entry_date, o.code, o.entry_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = r.id)
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE r.entry_date BETWEEN v_start AND v_end
           AND o.entry_date NOT BETWEEN v_start AND v_end
      ) x;

    SELECT COALESCE(SUM((s->>'unexplained_base')::numeric), 0) INTO v_unexp
      FROM jsonb_array_elements(v_recon->'sides') s;

    RETURN jsonb_build_object(
        'period_month',  v_start,
        'period_start',  v_start,
        'period_end',    v_end,
        'aging_as_of',   v_aging,
        'generated_on',  CURRENT_DATE,
        'base_currency', v_base,
        'locked_before', v_locked,
        'month_locked',  v_is_locked,
        'pnl',           v_pnl,
        'balance_sheet', v_bs,
        'cash_flow',     v_cf,
        'ar_aging',      v_ar,
        'ap_aging',      v_ap,
        'control_reconciliation', v_recon,
        'fx_month_end',  v_fx,
        'bank_reconciliations', v_bank,
        'cash_forecasts', v_forecast,
        'split_reversal_pairs', v_split,
        -- ★【这个包看不见什么 —— 逐条,而不是留给读的人猜】★
        -- 预测那一刀立的规矩:一份悄悄漏掉一整类东西的报表,是一个会被人当真
        -- 的数字。所以缺席是【具名的】,而且带着它自己的判据。
        'caveats', jsonb_build_object(
            'month_not_locked',        NOT v_is_locked,
            'aging_capped_at_today',   (v_aging < v_end),
            'fx_missing_mid',          EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'has_mid')::boolean IS NOT TRUE),
            'fx_not_revalued',         EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'revalued')::boolean IS NOT TRUE),
            'control_unexplained',     (v_unexp <> 0),
            'control_unexplained_base', v_unexp,
            'split_reversal_pairs_n',  jsonb_array_length(v_split),
            'no_bank_reconciliation',  (jsonb_array_length(v_bank) = 0),
            'no_cash_forecast',        (jsonb_array_length(v_forecast) = 0)));
END;
$function$
;
