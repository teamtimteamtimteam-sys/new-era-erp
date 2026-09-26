-- db/functions/submit_contract_activation_request.sql
-- APR-8(2026-09-26,grilling Q2):一份草稿或暂停的合同申请生效。门 action.contract_terms(cco)。
-- 等待期间合同表头与七张条款表冻结;CFO 看见此刻的条款与上一次批准时那一份的差别。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_contract_activation_request(p_contract_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.contract_terms');
    RETURN terms_request_submit_internal('contract_activate', p_contract_id, NULL, p_reason);
END;
$function$;
