-- db/functions/submit_expense_claim_items.sql
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q4 · Q5 · Q7):提交一张【多笔】报销单。
--   p_purpose  —— 整张单的用途(必填;落进 expense_claims.description,搜索读它,Q7);
--   p_items    —— [{spend_date, amount, description, no_receipt_reason?}, ...],至少一笔。金额是【收据上的总额】(含税,与此前一样)。
--   一张单一个币种(Q4)。日期(Q5,两条都按名拒):
--     · 所有明细落在【同一个日历月】—— 一张单生出一张费用单,一张费用单只有一个入账期间
--       (EXPENSE_CLAIM_ITEMS_SPAN_MONTHS|最早|最晚);
--     · 非本位币的单,所有明细【同一天】—— 一张费用单只有一个汇率,而汇率规矩是"按交易自己那一天"
--       (EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE|币种|最早|最晚)。
--   表头 spend_date = 最晚那一笔(它决定审批档次、默认入账日与汇率);amount_ccy = 明细之和 —— 两样都由
--   guard_expense_claim_totals 在提交时强制。科目与税码【不在这里】:那是财务批准时逐笔给的(Step 0b Q1)。
--   submit_expense_claim(旧签名)是这一支的【单笔包装】(Q8)。
CREATE OR REPLACE FUNCTION public.submit_expense_claim_items(p_employee_id uuid, p_currency text, p_purpose text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   employees%ROWTYPE;
    v_code  text;
    v_id    uuid;
    v_base  numeric;
    v_n     integer;
    v_i     integer;
    v_it    jsonb;
    v_date  date;
    v_amt   numeric;
    v_first date;
    v_last  date;
    v_total numeric := 0;
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
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_REQUIRED';
    END IF;
    v_n := jsonb_array_length(p_items);
    -- 逐笔:日期必填、不晚于今天,金额为正(多笔的单错误码带一个 '|<第几笔>' 尾巴;单笔与此前逐字相同)
    FOR v_i IN 1 .. v_n LOOP
        v_it := p_items -> (v_i - 1);
        IF jsonb_typeof(v_it) <> 'object' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_INVALID|%', v_i;
        END IF;
        v_date := NULLIF(v_it->>'spend_date', '')::date;
        IF v_date IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_REQUIRED%', CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        END IF;
        IF v_date > CURRENT_DATE THEN
            -- 一笔"将来才会花的钱"不是报销,那是备用金 —— 而备用金被否决了(§0)
            RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_FUTURE|%|%', v_date::text, CURRENT_DATE::text;
        END IF;
        v_amt := NULLIF(v_it->>'amount', '')::numeric;
        IF v_amt IS NULL OR v_amt <= 0 THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_INVALID|%', COALESCE(v_amt::text, '?');
        END IF;
        v_first := LEAST(COALESCE(v_first, v_date), v_date);
        v_last  := GREATEST(COALESCE(v_last, v_date), v_date);
        v_total := v_total + v_amt;
    END LOOP;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_CURRENCY_UNKNOWN|%', COALESCE(p_currency, '?');
    END IF;
    FOR v_i IN 1 .. v_n LOOP
        IF NULLIF(btrim(COALESCE(p_items -> (v_i - 1) ->> 'description', '')), '') IS NULL THEN
            -- 「买了什么」是审批人唯一能据以判断的东西 —— 逐笔
            RAISE EXCEPTION 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED%', CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        END IF;
    END LOOP;
    IF p_purpose IS NULL OR btrim(p_purpose) = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_PURPOSE_REQUIRED';
    END IF;
    -- Q5:同一个日历月;非本位币同一天
    IF date_trunc('month', v_first) <> date_trunc('month', v_last) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_SPAN_MONTHS|%|%', v_first::text, v_last::text
          USING HINT = '一张报销单生出一张费用单,只有一个入账期间 —— 跨月的花销分成每月一张';
    END IF;
    IF p_currency <> base_currency_code() AND v_first <> v_last THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE|%|%|%', p_currency, v_first::text, v_last::text
          USING HINT = '外币报销单只有一个汇率,而汇率按花钱那一天取 —— 不同日子的外币花销分开报';
    END IF;

    v_code := next_expense_claim_code(v_last);
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description, created_by)
    VALUES (v_code, p_employee_id, v_last, v_total, p_currency, btrim(p_purpose), auth.uid())
    RETURNING id INTO v_id;
    INSERT INTO expense_claim_items (claim_id, line_no, spend_date, amount_ccy, description, no_receipt_reason, created_by)
    SELECT v_id, x.ord::integer, (x.it->>'spend_date')::date, (x.it->>'amount')::numeric, btrim(x.it->>'description'),
           NULLIF(btrim(COALESCE(x.it->>'no_receipt_reason', '')), ''), auth.uid()
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(it, ord);

    -- ★ U1-B(ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的报销单那一半,与采购单 APR-10 同一个形状):
    --   审批开着时,按这张单会落到的那一级问一句"提单人与主角之外,有没有人批得动";没有 → 按名拒,整张单不落库
    --   (单号随回滚放回去)。主角要传 —— 报销单的四眼也看【报的是谁】(decide_expense_claim 的 forbid_self_approval)。
    --   【分档读同一份】expense_claim_amount_base 是 decide_expense_claim 分档用的那一支;折不出本位币(没有牌价)时
    --   不在这里另造一句拒绝 —— 那张单在决定时会被 fx_rate_for 按名拒(那句话归它),而在牌价补上之前谁都批不了它。
    IF approvals_enabled() THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(v_id) b;
        IF v_base IS NOT NULL THEN
            PERFORM assert_other_decider_for_subject('expense_claim', 'decide_expense_claim_items',
                                                     approval_level_for(v_base), p_employee_id,
                                                     'EXPENSE_CLAIM_NO_OTHER_DECIDER|' || v_code);
        END IF;
    END IF;

    -- CLAIM-RECEIPTS-1(Tim 2026-10-21,Q12):回每一笔的 id —— 表单在提交之后紧接着给每一笔传它的收据(claim_receipt_begin 要那一笔的 id)
    RETURN jsonb_build_object('claim_id', v_id, 'code', v_code, 'status', 'submitted', 'item_count', v_n,
                              'items', (SELECT jsonb_agg(jsonb_build_object('line_no', i.line_no, 'item_id', i.id) ORDER BY i.line_no)
                                          FROM expense_claim_items i WHERE i.claim_id = v_id));
END;
$function$
;
