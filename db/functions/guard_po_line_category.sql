-- db/functions/guard_po_line_category.sql
-- APR-10(2026-09-27,Tim 的 grilling Q5):一张单的品类由开单人选,但有两种行只能出现在「设备与货物」里 ——
--   · 资产行(asset_id 不空):那是设备;
--   · 电池料行(materials.kind_code = 'battery_material'):那是货物 —— 公司买来加工的原料。
--   其余的行,开单人选哪一类就是哪一类。违反 → PO_CATEGORY_LINE_MISMATCH|<单号>|<行号>|<品类>。
-- 挂在 purchase_order_lines 上(INSERT 与 UPDATE),所以开单与改单两条路都经过它。
-- ☞ 它认的是物料【目录上】的 kind_code:一个没填 kind_code 的物料它看不见(APR-10 交回时量过线上有这样的物料)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.guard_po_line_category()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code     text;
    v_category text;
BEGIN
    SELECT code, category INTO v_code, v_category FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF v_category IS DISTINCT FROM 'equipment_goods'
       AND (NEW.asset_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM materials m
                        WHERE m.id = NEW.material_id AND m.kind_code = 'battery_material')) THEN
        RAISE EXCEPTION 'PO_CATEGORY_LINE_MISMATCH|%|%|%', v_code, NEW.line_no, v_category;
    END IF;
    RETURN NEW;
END;
$function$;
