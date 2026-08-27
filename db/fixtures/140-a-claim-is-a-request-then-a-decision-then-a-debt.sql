-- 140 报销:一次请求 → 一次决定 → 一笔【欠员工的债】(CLAIM-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉五件事】
--   · **链路真的通到底** —— 提交 → 批准 → 在 ap_open_items 里带着【员工自己的
--     名字】→ 付款结清。PAYEE-1a 之前那里是 INNER JOIN suppliers,员工那一行
--     整行消失;fixture 90 的原话是「消失比空白更坏」,这里接着守。
--   · **批准那一刻【同时】记成本与记债** —— 批之前账上没有,批之后有一笔
--     unpaid、挂这名员工、入账日等于【花钱那天】的费用。
--   · **自己不能批自己** —— 而这条只有在【设了 claims】时才测得到:
--     assert_segregated 在 auth.uid() 为 NULL 时【直接返回】,所以不设 claims
--     的臂是空转的(fixture 127 立的那条,AGENTS.md 反复记过)。
--   · **凭据有两条路,而"两条都没有"按名拒** —— 一条没有例外出口的规矩会被绕过。
--   · **付了没有是【推导】的** —— 冲销那笔费用,claim 的状态跟着走。
--
-- ★【两个反复出现的陷阱,这份 fixture 都刻意躲开】★
--   ① 靠"两个实现碰巧一致"通过:B 臂不比"两个数相等",它比【入账日等于花钱
--      那天而不是今天】—— 而两者必须先被证明不同。
--   ② 目录断言匹配到注释:J 臂先剥注释,而且匹配【带参数的调用形状】。
--
-- 自带数据(README 第 2 条);期间锁自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_claimant  uuid := gen_random_uuid();
    v_approver  uuid := gen_random_uuid();
    r_all       uuid;
    v_emp       uuid; v_emp2 uuid;
    v_base      text; v_bank text;
    v_acct      text := '6120';
    d_spend     date := CURRENT_DATE - 10;
    v_res       jsonb; v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid;
    v_exp       uuid;
    v_n int; v_n2 int; v_before int; v_after int; v_msg text; v_src text;
    v_ap_emp numeric; v_ap_sup int;
    v_post date; v_owing boolean; v_paid boolean;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_claimant), (v_approver);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-140', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    -- 【两个人【都】拿全权限】—— 这一点是刻意的:职责分离要证的是
    -- "有权限但【是本人】的那个人也被拒",而不是"没权限的人被拒"。
    -- 后者是权限检查,不是职责分离,而把两者混起来正是一条查错了东西的断言。
    INSERT INTO user_roles (user_id, role_id) VALUES (v_claimant, r_all), (v_approver, r_all);

    -- 【前提显式设定，两个都是真前提】（README 第 4/5 条）
    --   · 期间锁 —— I 臂要自己开合它；
    --   · ★ GST 开关 —— 本 fixture 的 K 臂测的正是「GST 注册期间税码必给」，
    --     而重建库里 gst_registered 的引导默认值是 **false**，于是所有带税码的
    --     调用会撞上 GST_NOT_REGISTERED。第一版只在线上干跑过（线上是 true），
    --     所以这件事直到 gate 跑重建库才现形 —— 正是「不要继承时点/配置状态，
    --     要什么就自己设」那一条。
    UPDATE finance_settings
       SET locked_before = NULL,
           gst_registered = true,
           gst_registration_no = COALESCE(gst_registration_no, 'ZZ-F140-GST');
    SELECT code INTO v_base FROM currencies WHERE is_base;
    v_bank := bank_account_for_currency(v_base);

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F140-E', 'fixture 140 claimant', 'full_time', 'office', CURRENT_DATE - 400, v_claimant)
    RETURNING id INTO v_emp;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZ-F140-E2', 'fixture 140 other', 'full_time', 'office', CURRENT_DATE - 400)
    RETURNING id INTO v_emp2;
    -- 一家供应商 + 一笔未付供应商费用 —— A 臂的【配对断言】要它
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F140-S', 'fixture 140 supplier', 'SG', 'active', 'goods_supplier');
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_approver), true);
    PERFORM record_expense(
        p_expense_date := d_spend, p_account_code := v_acct, p_amount := 500,
        p_currency := v_base, p_payment_status := 'unpaid',
        p_supplier_id := (SELECT id FROM suppliers WHERE code='ZZ-F140-S'),
        p_tax_code := 'TX');

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 链路端到端,而员工那一行【带着自己的名字】出现在应付里
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 自证非空:花钱那天必须与今天【不同】,否则 B 臂的"入账日不是今天"
    --   退化成一句同义反复。
    IF d_spend = CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 140A 失败(空转):花钱那天就是今天 —— 入账日那条断言证明不了任何事';
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_claimant), true);
    v_res := submit_expense_claim(v_emp, d_spend, 120.50, v_base, '打车去客户那边', NULL);
    v_c1 := (v_res->>'claim_id')::uuid;
    IF (v_res->>'code') NOT LIKE 'CLM-%' THEN
        RAISE EXCEPTION 'FIXTURE 140A 失败:取号不对 —— %', v_res->>'code';
    END IF;

    -- 凭据:挂一份附件上去(D 臂会再测另外两条路)
    INSERT INTO finance_attachments (claim_id, file_name, file_path, mime_type)
    VALUES (v_c1, 'taxi.pdf', format('%s/taxi.pdf', v_c1), 'application/pdf');

    -- ══ 批准之前:账上【没有】这笔费用 ═══════════════════════════════════
    SELECT count(*) INTO v_before FROM expenses
     WHERE employee_id = v_emp AND status = 'posted';
    IF v_before <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 140B 失败(空转):还没批,账上就已经有 % 笔挂这名员工的费用', v_before;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_approver), true);
    v_res := decide_expense_claim(v_c1, true, v_acct, 'TX', NULL, NULL);
    v_exp := (v_res->>'expense_id')::uuid;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · 批准那一刻【同时】记成本与记债,而入账日是【花钱那天】
    -- ══════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_after FROM expenses
     WHERE employee_id = v_emp AND status = 'posted' AND payment_status = 'unpaid';
    IF v_after <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 140B 失败:批准之后应当【恰好】有 1 笔挂这名员工的未付费用,实得 %', v_after;
    END IF;
    SELECT expense_date INTO v_post FROM expenses WHERE id = v_exp;
    IF v_post <> d_spend THEN
        RAISE EXCEPTION 'FIXTURE 140B 失败:入账日是 %,而花钱那天是 % —— 成本被记进了它没有发生的那个期间',
            v_post, d_spend;
    END IF;
    IF v_post = CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 140B 失败:入账日等于今天 —— 那是"默认成今天"的形状,不是"记在花钱那天"';
    END IF;

    -- ══ 应付里那一行:带着【员工自己的名字】,而供应商那一支仍然在 ═══════
    -- 【配对断言】只断言"员工行在场且名字对"是不够的:一个把费用那一支
    -- 整个关掉的实现也会让员工行"不带错名字"。所以两条一起断言
    -- (GRN-2 的 G/H、SUP-TYPE-1a 的 A/B、fixture 90 同一条)。
    SELECT COALESCE(sum(open_base),0) INTO v_ap_emp FROM ap_open_items
     WHERE counterparty_kind = 'employee' AND counterparty_id = v_emp;
    SELECT count(*) INTO v_ap_sup FROM ap_open_items WHERE counterparty_kind = 'supplier';
    IF v_ap_emp <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 140B 失败:应付里看不见这笔欠员工的钱(实得 %) —— 消失比空白更坏', v_ap_emp;
    END IF;
    IF v_ap_sup = 0 THEN
        RAISE EXCEPTION 'FIXTURE 140B 失败(配对):供应商那一支不见了 —— 一个把整支关掉的实现也能让员工那一行"不带错名字"';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ap_open_items
                    WHERE counterparty_kind='employee' AND counterparty_name = 'fixture 140 claimant') THEN
        RAISE EXCEPTION 'FIXTURE 140B 失败:应付那一行【说不出是谁】—— 名字不是 fixture 140 claimant';
    END IF;

    RAISE NOTICE 'fixture 140 · 报销 —— A/B 臂通过';

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · ★【自己不能批自己】★ —— 而这条只有设了 claims 才测得到
    -- ══════════════════════════════════════════════════════════════════════
    -- assert_segregated 在 auth.uid() 为 NULL 时【直接返回】。所以:
    -- ① 先证明 claims 真的设上了(否则这一臂是空转的,fixture 127 那一课);
    -- ② 再证明【有权限但是本人】的那个人被拒 —— 拒的必须是"职责分离",
    --    不是"没权限"。两个人在布景里都拿了全权限,正是为了这一点。
    IF NULLIF(current_setting('request.jwt.claims', true), '') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 140C 失败(空转):claims 没设,assert_segregated 会直接返回 —— 这一臂什么都没测';
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_claimant), true);
    v_res := submit_expense_claim(v_emp, d_spend, 60, v_base, '自己批自己的那一笔', '小额无票');
    v_c2 := (v_res->>'claim_id')::uuid;
    -- 先证明这个人【确实有权批】—— 否则下面拒的是权限,不是职责分离
    IF NOT has_permission('module.finance.edit') THEN
        RAISE EXCEPTION 'FIXTURE 140C 失败(空转):提报人没有 finance.edit —— 那么被拒的是权限,而不是职责分离';
    END IF;
    BEGIN
        PERFORM decide_expense_claim(v_c2, true, v_acct, 'TX', NULL, NULL);
        RAISE EXCEPTION 'FIXTURE 140C 失败:提报人批了自己那一笔';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPENSE_CLAIM_SELF_APPROVAL%' THEN
            RAISE EXCEPTION 'FIXTURE 140C 失败:应报 EXPENSE_CLAIM_SELF_APPROVAL,实得 %', v_msg;
        END IF;
    END;
    -- 换个人批就过 —— 证明拒的是【那个人】,不是这条路
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_approver), true);
    PERFORM decide_expense_claim(v_c2, true, v_acct, 'TX', NULL, NULL);
    IF (SELECT status FROM expense_claims WHERE id = v_c2) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 140C 失败:换人批之后仍然不是 approved —— 那说明拒的是这条路本身';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · 凭据两条路都要通,而【两条都没有】按名拒
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 自证非空:三笔都要真的建出来,而且【第三笔既没附件也没理由】——
    --   否则"两者都没有会被拒"是在一个不存在的情形上做的断言。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_claimant), true);
    v_res := submit_expense_claim(v_emp, d_spend, 30, v_base, '既没票也没理由', NULL);
    v_c3 := (v_res->>'claim_id')::uuid;
    IF EXISTS (SELECT 1 FROM finance_attachments WHERE claim_id = v_c3)
       OR COALESCE(btrim((SELECT no_receipt_reason FROM expense_claims WHERE id = v_c3)),'') <> '' THEN
        RAISE EXCEPTION 'FIXTURE 140D 失败(空转):第三笔身上有凭据 —— 这一臂要测的正是"两条都没有"';
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_approver), true);
    BEGIN
        PERFORM decide_expense_claim(v_c3, true, v_acct, 'TX', NULL, NULL);
        RAISE EXCEPTION 'FIXTURE 140D 失败:既没附件也没理由的那一笔被批了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPENSE_CLAIM_NO_EVIDENCE%' THEN
            RAISE EXCEPTION 'FIXTURE 140D 失败:应报 EXPENSE_CLAIM_NO_EVIDENCE,实得 %', v_msg;
        END IF;
    END;
    -- 而【有附件】那一路(v_c1)与【有理由】那一路(v_c2)刚才都批过了 ——
    -- 两条例外出口都真的通,这一臂才不是"只留了一条不可能走的路"
    IF (SELECT status FROM expense_claims WHERE id = v_c1) <> 'approved'
       OR (SELECT status FROM expense_claims WHERE id = v_c2) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 140D 失败:两条凭据路径没有都通(附件那笔 % / 理由那笔 %)',
            (SELECT status FROM expense_claims WHERE id = v_c1),
            (SELECT status FROM expense_claims WHERE id = v_c2);
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · 驳回必须给理由,而【按名拒,不是让 CHECK 抛约束原文】
    -- ══════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM expense_claims;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 140E 失败(空转):一笔报销都没有 —— "拒完没多出行"要有非零基线';
    END IF;
    BEGIN
        PERFORM decide_expense_claim(v_c3, false, NULL, NULL, NULL, NULL);
        RAISE EXCEPTION 'FIXTURE 140E 失败:驳回没给理由却过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPENSE_CLAIM_REJECT_REASON_REQUIRED%' THEN
            RAISE EXCEPTION 'FIXTURE 140E 失败:应报 EXPENSE_CLAIM_REJECT_REASON_REQUIRED(而不是约束原文),实得 %', v_msg;
        END IF;
    END;
    PERFORM decide_expense_claim(v_c3, false, NULL, NULL, NULL, '没有收据也说不出为什么');
    IF (SELECT status FROM expense_claims WHERE id = v_c3) <> 'rejected' THEN
        RAISE EXCEPTION 'FIXTURE 140E 失败:给了理由的驳回没有生效';
    END IF;
    SELECT count(*) INTO v_n2 FROM expense_claims;
    IF v_n2 <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 140E 失败:拒绝之后报销行数从 % 变成了 %', v_n, v_n2;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · 撤回可以,改不行;已决定的撤不回
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_claimant), true);
    v_res := submit_expense_claim(v_emp, d_spend, 45, v_base, '交错了要撤回', '小额无票');
    v_c4 := (v_res->>'claim_id')::uuid;
    PERFORM withdraw_expense_claim(v_c4);
    IF (SELECT status FROM expense_claims WHERE id = v_c4) <> 'withdrawn' THEN
        RAISE EXCEPTION 'FIXTURE 140F 失败:撤回没生效';
    END IF;
    -- 撤回之后不能再决定
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_approver), true);
    BEGIN
        PERFORM decide_expense_claim(v_c4, true, v_acct, 'TX', NULL, NULL);
        RAISE EXCEPTION 'FIXTURE 140F 失败:一笔已撤回的报销被批了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPENSE_CLAIM_NOT_SUBMITTED%' THEN
            RAISE EXCEPTION 'FIXTURE 140F 失败:应报 EXPENSE_CLAIM_NOT_SUBMITTED,实得 %', v_msg;
        END IF;
    END;
    -- 已批准的撤不回(v_c1 已批)
    BEGIN
        PERFORM withdraw_expense_claim(v_c1);
        RAISE EXCEPTION 'FIXTURE 140F 失败:一笔已批准的报销被撤回了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPENSE_CLAIM_NOT_SUBMITTED%' THEN
            RAISE EXCEPTION 'FIXTURE 140F 失败(撤回已批准的):应报 EXPENSE_CLAIM_NOT_SUBMITTED,实得 %', v_msg;
        END IF;
    END;

    RAISE NOTICE 'fixture 140 · 报销 —— C–F 臂通过';

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · ★【付了没有是推导的】★ 三个状态各自要真的翻过一次
    -- ══════════════════════════════════════════════════════════════════════
    SELECT is_owing, is_paid INTO v_owing, v_paid
      FROM expense_claim_status WHERE claim_id = v_c1;
    IF NOT v_owing OR v_paid THEN
        RAISE EXCEPTION 'FIXTURE 140G 失败:批了还没付,应当 is_owing=true / is_paid=false,实得 % / %',
            v_owing, v_paid;
    END IF;
    -- 付掉它 —— 出款给【员工】那条路(record_payment 显式允许 employee)
    PERFORM record_payment('out', v_emp, 120.50, v_base, NULL, v_bank, CURRENT_DATE,
        'fixture 140 报销付款',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 120.50)),
        'employee');
    SELECT is_owing, is_paid INTO v_owing, v_paid
      FROM expense_claim_status WHERE claim_id = v_c1;
    IF v_owing OR NOT v_paid THEN
        RAISE EXCEPTION 'FIXTURE 140G 失败:付掉之后应当 is_owing=false / is_paid=true,实得 % / %',
            v_owing, v_paid;
    END IF;
    -- ★ 自证非空:两次读数必须真的不同,否则"推导"与"存了个常量"分不开 ——
    --   上面两条断言合起来已经保证了这件事(true/false → false/true)。

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 · 未来的花销按名拒 —— 那是备用金,而备用金被否决了
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_claimant), true);
    BEGIN
        PERFORM submit_expense_claim(v_emp, CURRENT_DATE + 1, 100, v_base, '下周要花的钱', NULL);
        RAISE EXCEPTION 'FIXTURE 140H 失败:一笔"将来才会花的钱"被当成报销收下了 —— 那是备用金';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPENSE_CLAIM_SPEND_DATE_FUTURE%' THEN
            RAISE EXCEPTION 'FIXTURE 140H 失败:应报 EXPENSE_CLAIM_SPEND_DATE_FUTURE,实得 %', v_msg;
        END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- I 臂 · 花钱那天在【关账】期间里 → 按名拒;显式给一个入账日 → 过
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 自证非空:先证明那个期间【真的】被锁上了,否则"被拒"可能另有原因
    v_res := submit_expense_claim(v_emp, d_spend, 88, v_base, '落在关账期间里的那一笔', '小额无票');
    v_c5 := (v_res->>'claim_id')::uuid;
    UPDATE finance_settings SET locked_before = d_spend + 1;
    IF (SELECT locked_before FROM finance_settings) <= d_spend THEN
        RAISE EXCEPTION 'FIXTURE 140I 失败(空转):期间锁没有真的盖住花钱那天';
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_approver), true);
    BEGIN
        PERFORM decide_expense_claim(v_c5, true, v_acct, 'TX', NULL, NULL);
        RAISE EXCEPTION 'FIXTURE 140I 失败:入账日落在关账期间里,却过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PERIOD_LOCKED%' THEN
            RAISE EXCEPTION 'FIXTURE 140I 失败:应报 PERIOD_LOCKED,实得 %', v_msg;
        END IF;
    END;
    -- 【显式】给一个开着的日子就过 —— 而它是审批人给的,不是系统偷偷回落的
    PERFORM decide_expense_claim(v_c5, true, v_acct, 'TX', CURRENT_DATE, NULL);
    IF (SELECT posting_date FROM expense_claims WHERE id = v_c5) <> CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 140I 失败:显式给的入账日没有被记下来';
    END IF;
    IF (SELECT spend_date FROM expense_claims WHERE id = v_c5) <> d_spend THEN
        RAISE EXCEPTION 'FIXTURE 140I 失败:花钱那天被入账日覆盖了 —— 两者是两个事实,不能合成一个';
    END IF;
    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════════════════════════════════════════════════════════════════
    -- K 臂 · GST 开着时【税码必给】,而且只能由审批人给
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 自证非空:先证明 GST 【真的】开着,否则这一臂拒的可能是别的东西;
    --   再证明 employees 那一侧【确实】没有 default_tax_code 这一列 ——
    --   那正是"只能显式给"的全部依据。
    IF NOT (SELECT gst_registered FROM finance_settings) THEN
        RAISE EXCEPTION 'FIXTURE 140K 失败(空转):GST 没开 —— 税码本来就不必给,这一臂什么都没测';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid='public.employees'::regclass AND attname='default_tax_code' AND attnum>0) THEN
        RAISE EXCEPTION 'FIXTURE 140K 失败(前提变了):employees 现在有 default_tax_code 了 —— 「员工侧永远解析不出默认税码」这个理由不再成立,这条断言要重写';
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_claimant), true);
    v_res := submit_expense_claim(v_emp, d_spend, 15, v_base, '没给税码的那一笔', '小额无票');
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_approver), true);
    BEGIN
        PERFORM decide_expense_claim((v_res->>'claim_id')::uuid, true, v_acct, NULL, NULL, NULL);
        RAISE EXCEPTION 'FIXTURE 140K 失败:GST 开着却没给税码,居然批过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'EXPENSE_CLAIM_TAX_CODE_REQUIRED%' THEN
            RAISE EXCEPTION 'FIXTURE 140K 失败:应报 EXPENSE_CLAIM_TAX_CODE_REQUIRED,实得 %', v_msg;
        END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- J 臂 · 目录断言:它【真的调】职责分离与 record_expense
    -- ══════════════════════════════════════════════════════════════════════
    -- ★【先剥注释,而且匹配【带参数的调用形状】】★ fixture 136 曾经匹配到一句
    -- 注释而绿;CHASE-1 更细一层:只匹配函数名也不够,因为函数名会出现在
    -- 别处。所以钉的是调用形状。
    SELECT string_agg(l, E'\n') INTO v_src
      FROM (SELECT regexp_replace(l, '--.*$', '') AS l
              FROM regexp_split_to_table(
                     pg_get_functiondef('public.decide_expense_claim(uuid,boolean,text,text,date,text)'::regprocedure),
                     E'\n') AS l) q;
    IF v_src NOT LIKE '%assert_segregated(''EXPENSE_CLAIM_SELF_APPROVAL'', v_actors, v_c.code)%' THEN
        RAISE EXCEPTION 'FIXTURE 140J 失败:decide_expense_claim 里【没有】那一次 assert_segregated 调用 —— 而 guard_payment_sod 明确豁免了付给员工的款,上游这道闸一撤,自己批自己就通了';
    END IF;
    -- 【对齐用的空格数不算数,绑定关系才算数】第一版把 p_employee_id 与 :=
    -- 之间的空格数写死成三个,而 pg_get_functiondef 存的是四个 —— 断言于是
    -- 因为【排版】而红。钉的应当是"这个参数绑到了这笔申请的员工",不是缩进。
    IF v_src NOT LIKE '%record_expense(%p_employee_id%:= v_c.employee_id%' THEN
        RAISE EXCEPTION 'FIXTURE 140J 失败:批准没有把费用挂到【那名员工】头上 —— 应付就说不出欠谁';
    END IF;
    IF v_src NOT LIKE '%p_payment_status%:= ''unpaid''%' THEN
        RAISE EXCEPTION 'FIXTURE 140J 失败:批准建的不是一笔【未付】费用 —— 那就没有记下对员工的债';
    END IF;

    RAISE NOTICE 'fixture 140 · 报销 —— 十一臂全部通过';
END $$;
ROLLBACK;
