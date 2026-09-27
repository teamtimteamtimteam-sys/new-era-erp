-- db/functions/contract_terms_lock_reason.sql
-- APR-8(2026-09-26,grilling Q2 · Q5):一份合同此刻为什么不许直连改 —— 两支守卫(合同表头、七张条款表)的一份判据。
--   'request:<label>'  有一张在等的生效申请(TERMS_REQUEST_FREEZES_CONTRACT / CONTRACT_TERMS_FROZEN)
--   'active'           合同在生效中:条款冻结;表头只许把状态改成暂停 / 到期 / 终止
--   'expired' / 'terminated'  ★ TERMS-EDIT-1(Tim 2026-09-27,grilling Q4):已经结束的合同,七张条款表也冻结 ——
--                      一份到期或终止了的协议,它当时约定的是什么是一件已经发生的事,改它就是改历史。
--                      (表头那一支 guard_contract_write 只读 'request:',所以这两个值不改变表头的规矩。)
--   NULL               草稿、暂停,或不存在:照改
-- SECURITY DEFINER:守卫以调用者身份跑,而调用者未必读得到申请表(它只给 CFO 那一组码)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql;
--       replaced by db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql (expired / terminated).

CREATE OR REPLACE FUNCTION public.contract_terms_lock_reason(p_contract_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT 'request:' || r.label FROM terms_requests r
          WHERE r.contract_id = p_contract_id AND r.status = 'submitted' LIMIT 1),
        (SELECT c.status FROM contracts c
          WHERE c.id = p_contract_id AND c.status IN ('active', 'expired', 'terminated')))
$function$;
