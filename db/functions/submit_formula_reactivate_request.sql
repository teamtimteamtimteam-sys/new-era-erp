-- db/functions/submit_formula_reactivate_request.sql
-- APR-8(2026-09-26,grilling Q1):让一张停用的公式重新生效(停用过的,或新建时被驳回 / 撤回的)。
-- p_terms 给了就是拟议条款(批准时写进去);NULL = 按公式上此刻的条款。门 module.pricing.edit(cco)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_formula_reactivate_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.pricing.edit');
    RETURN terms_request_submit_internal('formula_reactivate', p_formula_id, p_terms, p_reason);
END;
$function$;
