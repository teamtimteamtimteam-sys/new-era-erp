-- db/functions/pay_medical_claim.sql
-- 把已批准的报销变成一笔【未付】费用(科目 6120),走既有付款流程结清。
-- 只要 module.finance.edit —— HR 那一半的把关由"必须已批准"这个前置状态保证。
--
-- NOTE: updated by db/migrations/2026-08-02-hr2b-leave-exceptions-and-claims.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。

CREATE OR REPLACE FUNCTION public.pay_medical_claim(p_claim_id uuid, p_expense_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric)
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
    v_date  date;
    v_fx    numeric;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DATE_REQUIRED';
    END IF;
    v_date := p_expense_date;

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

    -- ── PAYEE-1a:上面那段"建一个 Staff Reimbursements 往来户"的注释【已退休】──
    -- 它原本写着:"expenses 的 CHECK 要求 unpaid 时 supplier_id 非空(应付账上
    -- 总得有'付给谁')。员工不是供应商,所以实务上建一个往来户,具体是谁写在
    -- payee_name 与备注里。" —— 那段话准确描述了一个【真实存在过的】变通,
    -- 而本刀移除了它的必要性:expenses 现在收得下 employee_id,应付账按人分行。
    -- 【注释与它描述的东西一起退休】—— 一条描述着已不存在的约束的注释,
    -- 与一条断言着不可能发生的隐患的注释是同一个缺陷(AGENTS.md)。
    -- 报销的收款人【就是提交报销的那个员工】,不需要任何人再挑一次。

    -- FIN-0:报销是 SGD,账本也是 SGD —— 不再需要任何汇率。
    -- (旧版在这里取"当天或之前最近"的一条汇率;那正是 C5 要禁掉的写法,随基准换币一并拆除。)
    IF p_fx_rate IS NOT NULL AND p_fx_rate <> 1 THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|SGD';
    END IF;
    v_fx := 1;

    v_exp := record_expense(
        p_expense_date  := v_date,
        p_account_code  := '6120',
        p_amount        := v_claim.amount_sgd,
        p_currency      := 'SGD',
        p_fx_rate       := NULL,
        p_payment_status:= 'unpaid',
        p_bank_account  := NULL,
        p_supplier_id   := NULL,
        p_employee_id   := v_claim.employee_id,
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
