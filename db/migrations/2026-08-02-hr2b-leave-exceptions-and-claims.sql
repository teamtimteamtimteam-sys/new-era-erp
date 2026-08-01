-- db/migrations/2026-08-02-hr2b-leave-exceptions-and-claims.sql
-- HR cut 2b:例外路径(决定 2 与 3)+ 报销转费用(决定 1)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一个机制服务两个决定】
--   决定 2:恩恤假/婚假/考试假保留标准天数,但要有【逐案审批】的口子;
--   决定 3:请假天数继续按周一至周五算,但六天工作制与轮班要有【同一个口子】。
--   两者要的是同一件事 —— "这一次不按标准算,理由如下"。所以不做两套机制,
--   做一个 is_exception + exception_reason。
--
-- 【例外能越过什么,不能越过什么 —— 这是本切最微妙的一处】
--   能越过:calculate_leave_days 的周一至周五口径(六天制/轮班),
--           以及 leave_types.default_days_per_year 这条【政策】上限(逐案批准的本意)。
--   不能越过:累积型假别(年假)的【余额检查】。
--   区别在于:default_days_per_year 是一条【公司政策】,政策可以逐案变通;
--   而年假余额是【真实的权利存量】—— 它由授予与消耗的账算出来,
--   批一天不存在的年假,不是"变通",是让账不平。例外让政策弯,不让账弯。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ============================================================================
-- B1. 例外路径
-- ============================================================================
ALTER TABLE public.leave_requests
    ADD COLUMN is_exception boolean NOT NULL DEFAULT false,
    ADD COLUMN exception_reason text;

COMMENT ON COLUMN public.leave_requests.is_exception IS
    'True when days were entered by hand rather than computed from calculate_leave_days. '
    'Two cases: (a) a six-day or shift schedule where Mon-Fri counting is wrong, '
    '(b) case-by-case leave (compassionate, marriage) varying the standard entitlement.';

-- 例外必须写理由 —— 一个没有理由的例外,三个月后没人知道当时为什么这么批
ALTER TABLE public.leave_requests
    ADD CONSTRAINT leave_requests_exception_reason
    CHECK (NOT is_exception OR (exception_reason IS NOT NULL AND btrim(exception_reason) <> ''));

-- 【必须先 DROP 旧签名】。CREATE OR REPLACE 只在【参数列表完全相同】时才是替换;
-- 多了三个带默认值的参数就成了【重载】,于是 submit_leave_request(uuid,text,date,date)
-- 这样的调用会因为两个候选都匹配而报 "function is not unique" —— 应用会在运行时炸。
DROP FUNCTION IF EXISTS public.submit_leave_request(uuid, text, date, date, boolean, boolean, text, text);

