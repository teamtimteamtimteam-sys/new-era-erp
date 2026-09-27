-- db/functions/po_category_raise_code.sql
-- APR-10(2026-09-27,Tim 的矩阵 §6「开采购单,按品类」· grilling Q6):一个品类 → 开这一类单的那一个码。
-- 【一份定义】create_purchase_order(开单的门)、po_may_manage(改 / 取消 / 关闭 / 重开的门)、屏幕上每一个
-- 品类选项的禁用理由,都读这里。不认识的品类 → NULL(调用方按名拒 PO_CATEGORY_INVALID)。
--   consumables     工厂耗材   action.raise_po_consumables   仓库
--   equipment_goods 设备与货物 action.raise_po_equipment     cco
--   office          办公用品   action.raise_po_office        财务
-- (admin 三个都持 —— Tim 的常设裁定:每一个新码同一迁移里也授给 admin。)
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.po_category_raise_code(p_category text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_category
        WHEN 'consumables'     THEN 'action.raise_po_consumables'
        WHEN 'equipment_goods' THEN 'action.raise_po_equipment'
        WHEN 'office'          THEN 'action.raise_po_office'
    END
$function$;
