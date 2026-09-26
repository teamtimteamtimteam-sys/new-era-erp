-- db/functions/submit_formula_create_request.sql
-- APR-8(2026-09-26,grilling Q1):新建一张定价公式 = 建一张【停用着】的公式 + 一张 formula_create 申请。
-- 门 module.pricing.edit(cco)。公式在 CFO 批准之前不能用(pricing_terms_of_formula 按名拒 FORMULA_INACTIVE);
-- 驳回或撤回后它停用着留下,cco 改了条款再提 formula_reactivate。提交里任何一处按名拒 = 整笔回滚,公式也不留。
-- 审批关着时生下来就批准并生效。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_formula_create_request(p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t  jsonb;
    v_id uuid;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    v_t := formula_terms_normalize(p_terms);
    INSERT INTO pricing_formulas (code, name, direction, price_basis, average_days, treatment_charge_usd_per_tonne,
                                  flat_discount_pct, supplier_id, customer_id, price_index, notes, is_active)
    VALUES ('', v_t->>'name', v_t->>'direction', v_t->>'price_basis', (v_t->>'average_days')::integer,
            (v_t->>'treatment_charge_usd_per_tonne')::numeric, (v_t->>'flat_discount_pct')::numeric,
            (v_t->>'supplier_id')::uuid, (v_t->>'customer_id')::uuid, v_t->>'price_index', v_t->>'notes', false)
    RETURNING id INTO v_id;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    SELECT v_id, e->>'metal', (e->>'payable_pct')::numeric FROM jsonb_array_elements(v_t->'metals') e;
    RETURN terms_request_submit_internal('formula_create', v_id, v_t, p_reason) || jsonb_build_object('formula_id', v_id);
END;
$function$;
