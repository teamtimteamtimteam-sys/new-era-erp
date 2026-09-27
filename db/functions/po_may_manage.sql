-- db/functions/po_may_manage.sql
-- APR-10(2026-09-27,Tim 的 grilling Q7):读者这个人能不能改 / 取消 / 关闭 / 重开这张采购单。
--   能 = 开单人本人(按人认:self_leg 的 raiser 腿 —— 同一个人的另一个账号也算)
--     或 此刻持这张单那一类的开单码(po_category_raise_code)。
--   单不存在 / 已删 → false。
-- 屏幕用它画"按不动 + 理由";门用 assert_po_manager(同一份判据,按名拒)。
-- 只回答读者自己的一个布尔,所以 authenticated 调得到。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.po_may_manage(p_purchase_order_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((
        SELECT self_leg(po.created_by, NULL::uuid, auth.uid()) = 'raiser'
            OR has_permission(po_category_raise_code(po.category))
          FROM purchase_orders po
         WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL), false)
$function$;
