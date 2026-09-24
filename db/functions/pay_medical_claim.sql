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
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ BUGFIX-1b(2026-09-12):GST 开着时,这条路【一笔费用都开不出来】★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它坏成什么样】本刀之前,这里调 record_expense **不传 p_tax_code**,而收款人
-- 写死是员工(PAYEE-1a),`p_supplier_id := NULL`。于是 GST 开着时:
--     record_expense → 供应商默认税码查出 NULL → resolve_tax_code(NULL, NULL, …)
--     → RAISE 'TAX_CODE_REQUIRED|supplier' → 整笔事务回滚 → 费用单没建出来。
-- ★ 而报销人【做什么都修不好】:界面没有税码字段、RPC 没有税码参数、
--   这条路上根本没有供应商可以去设默认值,而 `employees` 表**没有
--   default_tax_code 这一列** —— 员工这一侧永远解析不出默认值。
-- ★ 那句 `|supplier` 指的方向本身就是错的:这条路上没有供应商。
--
-- 【修法:照 decide_expense_claim 的形状】加一个 `p_tax_code`,GST 开着而没给就
-- **按名拒**(有翻译的 `MEDICAL_CLAIM_TAX_CODE_REQUIRED`),再把它传下去。
-- ★ 税码本身的有效性(存在 / 启用 / 侧别 = input)**仍然全归 resolve_tax_code** ——
--   这里不重写一遍税的规矩,只声明一个【这条路特有的前提】:员工没有默认值,
--   所以 override 必填。允许的进项税码那份清单只有一处真源:
--   **`tax_codes` 里 `is_active` 且 `side = 'input'` 的那些**,与报销单
--   (`/finance/claims`)那条路读的是同一处。
--
-- 【为什么这里写 `gst_registered()` 而 decide_expense_claim 写的是一句子查询】
-- ★ 因为**下游那个会拒绝我的人读的就是它** —— `record_expense` 第 4b 段的
--   `IF gst_registered() THEN`。两边用同一个谓词,这里的"先拒"与那边的"要码"
--   就不可能各说各话。(两种写法今天同值;同值不是同一个判据。)
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ 政策:这笔开支的税码【预选 BL】,而预选不等于替人决定 ★★
-- ════════════════════════════════════════════════════════════════════════════
-- ☞ **裁定与它的依据写在 `docs/accounting-policies.md` §9.1b** ——
--   一般规则是新加坡 GST 的 Reg 26(员工医疗开支的进项税被挡住),
--   而 **预选做在【界面】上,不做在这支函数里**:函数**不给默认值**,
--   没给就按名拒。★ 一个在数据库里的默认值,人是看不见、也确认不了的。
-- ⚠ 那条一般规则**还没有被会计确认**(Tim 2026-09-12 说他会去确认)——
--   §9.1b 把这一行写着,免得下一个读到它的人以为它已经被核过。
-- ════════════════════════════════════════════════════════════════════════════

-- CLAIM-GST-1(2026-09-24):医疗申报的 amount_sgd 是【收据上的总额】,已含 GST。
-- 此前它被当成净额、在上面再加 9%(BL 时那 9% 进 6120):报 30 记成欠员工 32.70(MC-2026-0001 →
-- EXP-2026-0008,留作测试数据残留,见 docs/known-wrong-until-cutover.md)。现在调 record_expense 时
-- 传 p_amount_includes_tax := true,税从总额里拆出来,欠员工的恰好是收据上的数。
--
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
        p_tax_code      := v_tax,
        -- CLAIM-GST-1(Tim Q3):员工报上来的是【收据上的总额】,已含 GST —— 税从里面拆出来,不加在上面。
        p_amount_includes_tax := true);

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
