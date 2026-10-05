-- db/functions/approval_log_readable.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):approval_log 的【读规则】,从那条策略的 CASE 里原样抽出来 ——
--   基表的 "approval_log select by permission" 与新的 approval_log_masked 视图调【同一支】函数,于是"谁看得见哪一类留痕"
--   只有一份定义(属主视图绕过 RLS,视图里必须重写一遍行谓词;重写一遍就是两份,两份必然漂开)。
-- 【逐字搬过来,一支都没改】每一支的来历注释留在 db/tables/approval_log.sql 那条策略的上方。
-- 【不是 SECURITY DEFINER】它只读 has_permission();RLS 求值要它对 authenticated 可执行。
CREATE OR REPLACE FUNCTION public.approval_log_readable(p_subject_type text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_subject_type
        WHEN 'leave_request'          THEN has_permission('module.hr.view'::text)
        WHEN 'medical_claim'          THEN has_permission('module.hr.view'::text)
        WHEN 'performance_review'     THEN has_permission('module.hr.view'::text)
        WHEN 'purchase_order'         THEN has_permission('module.purchasing.view'::text)
        WHEN 'payment'                THEN has_permission('module.finance.view'::text)
        WHEN 'expense'                THEN has_permission('module.finance.view'::text)
        WHEN 'expense_claim'          THEN has_permission('module.finance.view'::text)
        WHEN 'pricing_formula'        THEN has_permission('module.pricing.view'::text)
        WHEN 'stocktake'              THEN has_permission('module.stocktakes.view'::text)
        WHEN 'work_order'             THEN has_permission('module.processing.view'::text)
        WHEN 'payment_request'        THEN has_permission('module.finance.view'::text)
        WHEN 'supplier'               THEN has_permission('module.suppliers.view'::text)
        WHEN 'payroll_request'        THEN has_permission('module.hr.view'::text)
        WHEN 'receipt_price_request'  THEN has_permission('module.inbound.view'::text)
                                           AND has_permission('data.view_purchase_prices'::text)
        WHEN 'invoice_request'        THEN has_permission('module.finance.view'::text)
        WHEN 'shipping_release'       THEN has_permission('module.sales.view'::text)
        WHEN 'journal_request'        THEN has_permission('module.finance.view'::text)
        WHEN 'warehouse_request'      THEN has_permission('module.finance.view'::text)
        WHEN 'terms_request'          THEN has_permission('module.pricing.view'::text)
        WHEN 'salary_change_request'  THEN has_permission('module.hr.view'::text)
                                           AND has_permission('data.view_pay'::text)
        WHEN 'asset_disposal_request' THEN has_permission('module.finance.view'::text)
        WHEN 'gst_filing_request'     THEN has_permission('module.finance.view'::text)
        WHEN 'overtime_batch'         THEN (has_permission('module.hr.view'::text)
                                            OR has_permission('action.overtime_enter'::text)
                                            OR has_permission('action.overtime_approve'::text))
        ELSE false
    END;
$function$
