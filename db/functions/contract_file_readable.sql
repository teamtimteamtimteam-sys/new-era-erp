-- db/functions/contract_file_readable.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q8):调用者读不读得到这份合同的电子文件 —— 合同那一侧的读码【加上】那一侧的价格码:
--   客户合同 module.customers.view + data.view_prices;供应商合同 module.suppliers.view + data.view_purchase_prices。
--   PDF 里写着价格,所以文件跟着价格码走(GOLIVE-1 第 12 行按那一侧遮价格,同一个判据)。合同不存在 → false(关着失败)。
--   contract_files 的读策略、contract-files 桶的存储判据与写那几支函数问的都是这一句。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_readable(p_contract_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT CASE WHEN c.customer_id IS NOT NULL THEN has_permission('module.customers.view') AND has_permission('data.view_prices')
                                 WHEN c.supplier_id IS NOT NULL THEN has_permission('module.suppliers.view') AND has_permission('data.view_purchase_prices')
                                 ELSE false END
                       FROM contracts c WHERE c.id = p_contract_id AND c.deleted_at IS NULL), false);
$function$;
