-- db/functions/list_totals_freight.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/freight 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/freight/freightRows.ts 的 freightCount / freightPage 同一个固定谓词:deleted_at IS NULL(页面没有 URL 筛选)。
--   页面只画前 200 张(RowCapNotice 说出来);合计是【所有】符合的单据,不是那 200 张。
-- 【量】amount = amount_base(页面那一列印的就是本位币),currency 给本位币代码。
-- 【净额】(Q2)冲销的运费单只翻成 reversed、金额仍是正数,没有镜像行(reverse_freight_document.sql:60 是 UPDATE)→
--   status = 'reversed' 的排除在外(加 0)。它们仍是列表上的行,所以只要有行,合计就在(全部冲销时读 0.00,不是没有合计)。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance) 同一个码(表的 SELECT 策略是
--   inbound.view OR finance.view,宽于这一页的门)。invoker;金额不遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_freight()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           (SELECT c.code FROM currencies c WHERE c.is_base)::text,
           'amount'::text,
           round(COALESCE(sum(f.amount_base) FILTER (WHERE f.status <> 'reversed'), 0), 2),
           false
      FROM freight_documents f
     WHERE f.deleted_at IS NULL
    HAVING count(*) > 0;
END;
$function$;