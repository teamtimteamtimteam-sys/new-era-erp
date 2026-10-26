-- db/functions/list_totals_purchase_orders.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/purchasing/orders 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/purchasing/orders/orderRows.ts 逐项同一套(parsePoListParams :48-57 · applyFilters :84-90 · applyStatus :91-95):
--   order_date ≥ from、≤ to、supplier_id = 供应商;状态 = cancelled 时读 purchase_orders_masked(status = 'cancelled',
--   deleted_at IS NULL —— 与 poPage 那一支同一个关系,orderRows.ts:117-126),否则读 purchase_order_status
--   (它自己排除已取消与已删除,purchase_order_status.sql 末尾)并按 status = 状态。
-- 【合计】每个单据币种一行:net(estimated_total_ccy)、tax(tax_total_ccy,只加 carries_tax 的单 —— 未计税的单税额是
--   【合法的 NULL】,屏幕印「—」,不是遮;一张计税的单都没有的币种不回 tax)、gross(gross_total_ccy = 净额 + COALESCE(税,0),
--   与屏幕 orderRows.ts:190 同一个数)。prepaid(prepaid_base)是本位币,另一行;只在非已取消那一支(已取消那一支屏幕上是 n/a)。
-- 【净额】采购单没有冲销镜像行;已取消的单默认不在集合里(与列表同),只在筛「已取消」时自成一个集合。
-- 【门】require_permission('module.purchasing.view') —— 与页面守卫(requireModule(MOD.purchasing))、两张视图的行谓词同一个码。invoker。
-- 【受限】整个读者:net / tax / gross = NOT has_permission('data.view_purchase_prices')(purchase_orders_masked.sql 的 CASE);
--   prepaid = NOT has_permission('module.finance.view')(purchase_order_status.sql 的 CASE)。受限而一行都没有时,
--   仍每个 measure 回一行(currency NULL,total NULL,restricted true)。
CREATE OR REPLACE FUNCTION public.list_totals_purchase_orders(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_supplier uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_price_hidden boolean;
    v_prepaid_hidden boolean;
    v_cancelled boolean;
    v_base text;
BEGIN
    PERFORM require_permission('module.purchasing.view');
    v_price_hidden := NOT has_permission('data.view_purchase_prices');
    v_prepaid_hidden := NOT has_permission('module.finance.view');
    v_cancelled := COALESCE(p_status = 'cancelled', false);
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    RETURN QUERY
    WITH r AS (
        SELECT po.currency::text AS ccy, po.estimated_total_ccy AS net, po.tax_total_ccy AS tax,
               po.gross_total_ccy AS gross, po.carries_tax AS taxed, NULL::numeric AS prepaid
          FROM purchase_orders_masked po
         WHERE v_cancelled
           AND po.status = 'cancelled' AND po.deleted_at IS NULL
           AND (p_date_from IS NULL OR po.order_date >= p_date_from)
           AND (p_date_to IS NULL OR po.order_date <= p_date_to)
           AND (p_supplier IS NULL OR po.supplier_id = p_supplier)
        UNION ALL
        SELECT s.currency::text, s.estimated_total_ccy, s.tax_total_ccy,
               s.gross_total_ccy, s.carries_tax, s.prepaid_base
          FROM purchase_order_status s
         WHERE NOT v_cancelled
           AND (p_date_from IS NULL OR s.order_date >= p_date_from)
           AND (p_date_to IS NULL OR s.order_date <= p_date_to)
           AND (p_supplier IS NULL OR s.supplier_id = p_supplier)
           AND (p_status IS NULL OR s.status = p_status)
    ), by_ccy AS (
        SELECT r.ccy, sum(r.net) AS net, sum(r.tax) FILTER (WHERE r.taxed) AS tax, bool_or(r.taxed) AS any_taxed,
               sum(r.gross) AS gross
          FROM r
         GROUP BY r.ccy
    )
    SELECT ''::text, b.ccy, m.k, CASE WHEN v_price_hidden THEN NULL::numeric ELSE round(m.v, 2) END, v_price_hidden
      FROM by_ccy b CROSS JOIN LATERAL (VALUES ('net'::text, b.net, true), ('tax'::text, b.tax, b.any_taxed),
                                               ('gross'::text, b.gross, true)) m(k, v, present)
     WHERE m.present OR v_price_hidden
    UNION ALL
    SELECT ''::text, NULL::text, m.k, NULL::numeric, true
      FROM (VALUES ('net'::text), ('tax'::text), ('gross'::text)) m(k)
     WHERE v_price_hidden AND NOT EXISTS (SELECT 1 FROM r)
    UNION ALL
    SELECT ''::text, CASE WHEN EXISTS (SELECT 1 FROM r) THEN v_base END, 'prepaid'::text,
           CASE WHEN v_prepaid_hidden THEN NULL::numeric ELSE round(sum(r.prepaid), 2) END, v_prepaid_hidden
      FROM r
    HAVING NOT v_cancelled AND (count(*) > 0 OR v_prepaid_hidden)
     ORDER BY 2, 3;
END;
$function$;