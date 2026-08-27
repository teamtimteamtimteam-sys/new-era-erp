CREATE OR REPLACE FUNCTION public.decide_expense_claim(p_claim_id uuid, p_approve boolean, p_account_code text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        expense_claims%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_actors   uuid[];
    v_has_att  boolean;
    v_exp      jsonb;
    v_date     date;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_c.employee_id;

    -- ══ ★【职责分离:提报的人不能批自己那一笔】★ ══════════════════════════
    -- 【为什么这道闸必须新装在这里】SOD-1 的 guard_payment_sod 明确豁免了
    -- 付给员工的款,理由是"由 HR 建档、财务付款,已经跨了两个模块的门"。
    -- 那句话在写下的那天是对的 —— 而本刀开出了一条新路:**员工自己发起**。
    -- 发起人现在就是受益人,那个论证对新路不成立。
    -- 「换了推导来源,闸就要跟着搬」(AGENTS.md;GST-2 撞过两次)。
    -- 【第一步的主语有两个】受益人(员工自己的 user_id)与提报人(created_by):
    -- 代人录入时两者不同,而两者都不该是批准的那个人。
    v_actors := ARRAY(
        SELECT x FROM unnest(ARRAY[v_emp.user_id, v_c.created_by]) x WHERE x IS NOT NULL);
    PERFORM assert_segregated('EXPENSE_CLAIM_SELF_APPROVAL', v_actors, v_c.code);

    -- ══ 驳回 ══════════════════════════════════════════════════════════════
    IF NOT p_approve THEN
        -- 【按名拒,而不是让 CHECK 抛约束原文】fixture 90 立的那条
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_REJECT_REASON_REQUIRED|%', v_c.code;
        END IF;
        UPDATE expense_claims
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_claim_id;
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'rejected');
    END IF;

    -- ══ 批准 ══════════════════════════════════════════════════════════════
    IF p_account_code IS NULL OR btrim(p_account_code) = '' THEN
        -- 会计口径由审批人给 —— 没有科目就没法记账,而猜一个科目比拒绝坏
        RAISE EXCEPTION 'EXPENSE_CLAIM_ACCOUNT_REQUIRED|%', v_c.code;
    END IF;

    -- ★【GST 开着时,税码是【必给】的 —— 而且只能由审批人给】★
    -- 实测:resolve_tax_code 接受 override 或【往来对象的默认税码】,两者皆空就
    -- 按名拒(TAX_CODE_REQUIRED)。而 employees **没有 default_tax_code 这一列** ——
    -- 员工这一侧【永远】解析不出默认值。所以报销这条路上,税码只能显式给。
    -- 【为什么在这里先拒一次,而不是让 resolve_tax_code 去拒】它的提示语是
    -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工来说
    -- 前半句是【做不到的事】,于是那句话有一半是错的指路。这里按名拒并说清楚
    -- 要做的判断:进项税可抵是 TX,不可抵是 BL,而那是一个财务判断。
    -- 【这不是把税的规矩重写一遍】有效性、侧别、是否停用仍然全归 resolve_tax_code;
    -- 这里只声明一个【这条路特有的前提】:员工没有默认值,所以 override 必填。
    IF (SELECT gst_registered FROM finance_settings) AND
       COALESCE(btrim(COALESCE(p_tax_code, '')), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_TAX_CODE_REQUIRED|%', v_c.code;
    END IF;

    -- ★【凭据:要么有附件,要么有一句说得出为什么没有】★
    -- 【为什么查在这一步而不是提交那一步】提交那一刻申请还不存在,附件挂不上去;
    -- 而凭据真正起作用的时刻,正是有人要据它做决定的时刻。
    -- 【为什么留了一条例外的路】一条没有例外出口的规矩会被绕过 ——
    -- 这里绕过的走法是"让财务当成一笔普通费用直接录进去",而那会把整条
    -- 报销记录一起丢掉。所以:允许没有收据,但要求把【为什么】说出来,
    -- 并且让审批人看见自己批的是哪一种。
    SELECT EXISTS (SELECT 1 FROM finance_attachments
                    WHERE claim_id = p_claim_id AND deleted_at IS NULL) INTO v_has_att;
    IF NOT v_has_att AND COALESCE(btrim(v_c.no_receipt_reason), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NO_EVIDENCE|%', v_c.code;
    END IF;

    -- 入账日:默认花钱那天;期间关了账时由审批人显式给
    v_date := COALESCE(p_posting_date, v_c.spend_date);

    -- 【成本与欠款在这里同时落地】unpaid = 一笔挂在这名员工头上的应付,
    -- 它会立刻出现在 ap_open_items 里带着他自己的名字(PAYEE-1a)。
    -- 汇率传 NULL:由 record_expense 按【那一天】自己查牌价 —— 一条 FX 规矩,
    -- 查不到就按名拒(FX_RATE_MISSING),报销不是它的例外。
    v_exp := record_expense(
        p_expense_date   := v_date,
        p_account_code   := btrim(p_account_code),
        p_amount         := v_c.amount_ccy,
        p_currency       := v_c.currency,
        p_fx_rate        := NULL,
        p_payment_status := 'unpaid',
        p_bank_account   := NULL,
        p_supplier_id    := NULL,
        p_employee_id    := v_c.employee_id,
        p_payee_name     := v_emp.legal_name,
        p_notes          := format('Expense claim %s (%s) — %s', v_c.code, v_emp.code, v_c.description),
        p_tax_code       := NULLIF(btrim(COALESCE(p_tax_code, '')), ''));

    UPDATE expense_claims
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           account_code = btrim(p_account_code),
           tax_code = NULLIF(btrim(COALESCE(p_tax_code, '')), ''),
           posting_date = v_date,
           expense_id = (v_exp->>'expense_id')::uuid
     WHERE id = p_claim_id;

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'approved',
                              'expense_id', v_exp->>'expense_id', 'posting_date', v_date);
END;
$function$

;
