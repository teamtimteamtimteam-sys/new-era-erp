CREATE OR REPLACE FUNCTION public.record_approval_decision(p_subject_type text, p_subject_id uuid, p_decision text, p_level smallint DEFAULT NULL::smallint, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_ccy  text;
    v_amt  numeric;
    v_rate numeric;
    v_base numeric;
    v_ok   boolean := false;
    v_id   uuid;
    v_base_ccy text;
BEGIN
    SELECT code INTO v_base_ccy FROM currencies WHERE is_base;

    -- 【外键没了,这一段就是它的替代】主体必须真的存在,并且顺手把编号与金额
    -- 冻结下来。不存在 → 点名拒绝,而不是插一行指向空气的留痕。
    CASE p_subject_type
        WHEN 'leave_request' THEN
            -- 请假没有金额:天数不是钱,不塞进币种列
            SELECT true, r.code INTO v_ok, v_code
              FROM leave_requests r WHERE r.id = p_subject_id;
        WHEN 'medical_claim' THEN
            -- amount_sgd 已经是本位币口径(列名是 FIN-0 之前留下的字面量,不是新的判断)
            SELECT true, c.code, c.amount_sgd, v_base_ccy, 1, c.amount_sgd
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM medical_claims c WHERE c.id = p_subject_id;
        WHEN 'performance_review' THEN
            SELECT true, e.code INTO v_ok, v_code
              FROM performance_reviews r JOIN employees e ON e.id = r.employee_id
             WHERE r.id = p_subject_id;
        WHEN 'purchase_order' THEN
            -- 【用单据自己存的汇率】(决定 3)—— 审批档次因此不会随行情事后漂移
            SELECT true, po.code, po.estimated_total_ccy, po.currency, po.fx_rate,
                   round(po.estimated_total_ccy * po.fx_rate, 2)
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM purchase_orders po WHERE po.id = p_subject_id;
        WHEN 'payment' THEN
            SELECT true, p.code, p.amount_ccy, p.currency, p.fx_rate, p.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM payments p WHERE p.id = p_subject_id;
        WHEN 'expense' THEN
            SELECT true, e.code, e.amount_ccy, e.currency, e.fx_rate, e.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM expenses e WHERE e.id = p_subject_id;
        WHEN 'pricing_formula' THEN
            SELECT true, f.code INTO v_ok, v_code
              FROM pricing_formulas f WHERE f.id = p_subject_id;
        WHEN 'stocktake' THEN
            SELECT true, s.code INTO v_ok, v_code
              FROM stocktakes s WHERE s.id = p_subject_id;
        WHEN 'work_order' THEN
            -- WO-1b:工单【没有金额】—— 它是一份要做什么的计划,不是一笔钱。
            -- 与 leave_request / performance_review / stocktake 同一类:
            -- 只冻结编号,金额那四列留空,而不是塞一个 0 进去
            -- (0 会让它在按金额筛的报表里排到最前面,那是一句假话)。
            SELECT true, w.code INTO v_ok, v_code
              FROM work_orders w WHERE w.id = p_subject_id;
        ELSE
            RAISE EXCEPTION 'APPROVAL_SUBJECT_TYPE_UNKNOWN|%', p_subject_type;
    END CASE;

    IF NOT COALESCE(v_ok, false) THEN
        RAISE EXCEPTION 'APPROVAL_SUBJECT_NOT_FOUND|%|%', p_subject_type, p_subject_id;
    END IF;

    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level,
                              actor_user_id, note, amount_ccy, currency, fx_rate, amount_base)
    VALUES (p_subject_type, p_subject_id, v_code, p_decision, p_level,
            auth.uid(), p_note, v_amt, v_ccy, v_rate, v_base)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$function$

;
