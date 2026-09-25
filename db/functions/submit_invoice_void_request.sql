-- db/functions/submit_invoice_void_request.sql
-- APR-5a(2026-09-25):财务提一张作废发票的申请 —— 参数与 void_invoice 一字不差(发票、理由、冲销日),
-- CFO 批准那一刻按这一组作废并冲销(Tim 的矩阵「贷项通知、作废发票 | 财务 | CFO」,grilling Q9)。
-- 门 module.finance.edit(原 void_invoice 的门);其余全在 invoice_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_invoice_void_request(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN invoice_request_submit_internal(p_invoice_id, 'void', p_reversal_date, p_reason, NULL::jsonb);
END;
$function$
;