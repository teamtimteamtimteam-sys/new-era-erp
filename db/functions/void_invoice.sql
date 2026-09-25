-- db/functions/void_invoice.sql
-- APR-5a(2026-09-25):【一扇只会按名拒的门】作废一张发票要 CFO 批准(Tim 的矩阵「贷项通知、作废发票 |
-- 财务 | CFO」)。路径是 submit_invoice_void_request → decide_invoice_request,批准那一刻当场作废
-- (void_invoice_internal)。批准就是执行,所以这里永远没有一张"批了还没做"的申请 —— 本支对任何人
-- 都按名拒 INVOICE_NEEDS_APPROVED_REQUEST|发票(grilling Q9)。签名原样保留:旧页面、直连调用都听得见
-- 一个名字,而不是一次"找不到函数"。
-- NOTE: gate moved by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    RAISE EXCEPTION 'INVOICE_NEEDS_APPROVED_REQUEST|%', v_code;
END;
$function$
;