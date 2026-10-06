CREATE OR REPLACE FUNCTION public.submit_expense_claim(p_employee_id uuid, p_spend_date date, p_amount numeric, p_currency text, p_description text, p_no_receipt_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_emp employees%ROWTYPE; v_code text; v_id uuid; v_base numeric;
BEGIN
    -- 【自助:本人,或者持财务读权限的人代录】与 submit_medical_claim 同一条谓词
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.finance.view') OR p_employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF p_spend_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_REQUIRED';
    END IF;
    IF p_spend_date > CURRENT_DATE THEN
        -- 一笔"将来才会花的钱"不是报销,那是备用金 —— 而备用金被否决了(§0)
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_FUTURE|%|%', p_spend_date::text, CURRENT_DATE::text;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_INVALID|%', COALESCE(p_amount::text, '?');
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_CURRENCY_UNKNOWN|%', COALESCE(p_currency, '?');
    END IF;
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        -- 「买了什么」是审批人唯一能据以判断的东西
        RAISE EXCEPTION 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED';
    END IF;

    v_code := next_expense_claim_code(p_spend_date);
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, created_by)
    VALUES (v_code, p_employee_id, p_spend_date, p_amount, p_currency,
            btrim(p_description),
            NULLIF(btrim(COALESCE(p_no_receipt_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;

    -- ★ U1-B(ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的报销单那一半,与采购单 APR-10 同一个形状):
    --   审批开着时,按这张单会落到的那一级问一句"提单人与主角之外,有没有人批得动";没有 → 按名拒,整张单不落库
    --   (单号随回滚放回去)。主角要传 —— 报销单的四眼也看【报的是谁】(decide_expense_claim 的 forbid_self_approval)。
    --   【分档读同一份】expense_claim_amount_base 是 decide_expense_claim 分档用的那一支;折不出本位币(没有牌价)时
    --   不在这里另造一句拒绝 —— 那张单在决定时会被 fx_rate_for 按名拒(那句话归它),而在牌价补上之前谁都批不了它。
    IF approvals_enabled() THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(v_id) b;
        IF v_base IS NOT NULL THEN
            PERFORM assert_other_decider_for_subject('expense_claim', 'decide_expense_claim',
                                                     approval_level_for(v_base), p_employee_id,
                                                     'EXPENSE_CLAIM_NO_OTHER_DECIDER|' || v_code);
        END IF;
    END IF;

    RETURN jsonb_build_object('claim_id', v_id, 'code', v_code, 'status', 'submitted');
END;
$function$

;
