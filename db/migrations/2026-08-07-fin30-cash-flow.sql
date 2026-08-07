-- db/migrations/2026-08-07-fin30-cash-flow.sql
-- FIN-30:现金流量表。两处【声明】+ 一个函数。
--
-- 【为什么要加两列,而不是在报表里写死科目码】
--   * 哪些科目是现金:今天是 1000/1010,而 accounts 上【没有任何一列这么说】。
--     is_monetary 不是它 —— 1100 应收也是 monetary(它要被重估),却不是现金。
--     报表里写死 IN ('1000','1010') 就是 FIN-23 那个"按科目码区间判损益"的同一个
--     缺陷换个位置:开一个银行账户就要改代码,而没有任何东西会提醒。
--     → accounts.is_cash,与 is_system / is_monetary 同一类的声明。
--   * 投资/筹资:IAS 7 把【经营】定义为残差("不属于投资与筹资的其余活动"),
--     所以需要声明的只有另外两类。→ accounts.cash_flow_section,可空,
--     空 = 经营,而这【不是默认桶,是准则给的定义】。
--     种子:1500/1510 固定资产 → 投资;3000/3100 权益 → 筹资。
--
-- 【一笔分录归哪一类,由它的非现金对方科目决定,不由 source_type 决定】
-- source_type 说的是"这笔从哪个模块来",不是"这是什么活动":同样是 expense,
-- 买台设备(对方 1500)是投资,付电费(对方 5110)是经营 —— record_expense
-- 确实两种都做得出来。所以判据取【对方科目的声明】,投资/筹资优先于经营。
--
-- 【两类不是现金流,必须单独走】
--   * revaluation:重估改的是 1010 的【本位币账面值】,一分钱没动。放进任何一个
--     section 都是凭空造出一笔现金流。它是"汇率变动对现金的影响",列在三段【之下】。
--     判据是分录自己声明的 source_type —— 记录,不是推断。
--   * year_close:结转分录落在财年末,不碰现金。整段剔除(与损益表同一条规矩,
--     理由见 app/finance/pnl/page.tsx 的注释)。
--   * manual:手工分录【什么都不带】(post_journal_entry 收到的 source_type 就是
--     'manual',source_id 为 NULL)—— 它按构造无法归类。不塞进经营,单列一行
--     "未归类",非零时报表自己说出来。今天线上手工分录 0 笔。
--
-- 【自检】期初现金 + 三段 + 未归类 + 汇率影响 = 期末现金,而期末现金必须等于
-- 资产负债表口径下同一批科目的余额(含 year_close —— 资产负债表包含它)。
-- 两者不等就说不等,不印一个对不上的数。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin30-cash-flow.sql

BEGIN;

ALTER TABLE public.accounts ADD COLUMN is_cash boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.accounts.is_cash IS
    '这个科目是不是【现金及现金等价物】(FIN-30)。现金流量表据此取科目,不写死 1000/1010 —— 开一个新银行账户只该改数据,不该改代码。注意与 is_monetary 的区别:1100 应收是 monetary(要重估)但不是现金。';

ALTER TABLE public.accounts ADD COLUMN cash_flow_section text
    CHECK (cash_flow_section IS NULL OR cash_flow_section IN ('investing','financing'));
COMMENT ON COLUMN public.accounts.cash_flow_section IS
    '当一笔现金流动的【对方科目】是本科目时,这笔归哪一段(FIN-30)。只声明投资与筹资:IAS 7 把经营定义为残差("不属于投资与筹资的其余活动"),所以 NULL = 经营是【准则的定义】,不是兜底默认值。';

UPDATE public.accounts SET is_cash = true WHERE code IN ('1000','1010');
UPDATE public.accounts SET cash_flow_section = 'investing' WHERE code IN ('1500','1510');
UPDATE public.accounts SET cash_flow_section = 'financing' WHERE code IN ('3000','3100');

-- ── 报表本体:一份实现,页面只负责画 ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cash_flow_statement(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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

COMMIT;
