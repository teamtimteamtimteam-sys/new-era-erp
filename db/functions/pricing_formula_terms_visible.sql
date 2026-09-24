-- db/functions/pricing_formula_terms_visible.sql
-- ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线,grilling Q9):一条定价公式的【条款数字】(payable%、
-- TC、折扣)按【行】遮 —— 公式的 direction 说它是哪一侧的价格:
--   'sale'              → data.view_prices(销售那一侧,仓库永远拿不到)
--   'purchase' / 'both' → data.view_purchase_prices('both' 也用于采购,按采购那一侧算)
-- 【单独一支,不内联】三张公式视图与 calculate_metal_price 问的是同一句话,内联就是四份判据。
-- NULL 方向(公式不存在)按采购那一侧答 —— 调用方随后自己报"找不到"。
CREATE OR REPLACE FUNCTION public.pricing_formula_terms_visible(p_direction text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_direction = 'sale' THEN has_permission('data.view_prices')
                ELSE has_permission('data.view_purchase_prices') END;
$function$;
