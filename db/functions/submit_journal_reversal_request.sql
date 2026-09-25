-- db/functions/submit_journal_reversal_request.sql
-- APR-6(2026-09-25):财务提一张冲销申请 —— 冲一张【没有自己冲销路径】的分录(手工凭证,以及 sale ·
-- stocktake · writeoff · prepayment · revaluation · depreciation · asset_disposal · shipment · 工资付款分录;
-- grilling Q6 (i)(iii))。参数与 reverse_journal_entry 一字不差(分录、冲销日、理由),只是冲销日【必填】
-- (它决定期间 —— AGENTS.md:决定期间的日期从不代填)。CFO 批准那一刻按这一组冲。
-- 门 module.finance.edit(原 reverse_journal_entry 的门);其余全在 journal_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_journal_reversal_request(p_entry_id uuid, p_reversal_date date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN journal_request_submit_internal('reversal', p_reversal_date, p_reason, NULL::jsonb, p_entry_id);
END;
$function$;
