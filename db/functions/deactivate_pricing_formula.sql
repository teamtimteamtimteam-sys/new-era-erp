-- db/functions/deactivate_pricing_formula.sql
-- APR-8(2026-09-26,grilling Q1):停用一张公式仍是 cco 一步 —— 它只会让能用的公式变少(此后计价器、建采购单、
-- 应用化验按名拒 FORMULA_INACTIVE;已抄下的承诺不受影响)。门 module.pricing.edit。等待中的申请挂在它上面 →
-- TERMS_REQUEST_OPEN(先撤回)。重新启用要经 CFO(submit_formula_reactivate_request)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.deactivate_pricing_formula(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code   text;
    v_active boolean;
    v_open   text;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    SELECT code, is_active INTO v_code, v_active FROM pricing_formulas
     WHERE id = p_formula_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    SELECT label INTO v_open FROM terms_requests WHERE formula_id = p_formula_id AND status = 'submitted';
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'TERMS_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    IF NOT v_active THEN
        RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_code;
    END IF;
    UPDATE pricing_formulas SET is_active = false WHERE id = p_formula_id;
    RETURN jsonb_build_object('formula_id', p_formula_id, 'code', v_code, 'is_active', false);
END;
$function$;
