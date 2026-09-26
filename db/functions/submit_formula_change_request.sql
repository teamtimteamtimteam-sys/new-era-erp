-- db/functions/submit_formula_change_request.sql
-- APR-8(2026-09-26,grilling Q1):改一张在用的公式 = 一张带着【完整拟议条款】的申请;批准时就地替换。
-- 等待期间公式上仍是旧条款、旧条款照旧生效。门 module.pricing.edit(cco)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_formula_change_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.pricing.edit');
    IF p_terms IS NULL THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|terms';
    END IF;
    RETURN terms_request_submit_internal('formula_change', p_formula_id, p_terms, p_reason);
END;
$function$;
