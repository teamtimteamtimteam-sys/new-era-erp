-- db/functions/delete_pricing_formula.sql
-- APR-8(2026-09-26,grilling Q1):删除(软删)一张公式仍是 cco 一步 —— 只会让能用的变少。门 module.pricing.edit。
-- 等待中的申请挂在它上面 → TERMS_REQUEST_OPEN(先撤回)。原来这一步是屏幕直连 UPDATE deleted_at;公式表从此
-- 没有直连写(guard_pricing_formula_direct_write),于是它有了自己的门。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.delete_pricing_formula(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_open text;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    SELECT code INTO v_code FROM pricing_formulas WHERE id = p_formula_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    SELECT label INTO v_open FROM terms_requests WHERE formula_id = p_formula_id AND status = 'submitted';
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'TERMS_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    UPDATE pricing_formulas SET deleted_at = now() WHERE id = p_formula_id;
    RETURN jsonb_build_object('formula_id', p_formula_id, 'code', v_code, 'deleted', true);
END;
$function$;
