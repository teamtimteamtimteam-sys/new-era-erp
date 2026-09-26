-- db/functions/terms_request_fingerprint.sql
-- APR-8(2026-09-26,grilling Q5):主体此刻的样子 —— 提交时算一遍存进申请,批准时(terms_request_execute_internal)
-- 再算一遍,不一样 → TERMS_CHANGED_SINCE_REQUEST。公式:条款 + is_active + deleted_at;合同:表头 + 七张条款表 +
-- status + deleted_at。冻结让它在等待中几乎不会变 —— 这一道是给属主路径(迁移、修数)走过去的那一次留的。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_fingerprint(p_kind text, p_subject uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT md5(CASE WHEN p_kind = 'contract_activate' THEN
                   (SELECT jsonb_build_object('terms', contract_terms_state(c.id), 'status', c.status,
                                              'deleted_at', c.deleted_at)::text
                      FROM contracts c WHERE c.id = p_subject)
               ELSE
                   (SELECT jsonb_build_object('terms', formula_terms_state(f.id), 'is_active', f.is_active,
                                              'deleted_at', f.deleted_at)::text
                      FROM pricing_formulas f WHERE f.id = p_subject)
               END)
$function$;
