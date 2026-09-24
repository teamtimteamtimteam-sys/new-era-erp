CREATE OR REPLACE FUNCTION public.preview_reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 4a:这是定价面板的试算 —— 与它提交的那扇门同一对码:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');
    v_calc := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 单价 ≤ 0 时不试算拆账(它会 PRICE_INVALID),但明细照给 —— 那种料
    -- apply_assay_result 本来也不会给它定价,摆一个"调整 −X 元"反而是误导。
    IF v_unit > 0 THEN
        -- 币种显式:提交路径 reprice_from_committed_terms 也是按 USD 递进去的
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;