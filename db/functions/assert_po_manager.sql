-- db/functions/assert_po_manager.sql
-- APR-10(2026-09-27,Tim 的 grilling Q7):改 / 取消 / 关闭 / 重开一张采购单(以及给它套付款条款模板)的门。
--   PO_NOT_FOUND|<id>                                   单不存在或已删
--   PO_NOT_RAISER_OR_CATEGORY_HOLDER|<单号>|<那一类的码>  读者既不是开单人本人,也不持这一类的开单码
-- 判据只有一份:po_may_manage。批准 / 驳回【不走这里】—— 它们的门不变(Q7 最后一句)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.assert_po_manager(p_purchase_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code     text;
    v_category text;
BEGIN
    SELECT code, category INTO v_code, v_category
      FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF NOT po_may_manage(p_purchase_order_id) THEN
        RAISE EXCEPTION 'PO_NOT_RAISER_OR_CATEGORY_HOLDER|%|%', v_code, po_category_raise_code(v_category);
    END IF;
END;
$function$;
