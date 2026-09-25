-- db/functions/submit_credit_note_request.sql
-- APR-5a(2026-09-25):财务提一张贷项通知的申请 —— 参数与 create_credit_note 一字不差(发票、凭证日、
-- 理由、行),CFO 批准那一刻按这一组过账(Tim 的矩阵「贷项通知、作废发票 | 财务 | CFO」,grilling Q9)。
-- 门 module.finance.edit(原 create_credit_note 的门);其余全在 invoice_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_credit_note_request(p_invoice_id uuid, p_note_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN invoice_request_submit_internal(p_invoice_id, 'credit_note', p_note_date, p_reason, p_lines);
END;
$function$
;