CREATE OR REPLACE FUNCTION public.submit_leave_request(
    p_employee_id uuid,
    p_leave_type_code text,
    p_start date,
    p_end date,
    p_start_half boolean DEFAULT false,
    p_end_half boolean DEFAULT false,
    p_reason text DEFAULT NULL,
    p_certificate_ref text DEFAULT NULL,
    p_is_exception boolean DEFAULT false,
    p_exception_days numeric DEFAULT NULL,
    p_exception_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_type   record;
    v_days   numeric;
    v_taken  numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_code   text;
    v_req    record;
    v_clash  text;
BEGIN
    -- 本人或 HR。自助提交由员工自己发起时,p_employee_id 就是他自己的档案。
    IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    -- 【例外是 HR 的口子,不是员工自助的口子】
    IF p_is_exception AND NOT has_permission('module.hr.edit') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    SELECT id, code, employment_status INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'LEAVE_TYPE_NOT_FOUND|%', p_leave_type_code; END IF;
    IF NOT v_type.is_active THEN RAISE EXCEPTION 'LEAVE_TYPE_INACTIVE|%', p_leave_type_code; END IF;

    IF v_type.is_accrued AND v_emp.employment_status = 'probation' THEN
        RAISE EXCEPTION 'PROBATION_NO_ANNUAL_LEAVE';
    END IF;

    -- ── 天数:例外用手填的,常规用算的 ──────────────────────────────────────
    IF p_is_exception THEN
        IF p_exception_reason IS NULL OR btrim(p_exception_reason) = '' THEN
            RAISE EXCEPTION 'EXCEPTION_REASON_REQUIRED';
        END IF;
        IF p_exception_days IS NULL OR p_exception_days <= 0 THEN
            RAISE EXCEPTION 'EXCEPTION_DAYS_INVALID';
        END IF;
        v_days := p_exception_days;
    ELSE
        v_days := calculate_leave_days(p_start, p_end, p_start_half, p_end_half);
        IF v_days <= 0 THEN RAISE EXCEPTION 'NO_WORKING_DAYS|%|%', p_start, p_end; END IF;
    END IF;

    SELECT code INTO v_clash FROM leave_requests
    WHERE employee_id = p_employee_id AND deleted_at IS NULL
      AND status IN ('pending','approved')
      AND daterange(start_date, end_date, '[]') && daterange(p_start, p_end, '[]')
    LIMIT 1;
    IF v_clash IS NOT NULL THEN RAISE EXCEPTION 'OVERLAPPING_REQUEST|%', v_clash; END IF;

    -- 医生证明门槛照旧适用(例外也不例外 —— 那是医疗证据,不是政策口径)
    IF v_type.requires_certificate_after_days IS NOT NULL
       AND (p_certificate_ref IS NULL OR btrim(p_certificate_ref) = '') THEN
        SELECT COALESCE(SUM(r.days), 0) INTO v_taken
        FROM leave_requests r
        WHERE r.employee_id = p_employee_id AND r.leave_type_code = p_leave_type_code
          AND r.deleted_at IS NULL AND r.status IN ('pending','approved')
          AND EXTRACT(YEAR FROM r.start_date) = EXTRACT(YEAR FROM p_start);
        IF v_taken + v_days > v_type.requires_certificate_after_days THEN
            RAISE EXCEPTION 'CERTIFICATE_REQUIRED|%|%', v_taken, v_type.requires_certificate_after_days;
        END IF;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 【余额检查:例外【不能】越过】。
    -- default_days_per_year 是政策,逐案可以变通;年假余额是账上的存量,不能变通。
    -- 批一天不存在的年假不是"通融",是让账不平 —— 而这笔账最后要变成离职补偿的钱。
    -- ══════════════════════════════════════════════════════════════════════
    IF v_type.is_accrued THEN
        v_bal := leave_balance(p_employee_id, p_leave_type_code, p_start);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_days THEN
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%', v_avail, v_days;
        END IF;
    END IF;
    -- 非累积型(恩恤/婚假/考试等):default_days_per_year 只是【标准】,
    -- 例外路径正是为了超过它而存在的,所以这里不设上限。

    v_code := next_leave_request_code(p_start);
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date,
                                start_half_day, end_half_day, days, reason, certificate_ref,
                                is_exception, exception_reason)
    VALUES (v_code, p_employee_id, p_leave_type_code, p_start, p_end,
            p_start_half, p_end_half, v_days, p_reason, p_certificate_ref,
            p_is_exception, CASE WHEN p_is_exception THEN p_exception_reason ELSE NULL END)
    RETURNING * INTO v_req;

    RETURN jsonb_build_object('request_id', v_req.id, 'code', v_req.code,
                              'employee_code', v_emp.code, 'leave_type_code', p_leave_type_code,
                              'days', v_days, 'status', v_req.status,
                              'is_exception', v_req.is_exception);
END;
$function$;

