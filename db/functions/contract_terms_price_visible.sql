-- db/functions/contract_terms_price_visible.sql
-- GOLIVE-1 第 12 行(Tim 2026-10-25 TABLE-EXPORT-3c Q3 · 2026-10-29 Q9):一份合同条款上的【价格数字】对当前读者看不看得见 ——
--   按合同的【那一侧】:
--     客户合同(customer_id 不空)→ data.view_prices        (销售那一侧的价格)
--     供应商合同(supplier_id 不空)→ data.view_purchase_prices(采购那一侧;那个码的说明里写着「committed terms」)
--   合同不存在 / 两边都空 → false(关着失败)。
-- 【单独一支,不内联】四张条款视图(contract_*_masked)与变更记录的遮蔽规则(change_log_rule_visible 的 contract_price)问的是同一句话 ——
--   与 pricing_formula_terms_visible 同一个理由:内联就是五份判据。
-- 【SECURITY DEFINER】它要读 contracts 的那一侧,而那一行对读者的行级策略是另一回事(读者在别处问的是"这一行看不看得见");
--   返回的只是一个布尔,而且 has_permission() 解析的始终是【调用者】。anon 不可执行。
CREATE OR REPLACE FUNCTION public.contract_terms_price_visible(p_contract_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT CASE WHEN c.customer_id IS NOT NULL THEN has_permission('data.view_prices')
                                 WHEN c.supplier_id IS NOT NULL THEN has_permission('data.view_purchase_prices')
                                 ELSE false END
                       FROM contracts c WHERE c.id = p_contract_id), false);
$function$;
