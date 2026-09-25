-- db/functions/submit_journal_request.sql
-- APR-6(2026-09-25):财务提一张手工凭证 —— 参数就是手工凭证页一直交给 post_journal_entry 的那一组
-- (凭证日、摘要、行),只是少了 source_type 与 source_id:过出来的永远是 'manual',source_id 指回申请
-- (grilling Q1 · Q3)。CFO 批准那一刻按这一组过账。人手里能过一张手工凭证的门,只剩这一扇。
-- 门 module.finance.edit(矩阵「做:= 不变」);其余全在 journal_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_journal_request(p_entry_date date, p_memo text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN journal_request_submit_internal('entry', p_entry_date, p_memo, p_lines, NULL::uuid);
END;
$function$;
