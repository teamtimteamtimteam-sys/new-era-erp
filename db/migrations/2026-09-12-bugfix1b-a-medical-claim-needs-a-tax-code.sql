-- BUGFIX-1b:GST 开着时,一笔医疗报销【开不出费用单】—— 而报销人做什么都修不好
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它坏成什么样(round 1 在重建库上真的跑出来过,两臂)】
--   GST OFF : succeeded=t  -> expense EXP-2026-0001
--   GST ON  : succeeded=f  -> TAX_CODE_REQUIRED|supplier      ← 整笔事务回滚
--
-- 链:
--   app/hr/claims/[id]/ClaimControls.tsx  payClaim(claimId, date)
--   app/hr/claims/actions.ts              rpc('pay_medical_claim', {…})
--   db/functions/pay_medical_claim.sql    record_expense(…, p_supplier_id := NULL,
--                                                        【没有 p_tax_code】)
--   db/functions/record_expense.sql  §4b  IF gst_registered() THEN
--                                         suppliers WHERE id = NULL  → NULL
--                                         resolve_tax_code(NULL, NULL, 'input', 'supplier')
--   db/functions/resolve_tax_code.sql     RAISE 'TAX_CODE_REQUIRED|%'
--
-- ★ 用户不能自救,四条都查过:界面没有税码字段 · RPC 没有税码参数 ·
--   这条路上没有供应商可以去设默认值 · `employees` **没有 default_tax_code 这一列**。
-- ★ 而那句 `|supplier` 指的方向本身是错的 —— 这条路上根本没有供应商(PAYEE-1a
--   把收款人定成员工本人,`p_supplier_id` 写死 NULL)。
--
-- ★★ 最值钱的一句:`decide_expense_claim.sql` 的注释**早就整段写出了这个缺陷**
--    (「employees 没有 default_tax_code —— 员工这一侧永远解析不出默认值」)。
--    ☞ **那条裁定做到了 expense_claims 上,没有做到 medical_claims 上。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这支迁移改什么】
--   `pay_medical_claim` 加一个 **带默认值的** `p_tax_code text DEFAULT NULL`;
--   GST 开着而没给就按名拒 `MEDICAL_CLAIM_TAX_CODE_REQUIRED|<报销单号>`(有翻译);
--   给了就传给 `record_expense`。
--
-- ★ `record_expense` 与 `resolve_tax_code` **一个字都没有改** —— 读过了,不必改:
--   `record_expense` 早就收 `p_tax_code`(GST-2 起),而税码的有效性
--   (存在 / 启用 / 侧别 = input)全归 `resolve_tax_code`。
--   ☞ 允许的进项税码只有一处真源:**`tax_codes` 里 `is_active` 且 `side='input'`**,
--     与报销单(`/finance/claims`)那条路读的是同一处。这里不重写税的规矩,
--     只声明一个这条路特有的前提:员工没有默认值,所以 override 必填。
--
-- ★ `decide_expense_claim` **不动**(Tim 2026-09-12 的裁定):
--   报销单那条路要一次明确的选择,**不预选**。两条路给不同的答案是一次裁定,
--   不是一次疏忽 —— 理由写在 `docs/accounting-policies.md` §9.1b。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是 DROP + CREATE,而不是 CREATE OR REPLACE】
--   加参数 = 换签名 = **重载**,旧签名会原样活在线上变成镜像看不见的漂移(FIN-21)。
--   `db/preflight_migration.py` 为此**拒绝**这种形状,而 DROP + CREATE 是它唯一
--   放行的走法(PAYEE-1a 在同一支函数上付过同一笔账,见
--   `db/migrations/2026-08-18-payee1a-an-employee-can-be-paid-directly.sql:977`)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【破窗里会发生什么 —— 照直说】★★
--   窗口 = 这支迁移提交 → 新代码部署成功。期间线上跑的是 **旧代码 + 新函数**。
--   旧代码那句 `rpc('pay_medical_claim', {p_claim_id, p_expense_date})` 是**按名传参**,
--   而新增的两个参数都有默认值 → ★ **它仍然解析得到新函数**,走 `p_tax_code = NULL`。
--   于是 GST 开着时它 **仍然被按名拒、仍然开不出费用单、事务仍然回滚** ——
--   ☞ **结果与今天【逐字相同】:一笔都开不出来。**
--   ⚠ **有一处不同,不抹平**:拒绝的**码**从 `TAX_CODE_REQUIRED|supplier`
--     变成 `MEDICAL_CLAIM_TAX_CODE_REQUIRED|MC-…`。旧代码的 `localizeLeaveError`
--     两个码都不认识,所以**屏幕上两者都是一串生码** —— 窗口里可见行为不变。
--   ★ 窗口是良性且可枚举的,而这【不构成】"先推送后跑门"的理由(AGENTS.md,UI-1b 付过账)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION public.pay_medical_claim(uuid, date, numeric);

CREATE OR REPLACE FUNCTION public.pay_medical_claim(p_claim_id uuid, p_expense_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric, p_tax_code text DEFAULT NULL::text)
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
    v_tax   text;
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

    -- ★★ BUGFIX-1b:【GST 开着时税码必给,而且只能由人显式给】★★
    -- 【为什么在这里先拒,而不是让 resolve_tax_code 去拒】它的 HINT 写着
    -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工报销来说
    -- **前半句是做不到的事**(employees 没有 default_tax_code),而这条路上
    -- 连一个往来对象都没有。于是那句指路有一半是错的,而且它的码 `|supplier`
    -- 指的方向也是错的。这里按名拒,并且拿【这张报销单的单号】做参数,
    -- 让界面能说出"哪一张"。与 decide_expense_claim 的 EXPENSE_CLAIM_TAX_CODE_REQUIRED
    -- 逐字同一个形状。
    -- ★ GST 关着时【什么都不做】:record_expense 在未注册时对一个非空税码是
    --   **按名拒**(GST_NOT_REGISTERED),所以这里既不要求也不伪造。
    v_tax := NULLIF(btrim(COALESCE(p_tax_code, '')), '');
    IF gst_registered() AND v_tax IS NULL THEN
        RAISE EXCEPTION 'MEDICAL_CLAIM_TAX_CODE_REQUIRED|%', v_claim.code;
    END IF;

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
        p_notes         := format('Medical claim %s (%s)', v_claim.code, v_emp.code),
        p_tax_code      := v_tax);

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
        'tax_code', v_tax,
        'payment_status', 'unpaid',
        'claim_status', 'approved',
        'note', 'An unpaid expense has been raised. The claim becomes settled when that expense is paid through the payment flow; it is not marked paid on creation.');
END;
$function$;

COMMENT ON FUNCTION public.pay_medical_claim(uuid, date, numeric, text) IS
'把已批准的医疗报销变成一笔未付费用(6120)。GST 开着时 p_tax_code 必给 —— 员工没有默认税码,所以只能由人显式选。★ 走哪个税码是一条【政策】,写在 docs/accounting-policies.md §9.1b(一般规则:新加坡 GST Reg 26 把员工医疗开支的进项税挡住,即 BL;界面预选 BL 但仍要人确认;截至 2026-09-12 该规则尚未经会计确认)。允许的进项税码只有一处真源:tax_codes 里 is_active 且 side=''input'' 的那些,与 decide_expense_claim 那条路同源。';

COMMIT;
