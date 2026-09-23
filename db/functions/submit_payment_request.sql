-- db/functions/submit_payment_request.sql
-- PAY-REQ-1(2026-09-23):提一张【出款】申请。参数与 record_payment 同一组
-- (日期那一格是【计划】付款日;真正的付款日在付款那一步给)。
--
-- 顺序:权限 → 必填 → 这一笔真的需要申请吗 → 收款人没被拉黑/暂停 → 单据没挂在别的
-- 未了结申请上 → 落一行 → 按引擎试跑一遍(不合规矩就在这里按原话拒,而不是等 CFO 批完、
-- 付款时才拒)→ 按审批开关定状态、写留痕。
--
-- 【豁免的那一种不许走申请】payment_request_required 说 false 的出款(Q1:整笔付已批准
-- 的报销 / 医疗申报)按名拒 PAYMENT_REQUEST_NOT_REQUIRED —— 为一笔 Tim 明说不批的钱
-- 去排 CFO 的队,是让他签一个没有理由改的数。页面问的是同一支判据,所以正常走不到这里。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved(Tim 的 Q8,与采购单同形):
-- 那条路上确实没有任何人按过"批准"。路径只有一条:申请 → 付款。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_payment_request(p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_planned_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind     text;
    v_id       uuid := gen_random_uuid();
    v_code     text;
    v_conflict text;
    v_res      jsonb;
    v_on       boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    v_kind := COALESCE(NULLIF(btrim(p_counterparty_kind), ''), 'supplier');
    IF v_kind NOT IN ('supplier', 'employee') THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|out|%', v_kind;
    END IF;
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    IF NOT payment_request_required('out', v_kind, p_counterparty_id, p_amount, p_currency, p_allocations) THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_REQUIRED'
          USING HINT = '整笔付已批准的报销 / 医疗申报,直接记付款,不走申请(PAY-REQ-1 Q1)';
    END IF;

    IF v_kind = 'supplier' THEN
        PERFORM payment_request_payee_check('payment_out', p_counterparty_id);
    END IF;

    v_conflict := payment_request_conflict(p_allocations, NULL);
    IF v_conflict IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_TARGET_RESERVED|%', v_conflict;
    END IF;

    v_code := next_payment_request_code(p_planned_date);
    -- amount_base 先落 0、试跑之后立刻改成引擎算出来的数 —— 试跑按 id 读这一行,
    -- 所以行要先在;同一个事务里,没有任何人看得见那个 0。
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  supplier_id, employee_id, amount_ccy, currency, amount_base,
                                  fx_rate, bank_account_code, planned_date, allocations, notes,
                                  created_by)
    VALUES (v_id, v_code, 'payment_out',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_kind,
            CASE WHEN v_kind = 'supplier' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'employee' THEN p_counterparty_id END,
            p_amount, p_currency, 0, p_fx_rate, NULLIF(btrim(COALESCE(p_bank_account, '')), ''),
            p_planned_date, p_allocations, NULLIF(btrim(COALESCE(p_notes, '')), ''),
            auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
                              'amount_base', (v_res->>'amount_base')::numeric);
END;
$function$
;
