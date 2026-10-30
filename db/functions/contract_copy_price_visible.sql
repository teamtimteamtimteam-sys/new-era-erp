-- db/functions/contract_copy_price_visible.sql
-- GOLIVE-2(Tim 2026-10-30 Q4):合同条款的【冻结副本】(contract_document_terms)上的价格对当前读者看不看得见 —— 按【副本自己那一侧】:
--   挂在销售单上(sales_order_id)→ data.view_prices;挂在采购单上(purchase_order_id)→ data.view_purchase_prices;两边都空 → false(关着失败)。
--   与 contract_terms_price_visible 等价(link_document_to_contract 只把销售单挂客户合同、采购单挂供应商合同),但不回头去读合同 ——
--   副本的表注说「任何读取路径都不许拿 contract_id 回查」。contract_document_terms_masked 与变更记录的 cdt_price 规则问的都是这一支。
--   SECURITY INVOKER:它不读任何表,has_permission() 解析的始终是调用者。
CREATE OR REPLACE FUNCTION public.contract_copy_price_visible(p_sales_order_id uuid, p_purchase_order_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_sales_order_id IS NOT NULL THEN has_permission('data.view_prices')
                WHEN p_purchase_order_id IS NOT NULL THEN has_permission('data.view_purchase_prices')
                ELSE false END;
$function$;
