-- db/functions/supplier_grade_advice_internal.sql
-- MES-8a(2026-10-16,MES-0 Q77 · MES-8 Step 0 Q2 · Q5,Tim):【一家供应商此刻的等级建议】—— 一处实现,三个调用者:
--   create_purchase_order(返回值里的 warnings)、采购单表单(经 supplier_grade_advice 在提交之前预览)、收货页(抽样建议)。
--   读【最近一次没有被取代的评审】(supplier_latest_reviews —— 一处定义;按 seq,被另一次评审更正过的那一次已被取代)—— 以及【那一次评审抄下的】V24,不是今天的设定(Q2)。
--   没有评审 / 最近那一次没评出等级(V23 没给)→ 不给任何效果(Q4)。
--   预付:p_payment_terms 是采购单的付款计划(与 create_purchase_order 同一个形状);"下单时"(on_order)那几期的百分比之和,加上定额 ÷ 预估总额 × 100
--   —— 预估总额不是正数时定额折不出百分比,on_order_pct 为 null(not_computable),不猜。超过本等级的上限 → 一条 PREPAYMENT_ABOVE_GRADE_CAP 警告。
--   【只警告,从不拒绝】(Q5 / Q77:"Tim 以后可以把警告改成拒绝,改设定,不改代码" —— 那一天是另一次裁定)。
--   抽样级别:原样给出,只是建议 —— 不加任何一项必须的化验(登记 MES8A-SAMPLING-LEVEL-ADDS-NO-ASSAY)。
--   内层:不查调用者的码(create_purchase_order 已经查过它自己的;对外的那一支 supplier_grade_advice 查 module.suppliers.view),authenticated 调不到。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.supplier_grade_advice_internal(p_supplier_id uuid, p_payment_terms jsonb, p_estimated_total_ccy numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        supplier_scorecard_reviews%ROWTYPE;
    v_cap      numeric;
    v_level    text;
    v_pct      numeric;
    v_fixed    numeric;
    v_on_order boolean := false;
    v_pct_ok   boolean := true;
    v_warn     jsonb := '[]'::jsonb;
BEGIN
    SELECT r.* INTO v_r
      FROM supplier_scorecard_reviews r
     WHERE r.id = (SELECT l.id FROM supplier_latest_reviews l WHERE l.supplier_id = p_supplier_id);
    IF NOT FOUND THEN
        RETURN jsonb_build_object('reviewed', false, 'graded', false, 'review_id', NULL, 'grade', NULL,
                                  'prepayment_cap_pct', NULL, 'sampling_level', NULL, 'on_order_pct', NULL, 'warnings', '[]'::jsonb);
    END IF;

    IF v_r.grade IS NOT NULL THEN
        v_cap   := (v_r.grade_caps -> v_r.grade ->> 'prepayment_cap_pct')::numeric;
        v_level := v_r.grade_caps -> v_r.grade ->> 'sampling_level';
    END IF;

    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array' THEN
        SELECT COALESCE(sum((t ->> 'percentage')::numeric), 0), sum((t ->> 'fixed_amount_ccy')::numeric), count(*) > 0
          INTO v_pct, v_fixed, v_on_order
          FROM jsonb_array_elements(p_payment_terms) t
         WHERE t ->> 'trigger_event' = 'on_order';
        IF v_fixed IS NOT NULL THEN
            IF p_estimated_total_ccy IS NULL OR p_estimated_total_ccy <= 0 THEN
                v_pct_ok := false;
            ELSE
                v_pct := v_pct + v_fixed / p_estimated_total_ccy * 100;
            END IF;
        END IF;
        IF NOT v_pct_ok THEN
            v_pct := NULL;
        ELSE
            v_pct := round(v_pct, 2);
        END IF;
    ELSE
        v_pct := NULL;
    END IF;

    IF v_r.grade IS NOT NULL AND v_cap IS NOT NULL AND v_pct IS NOT NULL AND v_pct > v_cap THEN
        v_warn := jsonb_build_array(jsonb_build_object(
            'code', 'PREPAYMENT_ABOVE_GRADE_CAP', 'grade', v_r.grade, 'cap_pct', v_cap, 'on_order_pct', v_pct,
            'review_id', v_r.id));
    END IF;

    RETURN jsonb_build_object(
        'reviewed',           true,
        'graded',             v_r.grade IS NOT NULL,
        'review_id',          v_r.id,
        'reviewed_at',        v_r.recorded_at,
        'window_from',        v_r.window_from,
        'window_to',          v_r.window_to,
        'grade',              v_r.grade,
        'not_graded_reason',  v_r.not_graded_reason,
        'prepayment_cap_pct', v_cap,
        'sampling_level',     v_level,
        'on_order_pct',       v_pct,
        'on_order_not_computable', (v_on_order AND NOT v_pct_ok),
        'warnings',           v_warn);
END;
$function$
