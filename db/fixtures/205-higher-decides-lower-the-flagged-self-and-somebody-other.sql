-- 205 APR-ROUTE-1 · Batch A:【高一级批低一级】· 【二级持有人的标记自批】·
--                            【除了主角还有没有人批得动】· 【报销单只给本人与财务读】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   R1a ★ 一级的单:一级持有人自己提的 → |raiser;★ 二级持有人【批得动】(R1),
--        留痕 level = 1、self_decided = false
--        ☞ R1 之前这一格必然抛 APPROVAL_NOT_AUTHORISED|1 —— 那正是线上 chooer 的形状
--   R1b ★ R1 只向下:一级持有人去批二级的单 → APPROVAL_NOT_AUTHORISED|2
--   R2a ★★ 二级持有人【自己的】报销单(自己提、说的也是自己)→ 批得动,
--        留痕 self_decided = TRUE(事实被记下来)
--   R2b ★★ 二级持有人【替别人提】的报销单 → 他照样被拒 |raiser(例外要求"主角就是我")
--   R2c ★ 医疗申报:二级持有人(另持 hr.edit)自己的 → 批得动、self_decided = true
--   R2d ★ 【对照】一个【不是】二级持有人的 hr.edit 持有人,自己的医疗申报 → |raiser
--        ☞ 少了它,R2c 证明的可能只是"医疗申报根本不判自批"
--   R2e ★★ ~~例外【永远不覆盖】请假~~ —— ★ ROLE-1(Tim 的矩阵,2026-09-23)把请假加进来了,只对 CFO:
--        二级持有人自己的请假 → 决定得了,self_decided = TRUE
--   R2e′ ★【对照】一个【不是】二级持有人的决定人,自己的请假 → 照拒 |raiser
--        ☞ 少了它,R2e 证明的可能只是"请假根本不判自批"
--   R2f ★★ 一个【只持二级角色】的账号(独立 CFO 账号的形状)批自己的医疗申报 →
--        PERMISSION_DENIED|action.decide_hr_requests —— 例外不放宽任何模块门(Q5)
--        (ROLE-1 之前那个门是 module.hr.edit;线上的 cfo 从 ROLE-1 起持有决定码,
--         而这里的二级角色刻意不持 —— 这一臂问的是"例外会不会替你开门")
--   R2g ★ approval_log_self_decided_scope:往绩效评估上写一行 self_decided = true → 当场拒
--        (ROLE-1 之前用的是请假;请假如今在范围之内,于是换一个仍在范围之外的类型)
--   R2h ★★ 报表:没有码 → RAISE(不是零行);有码 → 读得到 R2a、R2c 与 R2e 那三行,
--        带主角的名字;【而一行非自批都没有】
--   R4a ★★ 面板:二级只有一个人时,own_document_gaps 点名他 ——
--        采购那两条链 self_exception = false(他的单会搁死),
--        报销那一条 self_exception = true(只能自批);一级那几条【一格都没有】
--   R4b ★★★ WOULD_STRAND 按【这一张】判:一张二级的在途报销,提单人正是二级唯一
--        的持有人、主角是别人 → 一次无关的门槛微调被按名拒,并点出那张单。
--        ☞ R4 之前这一格【放行】:"二级有 1 个持有人",而那一个人是提单人。
--   R4c ★ 【对照】给二级加第二个人 → 同一次编辑放行
--   R5  ★★★ expense_claim_status:非财务、非主角的真身份【只读到自己的】;
--        财务读者读到全部。每一次读之前先证 auth.uid() 真的切过去了。
--
-- 【躲开的陷阱,逐条】
--  (a) 每一条拒绝都配一条会成功的对照(R1a 的二级 / R2d 之于 R2c / R4c 之于 R4b)。
--  (b) 断言为真却没有管辖权 —— 被拒的演员都持那条链的门(同一臂里的对照当场证明)。
--  (c) ★ 求交按【人】算:一个人的权限是他所有角色的并集(fixture 203/204 各踩过一次)。
--      所以"只持二级角色"的那个账号【只】授那一个角色,并断言它。
--  (d) ★ RLS / 属主视图的读必须【切到真身份】并先证切过去了(README 第 6 条)。
--  (e) v_msg 是复用的变量 —— 每一臂开跑前清掉,否则"没报错"会印出上一臂的那句拒绝。
--
-- 自带数据(README 第 2 条)。不继承线上任何值 —— 自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_l1    uuid := gen_random_uuid();   -- 一级持有人(员工 E1)
    u_l2    uuid := gen_random_uuid();   -- 二级持有人(员工 E2),另持 hr.edit
    u_hr    uuid := gen_random_uuid();   -- 只持 hr.edit(员工 E3)—— R2d 的对照
    u_plain uuid := gen_random_uuid();   -- 什么模块都进不去的员工(E4)
    u_cfo   uuid := gen_random_uuid();   -- 【只持二级角色】—— 独立 CFO 账号的形状(员工 E5)
    u_adm   uuid := gen_random_uuid();   -- action.manage_permissions
    u_aud   uuid := gen_random_uuid();   -- data.view_self_approvals + module.finance.view
    r_l1 uuid; r_l2 uuid; r_hr uuid; r_adm uuid; r_aud uuid;
    e1 uuid := gen_random_uuid(); e2 uuid := gen_random_uuid(); e3 uuid := gen_random_uuid();
    e4 uuid := gen_random_uuid(); e5 uuid := gen_random_uuid();
    -- 报销单
    c_l1own   uuid := gen_random_uuid();   -- E1 自己的,一级
    c_hi_pl   uuid := gen_random_uuid();   -- E4 自己的,二级
    c_l2own   uuid := gen_random_uuid();   -- E2 自己的,二级
    c_l2for4  uuid := gen_random_uuid();   -- E2 替 E4 提的,二级 —— R2b 与 R4b
    -- 医疗 / 请假
    mc_l2own  uuid := gen_random_uuid();
    mc_hrown  uuid := gen_random_uuid();
    mc_cfoown uuid := gen_random_uuid();
    lv_l2own  uuid := gen_random_uuid();
    lv_hrown  uuid := gen_random_uuid();   -- ROLE-1 · R2e′
    v_base text;
    v_n integer; v_m integer; v_msg text; v_denied boolean;
    v_lvl smallint; v_self boolean; v_name text; v_name2 text;
    v_read jsonb; v_gap jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF v_base IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 205 布景失败:currencies 里没有本位币'; END IF;

    -- ══════════════════════ 布景 ══════════════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_l1, now()), (u_l2, now()), (u_hr, now()), (u_plain, now()),
        (u_cfo, now()), (u_adm, now()), (u_aud, now());

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx205-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx205-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx205-hr','f','f',true)  RETURNING id INTO r_hr;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx205-adm','f','f',true) RETURNING id INTO r_adm;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx205-aud','f','f',true) RETURNING id INTO r_aud;

    -- 两级都持报销与采购两条链的门(否则开关会为【别的链】变红);
    -- ★ 二级角色【不】持 hr.edit —— R2f 要一个只持它的账号走不进医疗申报。
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_l1, 'module.finance.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'), (r_l1, 'module.purchasing.view'),
        (r_l2, 'module.finance.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'), (r_l2, 'module.purchasing.view'),
        (r_hr, 'module.hr.edit'), (r_hr, 'module.hr.view'),
        -- ROLE-1(2026-09-23):请假与医疗申报的决定门换成 action.decide_hr_requests
        (r_hr, 'action.decide_hr_requests'),
        (r_adm, 'action.manage_permissions'), (r_adm, 'module.finance.view'),
        (r_aud, 'data.view_self_approvals'), (r_aud, 'module.finance.view');

    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_l1, r_l1), (u_l2, r_l2), (u_l2, r_hr), (u_hr, r_hr),
        (u_adm, r_adm), (u_aud, r_aud);
    -- u_cfo 的二级角色【晚一点】才授:R4a 要"二级只有一个人"那个形状。

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e1, 'FX205-E1', 'E1 one',   'full_time', 'office', DATE '2020-01-01', u_l1),
        (e2, 'FX205-E2', 'E2 two',   'full_time', 'office', DATE '2020-01-01', u_l2),
        (e3, 'FX205-E3', 'E3 three', 'full_time', 'office', DATE '2020-01-01', u_hr),
        (e4, 'FX205-E4', 'E4 four',  'full_time', 'office', DATE '2020-01-01', u_plain),
        (e5, 'FX205-E5', 'E5 five',  'full_time', 'office', DATE '2020-01-01', u_cfo);

    -- 金额一律本位币 —— 不依赖 fx_rates,这一支验的是路由,不是 THE FX RULE。
    INSERT INTO expense_claims (id, code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, status, created_by) VALUES
        (c_l1own,  'FX205-C-L1OWN',  e1, DATE '2030-03-01',   60.00, v_base, 'l1 own',  'none', 'submitted', u_l1),
        (c_hi_pl,  'FX205-C-HIPL',   e4, DATE '2030-03-01', 1500.00, v_base, 'hi plain','none', 'submitted', u_plain),
        (c_l2own,  'FX205-C-L2OWN',  e2, DATE '2030-03-01', 1500.00, v_base, 'l2 own',  'none', 'submitted', u_l2),
        (c_l2for4, 'FX205-C-L2FOR4', e4, DATE '2030-03-01', 1500.00, v_base, 'for 4',   'none', 'submitted', u_l2);

    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status, created_by) VALUES
        (mc_l2own,  'FX205-MC-L2',  e2, DATE '2030-03-04', 2030, 10, 'submitted', u_l2),
        (mc_hrown,  'FX205-MC-HR',  e3, DATE '2030-03-04', 2030, 10, 'submitted', u_hr),
        (mc_cfoown, 'FX205-MC-CFO', e5, DATE '2030-03-04', 2030, 10, 'submitted', u_cfo);

    INSERT INTO leave_types (code, name_en, name_zh, is_accrued, is_active)
      VALUES ('fx205-lv', 'f', 'f', false, true);
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by)
      VALUES (lv_l2own, 'FX205-LV-1', e2, 'fx205-lv', DATE '2030-03-04', DATE '2030-03-04', 1, 'pending', u_l2);
    -- ROLE-1 · R2e′ 的对照:一个不是二级持有人的决定人(u_hr,E3)自己的请假
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by)
      VALUES (lv_hrown, 'FX205-LV-2', e3, 'fx205-lv', DATE '2030-03-05', DATE '2030-03-05', 1, 'pending', u_hr);

    -- 策略:两级各一个真持有人,门槛 1000,审批【开着】。直写四列要显式举旗(APR-1)。
    -- ★ PAYROLL-APR-1(2026-09-24):工资过账申请这条链的门是 module.hr.view + data.view_pay(Tim 的 Q8)。
    --   二级角色不持这两个码,开审批就会按名拒 APPROVALS_CHAIN_HAS_NO_APPROVER|decide_payroll_request —— 本 fixture 测的不是它。
    -- ★ ROLE-1 Batch 4b(2026-09-25):收货定价申请这条链的门是 module.inbound.view + data.view_purchase_prices
    --   (Tim 的 Q2),同一个理由一并给上 —— 否则 …|decide_receipt_price_request。
    -- ★ APR-5b(2026-09-25):发货放行这条链的门是 module.sales.view + data.view_prices(Q13);二级角色
    --   已持 data.view_prices,补上 module.sales.view —— 否则 …|decide_shipping_release。
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM roles r CROSS JOIN unnest(ARRAY['module.hr.view', 'data.view_pay', 'module.inbound.view', 'data.view_purchase_prices', 'module.sales.view']) c
     WHERE r.code = 'fx205-l2'
    ON CONFLICT (role_id, permission_code) DO NOTHING;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false,
                                approval_level1_role_code = 'fx205-l1',
                                approval_level2_role_code = 'fx205-l2',
                                approval_threshold_base   = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'FIXTURE 205 布景失败:审批没开起来'; END IF;

    -- ══════════════════════ R4a ★★ 面板:他自己的单,谁来批 ══════════════════════
    -- 【先跑它】它要"二级只有一个人"那个形状;R4c 会给二级加第二个人。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_read := approvals_readiness();
    EXECUTE 'RESET ROLE';
    IF (v_read->>'own_document_gaps_block')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 205R4a 失败:own_document_gaps 应当是忠告(block = false),实得 %', v_read->>'own_document_gaps_block'; END IF;
    IF (v_read->>'chains_without_approver')::integer <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 205R4a 失败:每一条链都应当有人批得动,面板说 % 条没有', v_read->>'chains_without_approver'; END IF;
    -- 二级的四条链各有一格,且点名的都是 u_l2
    -- ★ PAY-REQ-1(2026-09-23):三 → 四 —— 付款申请只有二级那一行,而它没有自批例外,
    --   所以 u_l2 自己提的付款申请同样没人替他批(那一格与采购单同形:self_exception=false)。
    -- ★ PAYROLL-APR-1(2026-09-24):四 → 五 —— 工资过账申请同样只有二级一行、没有自批例外;
    --   u_l2 持它的门(本 fixture 为开审批授了 hr.view + view_pay),于是他自己提的那一张也没人替他批。
    -- ★ ROLE-1 Batch 4b(2026-09-25):五 → 六 —— 收货定价申请同样只有二级一行、没有自批例外;
    --   u_l2 持它的门(本 fixture 为开审批授了 inbound.view + 采购码),于是同一条。
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_read->'own_document_gaps') g
     WHERE (g->>'level')::int = 2 AND (g->>'user_id')::uuid = u_l2;
    -- ★ APR-5a(2026-09-25):六 → 七 —— 贷项 / 作废申请同样只有二级一行、没有自批例外;
    --   u_l2 持它的门(module.finance.view + data.view_prices,付款申请本来就要),于是同一条。
    -- ★ APR-5b(2026-09-25):七 → 八 —— 发货放行同样只有二级一行、没有自批例外;u_l2 持它的门
    --   (module.sales.view 上面补给了,data.view_prices 本来就有),于是同一条。
    IF v_n <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 205R4a 失败:二级八条链应当各点名 u_l2 一次,实得 %;全部 = %', v_n, v_read->'own_document_gaps'; END IF;
    -- 一级一格都没有:R1 让二级的人替一级持有人批,一级持有人也替二级持有人的一级单批
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_read->'own_document_gaps') g WHERE (g->>'level')::int = 1;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 205R4a 失败:一级不该有"他自己的单没人批"的格子(R1),实得 %', v_read->'own_document_gaps'; END IF;
    -- 采购那两条 self_exception = false(会搁死),报销那一条 = true(只能自批)
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_read->'own_document_gaps') g
     WHERE g->>'subject_type' = 'purchase_order' AND (g->>'self_exception')::boolean = false;
    SELECT count(*) INTO v_m FROM jsonb_array_elements(v_read->'own_document_gaps') g
     WHERE g->>'subject_type' = 'expense_claim' AND (g->>'self_exception')::boolean = true;
    IF v_n <> 2 OR v_m <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 205R4a 失败:采购两条应当 self_exception=false(实得 %),报销一条应当 true(实得 %)', v_n, v_m; END IF;
    -- 一级的求交数的是【人】,并且含 R1:2 人;二级 1 人
    SELECT min(approvers) FILTER (WHERE level = 1), max(approvers) FILTER (WHERE level = 2)
      INTO v_n, v_m FROM approval_gate_intersections();
    IF v_n <> 2 OR v_m <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 205R4a 失败:一级应当 2 人(含二级的那一位)、二级 1 人,实得 % / %', v_n, v_m; END IF;

    -- ══════════════════════ R1a ★ 一级的单,二级的人批得动 ══════════════════════
    v_msg := NULL; v_denied := false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    BEGIN
        PERFORM decide_expense_claim(c_l1own, false, NULL, NULL, NULL, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R1a 失败:一级持有人批自己的单应当报 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l2), true);
    PERFORM decide_expense_claim(c_l1own, false, NULL, NULL, NULL, '二级替一级批');
    SELECT level, self_decided INTO v_lvl, v_self FROM approval_log
     WHERE subject_type = 'expense_claim' AND subject_id = c_l1own;
    IF v_lvl IS DISTINCT FROM 1 OR v_self IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 205R1a 失败:★ 二级的人应当批得动一级的单(R1),留痕 level=1、self_decided=false;实得 level=% self=%', v_lvl, v_self; END IF;

    -- ══════════════════════ R1b ★ R1 只向下 ══════════════════════
    v_msg := NULL; v_denied := false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    BEGIN
        PERFORM decide_expense_claim(c_hi_pl, false, NULL, NULL, NULL, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'APPROVAL_NOT_AUTHORISED|2|fx205-l2'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R1b 失败:一级的人去批二级的单应当报 APPROVAL_NOT_AUTHORISED|2|fx205-l2,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ R2a ★★ 二级持有人自己的报销单 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l2), true);
    PERFORM decide_expense_claim(c_l2own, false, NULL, NULL, NULL, '自己的,自己拒');
    SELECT self_decided, level INTO v_self, v_lvl FROM approval_log
     WHERE subject_type = 'expense_claim' AND subject_id = c_l2own;
    IF v_self IS DISTINCT FROM true OR v_lvl IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 205R2a 失败:二级持有人决定自己的报销单应当成功并标成 self_decided=true(level 2),实得 self=% level=%', v_self, v_lvl; END IF;

    -- ══════════════════════ R2b ★★ 他替别人提的单,他照样被拒 ══════════════════════
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM decide_expense_claim(c_l2for4, false, NULL, NULL, NULL, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R2b 失败:★ 二级持有人替别人提的单,他批应当报 |raiser —— 例外只覆盖"说的是我"的单,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ R2c ★ 医疗:二级持有人自己的 ══════════════════════
    PERFORM decide_medical_claim(mc_l2own, false, '自己的医疗,自己拒');
    SELECT self_decided INTO v_self FROM approval_log WHERE subject_type = 'medical_claim' AND subject_id = mc_l2own;
    IF v_self IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 205R2c 失败:二级持有人(持 hr.edit)决定自己的医疗申报应当成功并标记,实得 %', v_self; END IF;

    -- ══════════════════════ R2d ★ 对照:不是二级持有人 → 照拒 ══════════════════════
    v_msg := NULL; v_denied := false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    BEGIN
        PERFORM decide_medical_claim(mc_hrown, false, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R2d 失败:一个不持二级角色的 hr.edit 持有人批自己的医疗申报应当报 |raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ R2e ★★ ROLE-1:例外覆盖 CFO 自己的请假 ══════════════════════
    -- 此前这一臂断言"二级持有人批自己的请假 → |raiser"。Tim 的矩阵(2026-09-23)反过来:
    -- 「Tim 自己的假,Tim 自己批,标成 self_decided」。旧的断言如今是【错的规矩】,不是回归。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l2), true);
    PERFORM decide_leave_request(lv_l2own, false, '自己的假,自己拒');
    SELECT self_decided INTO v_self FROM approval_log WHERE subject_type = 'leave_request' AND subject_id = lv_l2own;
    IF v_self IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 205R2e 失败:二级持有人决定自己的请假应当成功并标记 self_decided,实得 %', v_self; END IF;

    -- ══════════════════════ R2e′ ★ 对照:不是二级持有人 → 自己的请假照拒 ══════════════
    v_msg := NULL; v_denied := false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    BEGIN
        PERFORM decide_leave_request(lv_hrown, false, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R2e′ 失败:一个不持二级角色的决定人批自己的请假应当报 |raiser —— 例外只给 CFO,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ R2g ★ 范围 CHECK:第二道保险 ══════════════════════
    -- ROLE-1:请假如今在范围之内,换一个仍在范围之外的类型(绩效评估 —— 例外永远不覆盖它)。
    v_msg := NULL; v_denied := false;
    BEGIN
        INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, actor_user_id, self_decided)
        VALUES ('performance_review', gen_random_uuid(), 'FX205-PR-X', 'approved', u_l2, true);
    EXCEPTION WHEN check_violation THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE '%approval_log_self_decided_scope%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R2g 失败:往绩效评估上写 self_decided=true 应当撞 approval_log_self_decided_scope,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ R2h ★★ 报表:没码就拒,有码就读得到那两行 ══════════════
    v_msg := NULL; v_denied := false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        PERFORM * FROM self_approved_decisions();
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|data.view_self_approvals'); END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R2h 失败:没有码的人读报表应当被拒(不是零行),实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_aud), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF auth.uid() IS DISTINCT FROM u_aud THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 205R2h 布景失败:auth.uid() 没有切到审计者'; END IF;
    SELECT count(*), count(*) FILTER (WHERE subject_id IN (c_l2own, mc_l2own, lv_l2own)),
           max(subject_name) FILTER (WHERE subject_id = c_l2own),
           max(subject_name) FILTER (WHERE subject_id = lv_l2own)
      INTO v_n, v_m, v_name, v_name2
      FROM self_approved_decisions() WHERE subject_code LIKE 'FX205-%';
    EXECUTE 'RESET ROLE';
    -- ROLE-1:第三行是 R2e 那张请假;它的主角名要读得出来(self_approved_decisions 加了 leave_requests 那一支)
    IF v_n <> 3 OR v_m <> 3 OR v_name IS DISTINCT FROM 'E2 two' OR v_name2 IS DISTINCT FROM 'E2 two' THEN
        RAISE EXCEPTION 'FIXTURE 205R2h 失败:报表应当恰好是 R2a、R2c 与 R2e 那三行、主角名都是 E2 two;实得 % 行 / 命中 % / 名字 % / 请假主角 %', v_n, v_m, v_name, v_name2; END IF;

    -- ══════════════════════ R4b ★★★ WOULD_STRAND 按【这一张】判 ══════════════════
    -- 在途:c_hi_pl(E4 自己提,二级)与 c_l2for4(u_l2 替 E4 提,二级)。
    -- 二级唯一的人是 u_l2,而他是 c_l2for4 的提单人 —— 它【已经】没有人批得动。
    -- 一次无害的门槛微调(1000 → 1001)会让闸把每一张在途单据重新判一遍。
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approval_threshold_base = 1001;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'APPROVALS_POLICY_WOULD_STRAND|FX205-C-L2FOR4|2|fx205-l2|decide_expense_claim|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R4b 失败:★ 一张只有它自己的提单人批得动的在途单,应当让策略编辑按名拒并点出 FX205-C-L2FOR4,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ R4c ★ 对照:二级加第二个人 → 同一次编辑放行 ══════════
    INSERT INTO user_roles (user_id, role_id) VALUES (u_cfo, r_l2);
    SELECT count(*) INTO v_n FROM user_roles WHERE user_id = u_cfo AND revoked_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 205R4c 布景失败:u_cfo 持了 % 个角色 —— 它必须【只】持二级那一个(R2f 要它)', v_n; END IF;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_threshold_base = 1001;
    IF (SELECT approval_threshold_base FROM finance_settings) <> 1001 THEN
        RAISE EXCEPTION 'FIXTURE 205R4c 失败:二级有了第二个人之后,那次编辑仍然被拦'; END IF;

    -- ══════════════════════ R2f ★★ 只持二级角色的账号批不了医疗 ══════════════════
    v_msg := NULL; v_denied := false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    BEGIN
        PERFORM decide_medical_claim(mc_cfoown, false, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.decide_hr_requests'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 205R2f 失败:★ 一个只持二级角色的账号批自己的医疗申报应当撞 PERMISSION_DENIED|action.decide_hr_requests —— 例外不放宽任何模块门,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ R5 ★★★ expense_claim_status 只给本人与财务 ══════════════
    -- 本支的四张报销单:E1 一张、E2 一张、E4 两张。
    -- ① 非财务、非主角(对 E1/E2 的单而言)的真身份:u_plain,他只该读到 E4 那两张。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_plain), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF auth.uid() IS DISTINCT FROM u_plain OR current_user <> 'authenticated' THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 205R5 布景失败:身份没有切过去(auth.uid=%, current_user=%)', auth.uid(), current_user; END IF;
    IF has_permission('module.finance.view') THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 205R5 布景失败:u_plain 持 module.finance.view —— 这一臂就不是在测"非财务"了'; END IF;
    SELECT count(*), count(*) FILTER (WHERE employee_id <> e4)
      INTO v_n, v_m FROM expense_claim_status WHERE code LIKE 'FX205-%';
    EXECUTE 'RESET ROLE';
    IF v_n <> 2 OR v_m <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 205R5 失败:★ 非财务读者应当只读到自己的 2 张,实得 % 张,其中别人的 % 张', v_n, v_m; END IF;
    -- ② 对照:财务读者读到全部 4 张(少了它,①证明的可能只是"这张视图谁都读不到")
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_aud), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF auth.uid() IS DISTINCT FROM u_aud THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 205R5 布景失败:auth.uid() 没有切到财务读者'; END IF;
    SELECT count(*) INTO v_n FROM expense_claim_status WHERE code LIKE 'FX205-%';
    EXECUTE 'RESET ROLE';
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 205R5 失败:财务读者应当读到全部 4 张,实得 %', v_n; END IF;
    -- ③ 一个既不持财务、名下也没有报销单的人(u_hr)→ 0 张。
    --   ☞ 与 ① 合起来才说明白谓词的两半:①证"本人那一半放得进",③证"别人的一张都放不进"。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM expense_claim_status WHERE code LIKE 'FX205-%';
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 205R5 失败:一个没有报销单、也不持财务的人应当读到 0 张,实得 %', v_n; END IF;

    RAISE NOTICE 'FIXTURE 205 全部通过:面板点名"他自己的单没人批"且只作忠告(R4a)· 二级批得动一级、一级批不动二级(R1a/R1b)· 二级持有人自己的报销与医疗批得动并被标记,替别人提的照拒、非二级持有人照拒、请假照拒、只持二级角色的账号进不了医疗(R2a–R2f)· 范围 CHECK 拦得住(R2g)· 报表没码就拒、有码读得到恰好那两行(R2h)· WOULD_STRAND 按这一张判、加第二个人就放行(R4b/R4c)· 报销视图只给本人与财务(R5)';
END $$;
ROLLBACK;
