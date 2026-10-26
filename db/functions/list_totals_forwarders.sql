-- db/functions/list_totals_forwarders.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/logistics/forwarders 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/logistics/forwarders/page.tsx 同一个集合:货代 = supplier_lookup 里 counterparty_type = 'forwarder'、
--   deleted_at IS NULL(:36-44);欠款 = ap_open_items 里 counterparty_id 属于这些货代的 open_base(:83-94)。
-- 【合计】owed —— Σ open_base,本位币(currencies.is_base;页面 :95-99 同一个来源)。每一行「未结应付」照旧在页面上加。
-- 【净额】ap_open_items 自己已经只留未结的、并去掉了被冲销的费用(ap_open_items.sql:152-154)—— 这里不再另算。
-- 【门】require_permission('module.logistics.view') —— 与页面守卫(requireModule(MOD.logistics))同一个码。invoker。
-- 【受限】整个读者:NOT has_permission('module.finance.view')(视图对不持它的人回零行,ap_open_items.sql:178)
--   OR NOT has_permission('data.view_purchase_prices')(视图读 inbound_batches_masked 并只留 unit_price IS NOT NULL,
--   不持它的人【悄悄少了】每一笔入库应付,:110,119;预付抵扣也按它遮成 0)。受限而一行都看不见时 currency 给 NULL。
CREATE OR REPLACE FUNCTION public.list_totals_forwarders()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hidden boolean;
BEGIN
    PERFORM require_permission('module.logistics.view');
    v_hidden := NOT has_permission('module.finance.view') OR NOT has_permission('data.view_purchase_prices');
    RETURN QUERY
    SELECT ''::text,
           CASE WHEN count(*) > 0 THEN (SELECT c.code FROM currencies c WHERE c.is_base)::text END,
           'owed'::text,
           CASE WHEN v_hidden THEN NULL::numeric ELSE round(sum(o.open_base), 2) END,
           v_hidden
      FROM ap_open_items o
     WHERE o.counterparty_id IN (SELECT f.id FROM supplier_lookup f
                                  WHERE f.counterparty_type = 'forwarder' AND f.deleted_at IS NULL)
    HAVING count(*) > 0 OR v_hidden;
END;
$function$;