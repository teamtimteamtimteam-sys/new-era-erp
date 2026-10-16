-- db/functions/supplier_grade_advice.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q5 · Q91):对外的那一支 —— 采购单表单(提交之前预览警告、供应商旁边显示最近的等级)与收货页(抽样建议)读它。
--   门 module.suppliers.view(Q91:分数跟着供应商的查看码);其余全在 supplier_grade_advice_internal(与 create_purchase_order 同一份)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.supplier_grade_advice(p_supplier_id uuid, p_payment_terms jsonb DEFAULT NULL::jsonb, p_estimated_total_ccy numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.suppliers.view');
    RETURN supplier_grade_advice_internal(p_supplier_id, p_payment_terms, p_estimated_total_ccy);
END;
$function$
