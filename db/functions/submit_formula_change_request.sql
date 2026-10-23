-- db/functions/submit_formula_change_request.sql
-- APR-8(2026-09-26,grilling Q1):改一张在用的公式 = 一张带着【完整拟议条款】的申请;批准时就地替换。
-- 等待期间公式上仍是旧条款、旧条款照旧生效。门 module.pricing.edit(cco)。
-- ★ TABLE-EXPORT-2b-1(Tim 2026-10-23,TABLE-EXPORT-2b Q5):看不见这张公式条款的人(pricing_formula_terms_visible(此刻的方向) 为假)
--   提的修改,加工费 · 折扣 · 计价比例三项【一律取库里此刻的值】—— 他屏幕上那三格是「受限」,送来的什么都不是他看过的数;
--   formula_terms_normalize 又会把缺的两项读成 0。于是一次只改名字的保存曾经能把加工费与折扣改成 0、把比例清空。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql;
--       replaced by db/migrations/2026-10-23-table-export-2b1-formula-masked-terms-unchanged.sql (Q5).

CREATE OR REPLACE FUNCTION public.submit_formula_change_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dir text;
    v_now jsonb;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    IF p_terms IS NULL THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|terms';
    END IF;
    SELECT direction INTO v_dir FROM pricing_formulas WHERE id = p_formula_id AND deleted_at IS NULL;
    IF v_dir IS NOT NULL AND NOT pricing_formula_terms_visible(v_dir) THEN
        v_now := formula_terms_state(p_formula_id);
        p_terms := p_terms || jsonb_build_object(
            'treatment_charge_usd_per_tonne', v_now->'treatment_charge_usd_per_tonne',
            'flat_discount_pct', v_now->'flat_discount_pct',
            'metals', v_now->'metals');
    END IF;
    RETURN terms_request_submit_internal('formula_change', p_formula_id, p_terms, p_reason);
END;
$function$;
