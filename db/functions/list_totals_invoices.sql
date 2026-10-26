-- db/functions/list_totals_invoices.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/invoices 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【读】与页面同一张视图 invoice_status(app/finance/invoices/invoiceRows.ts issuedCount/issuedPage;视图读 invoices_masked)。
-- 【筛选】与 invoiceRows.ts 的 applyDates / applyState 逐项同一套:issue_date ≥ from、≤ to;state = 'overdue' → overdue = true,
--   其余 state → payment_state = state(看不见价格的读者那里 overdue / payment_state 由 NULL 合计推出,与列表同样地筛 —— 同一个集合)。
-- 【净额】(Q2)作废的发票被它的冲销抵掉,加 0:作废的不进任何一个合计。于是 status='void' 返回零行(没有可加的),
--   status='all' 与 'issued' 是同一个合计(页面 page.tsx 在 'all' 时把作废的接在后面,它们在这里加 0)。
-- 【量】total(total_base)· settled(settled_base)· open(open_base),都是本位币,currency 给本位币代码。
-- 【受限】total / open 在 invoices_masked 里按 data.view_prices 整个读者地遮(invoices_masked.sql:33-36)→
--   restricted = NOT has_permission('data.view_prices'),total 为 NULL;没有可见行时也照样返回那一行(受限不用零行表示)。
--   settled 不遮(invoice_status.sql:32),restricted 恒为 false。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与视图的谓词同一个码。invoker。
CREATE OR REPLACE FUNCTION public.list_totals_invoices(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_state text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_masked boolean;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_status = 'void' THEN
        RETURN;
    END IF;
    v_masked := NOT has_permission('data.view_prices');
    RETURN QUERY
    WITH a AS (
        SELECT count(*) AS n,
               sum(v.total_base) AS t,
               sum(v.settled_base) AS s,
               sum(v.open_base) AS o
          FROM invoice_status v
         WHERE (p_date_from IS NULL OR v.issue_date >= p_date_from)
           AND (p_date_to IS NULL OR v.issue_date <= p_date_to)
           AND (p_state IS NULL
                OR (p_state = 'overdue' AND v.overdue = true)
                OR (p_state <> 'overdue' AND v.payment_state = p_state))
    )
    SELECT ''::text,
           (SELECT c.code FROM currencies c WHERE c.is_base)::text,
           m.measure,
           CASE WHEN m.restr THEN NULL ELSE round(m.val, 2) END,
           m.restr
      FROM a
     CROSS JOIN LATERAL (VALUES (1, 'total'::text, a.t, v_masked),
                                (2, 'settled'::text, a.s, false),
                                (3, 'open'::text, a.o, v_masked)) AS m(ord, measure, val, restr)
     WHERE a.n > 0 OR m.restr
     ORDER BY m.ord;
END;
$function$;