-- ============================================================================
-- B3. 员工福利与医疗科目
-- ============================================================================
-- 【为什么单开一个科目,而不是塞进 6900 杂项】
--   杂项是"没有归属的零星支出"。医疗报销既不零星也不无归属:它有年度额度、
--   有政策、Tim 会想知道一年花了多少 —— 埋进杂项里就再也看不出来了。
-- 【为什么不并进 6100 工资薪金】
--   工资薪金是【报酬】,是公积金与人力成本分析的基数。报销是【福利支出】,
--   不是报酬也不计公积金。混进去会让工资这条线虚高,进而让所有按工资算的比率失真。
-- 放在 6110 之后,与雇佣相关的成本挨在一起,但明确不是报酬。
INSERT INTO accounts (code, name_en, name_zh, account_type, is_active, notes) VALUES
    ('6120', 'Staff Welfare & Medical', '员工福利与医疗', 'expense', true,
     'Medical claim reimbursements and other staff welfare. Separate from 6100 Salaries & Wages '
     'because it is a benefit, not remuneration, and must not inflate the wage base used for CPF '
     'and headcount ratios; separate from 6900 Miscellaneous because it is a budgeted, recurring '
     'category that Tim will want to see on its own line.');

-- ============================================================================
-- B2. pay_medical_claim —— 批准的报销 → 一笔【未付】费用,走既有付款流程
-- ============================================================================
-- 【权限:只要 module.finance.edit,不要求同时持有 module.hr.edit】。
--   这是对原设计的一处【有意偏离】,理由是量出来的:
--     同时要求两者 → 只有 admin 与 gm 能调用(finance 没有 hr.edit,hr 没有 finance.edit);
--     也就是说【财务本人反而做不了这一步】,与"实际上由财务来做"的预期正好相反。
--   真正的职责分离已经由【两步、两个人】实现:
--     第一步 decide_medical_claim 要 module.hr.edit —— HR 审核这笔报销是否属实、是否在额度内;
--     第二步 pay_medical_claim   要 module.finance.edit —— 财务把它变成一笔应付。
--   把两个码压在同一次调用上,并不会更安全,只会把一笔三百块的报销升级成
--   必须由管理员或总经理亲自操作。所以这里检查 finance.edit,并【要求报销已被批准】,
--   HR 那一半的把关由那个前置状态来保证。
CREATE OR REPLACE FUNCTION public.pay_medical_claim(
    p_claim_id uuid,
    p_expense_date date DEFAULT NULL,
    p_supplier_id uuid DEFAULT NULL,
    p_fx_rate numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_claim record;
    v_emp   record;
    v_exp   jsonb;
    v_code  text;
    v_date  date := COALESCE(p_expense_date, CURRENT_DATE);
    v_fx    numeric;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;

    -- HR 那一半的把关:必须已经被批准过
    IF v_claim.status <> 'approved' THEN
        RAISE EXCEPTION 'CLAIM_NOT_APPROVED|%', v_claim.status;
    END IF;

    IF v_claim.expense_id IS NOT NULL THEN
        SELECT code INTO v_code FROM expenses WHERE id = v_claim.expense_id;
        RAISE EXCEPTION 'CLAIM_ALREADY_PAID|%', COALESCE(v_code, v_claim.expense_id::text);
    END IF;

    SELECT id, code, legal_name INTO v_emp FROM employees WHERE id = v_claim.employee_id;

    -- 【未付费用必须有一个往来对象】:expenses 的 CHECK 要求 unpaid 时 supplier_id 非空
    -- (应付账上总得有"付给谁")。员工不是供应商,所以实务上建一个
    -- "员工报销 / Staff Reimbursements" 的往来户,具体是谁写在 payee_name 与备注里。
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;

    -- 报销是 SGD,账本是 USD,所以要一个汇率。没给就取【费用日期当天或之前最近】的一条;
    -- 一条都没有就明说缺什么,而不是随便凑一个数把账做平。
    v_fx := p_fx_rate;
    IF v_fx IS NULL THEN
        SELECT rate_to_usd INTO v_fx FROM fx_rates
        WHERE currency = 'SGD' AND rate_date <= v_date AND deleted_at IS NULL
        ORDER BY rate_date DESC LIMIT 1;
    END IF;
    IF v_fx IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|SGD|%', v_date;
    END IF;

    v_exp := record_expense(
        p_expense_date  := v_date,
        p_account_code  := '6120',
        p_amount        := v_claim.amount_sgd,
        p_currency      := 'SGD',
        p_fx_rate       := v_fx,
        p_payment_status:= 'unpaid',
        p_bank_account  := NULL,
        p_supplier_id   := p_supplier_id,
        p_payee_name    := v_emp.legal_name,
        p_notes         := format('Medical claim %s (%s)', v_claim.code, v_emp.code));

    -- 【状态仍然是 approved,不是 paid】。
    -- 这笔费用刚建出来是 unpaid —— 员工手里一分钱还没拿到。此刻把报销标成
    -- "paid" 是在说一件没发生的事。真正的结清由付款流程完成,
    -- medical_claim_status 视图从 expenses.payment_status 推导出真实状态。
    UPDATE medical_claims
    SET expense_id = (v_exp->>'expense_id')::uuid, updated_by = auth.uid()
    WHERE id = p_claim_id;

    RETURN jsonb_build_object(
        'claim_id', p_claim_id, 'claim_code', v_claim.code,
        'expense_id', v_exp->>'expense_id', 'expense_code', v_exp->>'code',
        'account_code', '6120', 'amount_sgd', v_claim.amount_sgd, 'fx_rate', v_fx,
        'payment_status', 'unpaid',
        'claim_status', 'approved',
        'note', 'An unpaid expense has been raised. The claim becomes settled when that expense is paid through the payment flow; it is not marked paid on creation.');
END;
$function$;

-- medical_claim_status:把"是否真的付掉了"从费用那边推导出来,而不是靠一个可能撒谎的状态列
CREATE OR REPLACE VIEW public.medical_claim_status WITH (security_invoker = off) AS
SELECT
    mc.id AS claim_id, mc.code, mc.employee_id, e.code AS employee_code, e.legal_name,
    mc.claim_date, mc.claim_year, mc.amount_sgd, mc.description, mc.receipt_ref,
    mc.status, mc.decided_at, mc.expense_id,
    (mc.expense_id IS NOT NULL) AS linked_to_expense,
    ex.code AS expense_code,
    ex.amount_usd AS expense_amount_usd,
    COALESCE(pay.settled_usd, 0) AS settled_usd,
    -- 【结算状态是算出来的】:报销单自己的 status 只说到"批准",钱到没到手要看付款。
    -- 【看的是已过账的付款分配,不是 expenses.payment_status】—— 后者对"建单时未付、
    -- 之后经付款流程结清"的费用【不会翻转】(它的 CHECK 要求 paid 必须带银行科目)。
    -- 这与 ap_open_items 判断未结金额用的是同一个信号,免得两处对"付没付"给出不同答案。
    CASE WHEN mc.status <> 'approved' THEN mc.status
         WHEN mc.expense_id IS NULL THEN 'awaiting_payment_run'
         WHEN COALESCE(pay.settled_usd, 0) >= ex.amount_usd THEN 'paid'
         WHEN COALESCE(pay.settled_usd, 0) > 0 THEN 'part_paid'
         ELSE 'expense_raised' END AS settlement_state
FROM medical_claims mc
JOIN employees e ON e.id = mc.employee_id
LEFT JOIN expenses ex ON ex.id = mc.expense_id
LEFT JOIN LATERAL (
    SELECT SUM(pa.allocated_usd) AS settled_usd
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.expense_id = ex.id
) pay ON true
WHERE mc.deleted_at IS NULL
  AND (has_permission('module.hr.view') OR mc.employee_id = current_user_employee());

NOTIFY pgrst, 'reload schema';

COMMIT;
