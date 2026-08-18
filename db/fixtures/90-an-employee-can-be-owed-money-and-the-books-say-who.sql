-- 90 一个员工可以被欠钱,而账上说得出【是谁】
--
-- 【它守的是什么】PAYEE-1a 之前,两条 CHECK 逼着每一笔未付费用与每一笔出款
-- 都挂一个供应商。于是员工报销只能借一个假供应商("Staff Reimbursements"),
-- 真正的收款人退化成 payee_name 那个自由文本 —— 应付账上所有人的欠款汇成一行,
-- 分不出是谁、也点不开。本刀把往来对象从【假设】变成【选择】。
--
-- 【三件事必须同时成立,而它们各自会以不同方式坏掉】
--   ① 二选一是【恰好一个】:两个都填是矛盾,一个都不填是说不出欠谁 ——
--      两种都要【按名】拒绝,而不是让 CHECK 抛一句约束原文;
--   ② 员工的应付【必须在 ap_open_items 里、并且带着自己的名字】。
--      本刀之前那里是 INNER JOIN suppliers:supplier_id 为空的费用【整行消失】。
--      **消失比空白更坏** —— 空白至少还看得见有这么一笔;
--   ③ 报销全程【不需要任何供应商】:submit → decide → pay 一路走完。
--
-- 【为什么"缺席"这一臂必须存在,而且要与"在场"配对】
-- 把 ap_open_items 的费用支整个删掉,员工那一行也会"不带错名字" ——
-- 所以每一条"员工行在场且名字对"的断言旁边,都要有一条"供应商行仍然在场",
-- 否则一个把整支关掉的实现也能全绿(GRN-2 的 G/H、SUP-TYPE-1a 的 A/B 同一条)。
--
-- 【本 fixture 以 postgres 跑】ap_open_items 是属主权限视图,门是体内的
-- has_permission();employees 的 RLS 因此不参与 —— 而那正是本刀要的:
-- 财务读者不必持 HR 权限也看得见"这笔钱欠谁"(AGENTS.md 第三条既有决定)。
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();
    r_all uuid;
    emp_a uuid; emp_b uuid; sup uuid;
    v_exp jsonb; v_pay jsonb; v_claim jsonb;
    exp_emp uuid; exp_sup uuid; claim_id uuid;
    v_msg text; v_denied boolean; n int; v_name text; v_kind text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-90', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_all, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);

    -- 【前提显式设定】期间锁必须让开,否则这些用例会因为一个与被测规则无关的
    -- 理由红掉(README 第 4/5 条:locked_before 是随月结移动的运行时状态)。
    UPDATE finance_settings SET locked_before = NULL;
    -- 【system_start_date 也要自己设,不许向线上借】HR-6 把医疗报销的额度
    -- 按"这个库从哪天起有完整记录"截断;重建库里它是 NULL,于是 submit
    -- 直接抛 SYSTEM_START_NOT_SET —— 对着线上跑一切正常,gate 在重建库上报红。
    -- 这与 fixture 88 借 window_days 是同一个错的第二次(README 第 2/5 条)。
    UPDATE finance_settings SET system_start_date = CURRENT_DATE - 800;

    -- employees 的必填列:employment_type / work_category / hire_date
    -- (employment_status 有默认值 'probation';residency_status 不设成 work_pass
    --  就不触发 employees_work_pass_shape)。department_id 可空 —— 不借引导数据。
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status)
    VALUES ('FX90-E1', 'fixture 90 employee one', 'full_time', 'office', CURRENT_DATE - 400, 'active')
    RETURNING id INTO emp_a;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status)
    VALUES ('FX90-E2', 'fixture 90 employee two', 'full_time', 'office', CURRENT_DATE - 400, 'active')
    RETURNING id INTO emp_b;
    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('FX90-SUP', 'fixture 90 supplier', 'SG') RETURNING id INTO sup;

    -- ══════════════════════════════════════════════════════════════════════════
    -- A. 挂员工、不挂供应商的未付费用【被接受】—— 这一刀的全部要点
    -- ══════════════════════════════════════════════════════════════════════════
    v_exp := record_expense(
        p_expense_date := CURRENT_DATE, p_account_code := '6120',
        p_amount := 500, p_currency := 'SGD', p_payment_status := 'unpaid',
        p_employee_id := emp_a, p_payee_name := 'fixture 90 employee one');
    exp_emp := (v_exp->>'expense_id')::uuid;
    IF exp_emp IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 90A 挂员工的未付费用必须建得出来';
    END IF;
    SELECT count(*) INTO n FROM expenses
     WHERE id = exp_emp AND employee_id = emp_a AND supplier_id IS NULL;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 90A 落库应当是 employee_id 有值、supplier_id 为空,实得 % 行', n;
    END IF;
    RAISE NOTICE '90A 挂员工、无供应商的未付费用:接受 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- B. 【两个都给】按名拒绝 —— 悄悄挑一个会让另一个人的账凭空消失
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(
            p_expense_date := CURRENT_DATE, p_account_code := '6120',
            p_amount := 100, p_currency := 'SGD', p_payment_status := 'unpaid',
            p_supplier_id := sup, p_employee_id := emp_a);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('COUNTERPARTY_AMBIGUOUS' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 90B 供应商与员工都填必须【按名】拒(COUNTERPARTY_AMBIGUOUS),实得:%',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;
    RAISE NOTICE '90B 两个都给:按名拒 —— % ✓', v_msg;

    -- ══════════════════════════════════════════════════════════════════════════
    -- C. 【一个都不给】按名拒绝 —— 而且不许漏成约束原文
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(
            p_expense_date := CURRENT_DATE, p_account_code := '6120',
            p_amount := 100, p_currency := 'SGD', p_payment_status := 'unpaid');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('COUNTERPARTY_REQUIRED_FOR_UNPAID' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 90C 两个都不给必须【按名】拒(COUNTERPARTY_REQUIRED_FOR_UNPAID),实得:%',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;
    -- 【不许是约束原文】漏到 CHECK 那一层,屏幕上会出现 expenses_counterparty_shape
    IF position('expenses_counterparty_shape' in v_msg) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 90C 拒绝漏到了 CHECK 那一层(约束原文进了错误信息):%', v_msg;
    END IF;
    RAISE NOTICE '90C 一个都不给:按名拒,且没漏成约束原文 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- D. 员工的应付【在 AP 账龄里、是自己一行、带着自己的名字】
    --    本刀之前这里是 INNER JOIN suppliers —— 整行消失,不是空白。
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO n FROM ap_open_items WHERE doc_id = exp_emp;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 90D 员工应付必须【出现】在 ap_open_items 里(此前 INNER JOIN suppliers 会让它整行消失),实得 % 行', n;
    END IF;
    SELECT counterparty_kind, counterparty_name INTO v_kind, v_name
      FROM ap_open_items WHERE doc_id = exp_emp;
    IF v_kind <> 'employee' THEN
        RAISE EXCEPTION 'FIXTURE 90D counterparty_kind 应为 employee,实得 %', v_kind;
    END IF;
    IF v_name IS DISTINCT FROM 'fixture 90 employee one' THEN
        RAISE EXCEPTION 'FIXTURE 90D 这一行必须【带着员工自己的名字】(不是空白、不是"Staff Reimbursements"),实得 %', COALESCE(v_name,'(NULL)');
    END IF;
    -- 【supplier_name 诚实地为空】不把员工姓名塞进供应商那一列 —— 那正是本系列在拆的混同
    SELECT supplier_name INTO v_name FROM ap_open_items WHERE doc_id = exp_emp;
    IF v_name IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 90D supplier_name 对员工行必须是 NULL(没有供应商就说没有),实得 %', v_name;
    END IF;
    RAISE NOTICE '90D 员工应付在账龄里、是自己一行、带自己的名字,而 supplier_name 诚实为空 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- E. 【配对臂】供应商的应付仍然在场且名字对 ——
    --    少了它,把整支关掉的实现也能让 D 变绿
    -- ══════════════════════════════════════════════════════════════════════════
    v_exp := record_expense(
        p_expense_date := CURRENT_DATE, p_account_code := '6120',
        p_amount := 700, p_currency := 'SGD', p_payment_status := 'unpaid',
        p_supplier_id := sup);
    exp_sup := (v_exp->>'expense_id')::uuid;
    SELECT counterparty_kind, counterparty_name INTO v_kind, v_name
      FROM ap_open_items WHERE doc_id = exp_sup;
    IF v_kind <> 'supplier' OR v_name IS DISTINCT FROM 'fixture 90 supplier' THEN
        RAISE EXCEPTION 'FIXTURE 90E 供应商应付必须【仍然】在场且名字对(与 D 配对,才分得出"支持员工"与"把整支关掉"),实得 kind=% name=%', v_kind, COALESCE(v_name,'(NULL)');
    END IF;
    RAISE NOTICE '90E 供应商应付仍在场且名字对(与 D 配对)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- F. 出款【付给员工】被接受,并且核销到他自己那张单上
    -- ══════════════════════════════════════════════════════════════════════════
    -- 【失败要按名说出来】不裹这一层,任何缺陷都会以 record_payment 自己的
    -- 原始错误逃出去(实测:party_id 只认 supplier_id 时逃出的是
    -- ALLOC_WRONG_PARTY)—— 那样红是红了,却没说是这一臂,
    -- 而"一条报了红却说不出是哪一条断言"的检查,与不报是两回事但同样难用。
    v_denied := false; v_msg := NULL;
    BEGIN
        v_pay := record_payment(
            p_direction := 'out', p_counterparty_id := emp_a, p_amount := 500,
            p_currency := 'SGD', p_bank_account := '1000', p_payment_date := CURRENT_DATE,
            p_counterparty_kind := 'employee',
            p_allocations := jsonb_build_array(
                jsonb_build_object('expense_id', exp_emp, 'amount_doc', 500)));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 90F 付给员工的出款必须成功(核销到他自己那张单上),实得拒绝:%', v_msg;
    END IF;
    IF (v_pay->>'payment_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 90F 付给员工的出款必须建得出来';
    END IF;
    SELECT count(*) INTO n FROM payments
     WHERE id = (v_pay->>'payment_id')::uuid
       AND counterparty_type = 'employee' AND employee_id = emp_a AND supplier_id IS NULL;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 90F 落库应当是 counterparty_type=employee、employee_id 有值、supplier_id 为空,实得 % 行', n;
    END IF;
    -- 结清之后它应当离开 AP 账龄(与供应商单据同一口径)
    SELECT count(*) INTO n FROM ap_open_items WHERE doc_id = exp_emp;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 90F 付清之后员工应付应当离开账龄,实得 % 行', n;
    END IF;
    RAISE NOTICE '90F 付给员工的出款:接受、核销、离开账龄 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- G. 【核销到别人的单上】仍然被拒 —— party_id 对员工也照样管用
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment(
            p_direction := 'out', p_counterparty_id := emp_b, p_amount := 700,
            p_currency := 'SGD', p_bank_account := '1000', p_payment_date := CURRENT_DATE,
            p_counterparty_kind := 'employee',
            p_allocations := jsonb_build_array(
                jsonb_build_object('expense_id', exp_sup, 'amount_doc', 700)));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('ALLOC_WRONG_PARTY' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 90G 把员工的付款核销到供应商的单据上必须拒(ALLOC_WRONG_PARTY),实得:%',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;
    RAISE NOTICE '90G 核销到别人的单上:按名拒 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- H. 报销全程【一个供应商都不出现】:submit → decide → pay
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        v_claim := submit_medical_claim(
            p_employee_id := emp_b, p_claim_date := CURRENT_DATE,
            p_amount_sgd := 120, p_description := 'fixture 90 claim');
        claim_id := (v_claim->>'claim_id')::uuid;
        PERFORM decide_medical_claim(p_claim_id := claim_id, p_approve := true);
        v_claim := pay_medical_claim(p_claim_id := claim_id, p_expense_date := CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        -- 实测:pay_medical_claim 不填 employee_id 时,逃出来的是
        -- COUNTERPARTY_REQUIRED_FOR_UNPAID —— 那句话对,但它没说是这一臂。
        RAISE EXCEPTION 'FIXTURE 90H 报销 submit→decide→pay 必须全程走通、且不需要任何供应商,实得拒绝:%', v_msg;
    END IF;

    SELECT count(*) INTO n FROM expenses
     WHERE id = (v_claim->>'expense_id')::uuid
       AND employee_id = emp_b AND supplier_id IS NULL AND payment_status = 'unpaid';
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 90H 报销产生的费用必须挂在【那个员工】身上、且没有供应商,实得 % 行', n;
    END IF;
    SELECT counterparty_kind, counterparty_name INTO v_kind, v_name
      FROM ap_open_items WHERE doc_id = (v_claim->>'expense_id')::uuid;
    IF v_kind <> 'employee' OR v_name IS DISTINCT FROM 'fixture 90 employee two' THEN
        RAISE EXCEPTION 'FIXTURE 90H 报销的应付要按【那个员工】的名字进账龄,实得 kind=% name=%', v_kind, COALESCE(v_name,'(NULL)');
    END IF;
    RAISE NOTICE '90H 报销 submit→decide→pay 全程无供应商,应付按员工姓名入账龄 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- I. 【已付费用不要求往来对象】—— 线上就有这样的历史行(2 笔),
    --    把"从不两个"误写成"永远必须有一个"会把它们全部挡下
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        v_exp := record_expense(
            p_expense_date := CURRENT_DATE, p_account_code := '6120',
            p_amount := 60, p_currency := 'SGD', p_payment_status := 'paid',
            p_bank_account := '1000');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR (v_exp->>'expense_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 90I 已付费用【不】要求往来对象(线上 2 笔历史行正是这个形状)—— 把"从不两个"误写成"永远必须有一个"会把它们全部挡下。实得:%', COALESCE(v_msg,'(建不出来)');
    END IF;
    RAISE NOTICE '90I 已付费用无往来对象:仍然接受 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- J. employee_id 【也不可改】—— 由【两道闸】共同保证
    --    ① 逐列枚举(fu1 把 employee_id 补了进去,让这份清单名副其实);
    --    ② 一句兜底:只放行"过账→冲销",别的 UPDATE 一律拒。
    --    【实测更正】写 fu1 时我以为清单漏了这一列就是个洞 —— 不是:
    --    只拿掉清单里的那一行,UPDATE 仍被兜底拒掉(注入实测)。
    --    所以这一臂断言的是【结果】(改不动),不是"fu1 补了一个洞"。
    --    能让它变红的注入必须【两道闸一起拿掉】。
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE expenses SET employee_id = emp_b WHERE id = exp_emp;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('EXPENSE_IMMUTABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 90J 已过账费用的 employee_id 必须【改不动】(EXPENSE_IMMUTABLE)—— 否则一笔钱可以被悄悄改欠给另一个人。实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE payments SET employee_id = emp_b WHERE id = (v_pay->>'payment_id')::uuid;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('PAYMENT_IMMUTABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 90J 已过账付款的 employee_id 必须【改不动】(PAYMENT_IMMUTABLE),实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '90J employee_id 在两张不可变凭证上都改不动(枚举 + 兜底,两道闸)✓';

    RAISE NOTICE 'FIXTURE 90 全部通过';
END $$;
ROLLBACK;
