-- 206 APR-ROUTE-1 · Batch B:【一个人,几个账号】· 【gm 只读】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   L1 ★ 链接要先有主账号:给一个没有主账号的人链额外账号 → ADDITIONAL_NEEDS_PRIMARY
--   L2 ★ 链接成功:落一行史;account_person 与(以那个账号的身份)current_user_employee()
--        都答【那个人】
--   G  ★★ 两道守卫,两个方向:主账号不许进额外表(ACCOUNT_IS_PRIMARY);额外账号不许被设成
--        任何人的主账号 —— 直写 employees.user_id 与走 set_user_employee_link 都拒(ACCOUNT_IS_ADDITIONAL)
--   H  ★★ Tim 的 Q1:一个在 approval_log 里做过决定的账号不许被链(ACCOUNT_HAS_DECISIONS|n)
--   P1 ★★★ 按人认的提单人:人甲用主账号提的报销单,他的第二个账号(二级持有人)去批 →
--        SELF_APPROVAL_FORBIDDEN|raiser。★ 对照:另一个二级持有人批得动
--   P2 ★★ R2 按人记:人甲自己的报销单,他的第二个账号(二级持有人)批 → 成功,self_decided = true
--   P3 ★★ 采购单那两句裸自批按人认:主账号建的在途采购单,第二个账号去驳 → SELF_APPROVAL_FORBIDDEN
--   P4 ★ assert_segregated 按人认:第一步是主账号做的,第二个账号做第二步 → 拒;别人 → 放行
--   V  ★★ 以第二个账号的真身份(SET LOCAL ROLE authenticated):读得到那个人自己的员工行
--        (本人行策略经 current_user_employee),读不到别人的;先证 auth.uid() 切过去了
--   D  ★ user_directory:第二个账号那一行 account_kind = 'additional'、employee_id = 那个人
--   R  ★ 面板(Q3):二级 3 个账号、2 个人 —— 两个数都在,而且不相等
--   U  ★★ 解除(Q2):落第二行史;account_person 变回 NULL;P2 那一行 self_decided【仍然是 true】;
--        而它在链接期间做过决定,所以再链一次 → ACCOUNT_HAS_DECISIONS
--   M  ★★ gm 只读:引导里的 gm 没有任何 *.edit / action.*,读码都在;一个只持 gm 的人
--        决定请假 → PERMISSION_DENIED|module.hr.edit;建任务 → 被 RLS 拒(连个人任务也建不了)
--
-- 自带数据(README 第 2 条);审批策略自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_main   uuid := gen_random_uuid();   -- 人甲的主账号(一级持有人 + 管权限 + 人事)
    u_second uuid := gen_random_uuid();   -- 人甲的第二个账号(二级持有人)
    u_l2b    uuid := gen_random_uuid();   -- 人乙:另一个二级持有人 —— 对照
    u_dec    uuid := gen_random_uuid();   -- 一个做过决定、还没关联任何人的账号(H)
    u_gm     uuid := gen_random_uuid();   -- 只持 gm
    r_l1 uuid; r_l2 uuid; r_adm uuid; r_hr uuid; r_gm uuid;
    e_a uuid := gen_random_uuid();        -- 人甲
    e_b uuid := gen_random_uuid();        -- 人乙
    e_c uuid := gen_random_uuid();        -- 人丙:报销单的主角(别人)
    e_nop uuid := gen_random_uuid();      -- 没有主账号的人
    c_forc  uuid := gen_random_uuid();    -- 人甲提、说的是人丙 —— P1
    c_own   uuid := gen_random_uuid();    -- 人甲提、说的是人甲 —— P2
    c_ctl   uuid := gen_random_uuid();    -- 对照:人甲提、说的是人丙
    po_id   uuid := gen_random_uuid();
    sup_id  uuid := gen_random_uuid();
    lv_id   uuid := gen_random_uuid();
    v_base text;
    v_n integer; v_m integer; v_msg text; v_denied boolean; v_self boolean;
    v_read jsonb; v_kind text; v_emp uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══════════════════════ 布景 ══════════════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_main, now()), (u_second, now()), (u_l2b, now()), (u_dec, now()), (u_gm, now());

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx206-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx206-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx206-adm','f','f',true) RETURNING id INTO r_adm;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx206-hr','f','f',true)  RETURNING id INTO r_hr;
    SELECT id INTO r_gm FROM roles WHERE code = 'gm';
    IF r_gm IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 206 布景失败:引导数据里没有 gm 角色'; END IF;

    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_l1, 'module.finance.view'), (r_l1, 'data.view_prices'), (r_l1, 'module.purchasing.view'),
        (r_l2, 'module.finance.view'), (r_l2, 'data.view_prices'), (r_l2, 'module.purchasing.view'),
        (r_adm, 'action.manage_permissions'), (r_adm, 'module.finance.view'),
        (r_adm, 'module.purchasing.edit'), (r_adm, 'module.suppliers.edit'),
        (r_hr, 'module.hr.edit'), (r_hr, 'module.hr.view'),
        -- ROLE-1(2026-09-23):请假与医疗申报的决定门换成 action.decide_hr_requests
        (r_hr, 'action.decide_hr_requests');

    -- ★ 二级:u_second(人甲)· u_main(人甲)· u_l2b(人乙)= 3 个账号、2 个人(R 臂)
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_main, r_l1), (u_main, r_adm), (u_main, r_hr), (u_main, r_l2),
        (u_second, r_l2), (u_l2b, r_l2), (u_gm, r_gm);

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_a,   'FX206-A',   'Person A',   'full_time', 'office', DATE '2020-01-01', u_main),
        (e_b,   'FX206-B',   'Person B',   'full_time', 'office', DATE '2020-01-01', u_l2b),
        (e_c,   'FX206-C',   'Person C',   'full_time', 'office', DATE '2020-01-01', NULL),
        (e_nop, 'FX206-NOP', 'Nobody',     'full_time', 'office', DATE '2020-01-01', NULL);

    -- 金额一律本位币,一级(< 门槛)—— 这一支验的是"是谁",不是分档
    INSERT INTO expense_claims (id, code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, status, created_by) VALUES
        (c_forc, 'FX206-C-FORC', e_c, DATE '2030-03-01', 50.00, v_base, 'for c', 'none', 'submitted', u_main),
        (c_own,  'FX206-C-OWN',  e_a, DATE '2030-03-01', 50.00, v_base, 'own',   'none', 'submitted', u_main),
        (c_ctl,  'FX206-C-CTL',  e_c, DATE '2030-03-01', 50.00, v_base, 'ctl',   'none', 'submitted', u_main);

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_main), true);
    INSERT INTO suppliers (id, code, legal_name, country, counterparty_type)
      VALUES (sup_id, 'FX206-SUP', 'Sup', 'SG', 'goods_supplier');
    INSERT INTO purchase_orders (id, code, supplier_id, order_date, currency, fx_rate,
                                 estimated_total_ccy, status, approval_status, created_by)
      VALUES (po_id, 'FX206-PO-1', sup_id, DATE '2030-03-01', v_base, 1, 50.00, 'draft', 'pending', u_main);

    -- 策略:两级各有真持有人,门槛 1000,审批【开着】(采购单那两句要它开着才走得到)
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false, approval_level1_role_code = 'fx206-l1',
                                approval_level2_role_code = 'fx206-l2', approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════════════ L1 ★ 链接要先有主账号 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_main), true);
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM link_additional_account(u_second, e_nop);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'ADDITIONAL_NEEDS_PRIMARY|FX206-NOP'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206L1 失败:给没有主账号的人链额外账号应当报 ADDITIONAL_NEEDS_PRIMARY,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ L2 ★ 链接成功 ══════════════════════
    PERFORM link_additional_account(u_second, e_a);
    SELECT count(*) INTO v_n FROM employee_account_history WHERE user_id = u_second AND action = 'linked' AND employee_id = e_a;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 206L2 失败:链接应当正好落一行史,实得 %', v_n; END IF;
    IF account_person(u_second) IS DISTINCT FROM e_a THEN
        RAISE EXCEPTION 'FIXTURE 206L2 失败:account_person(第二个账号) 应当是人甲'; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_second), true);
    IF current_user_employee() IS DISTINCT FROM e_a THEN
        RAISE EXCEPTION 'FIXTURE 206L2 失败:以第二个账号的身份,current_user_employee() 应当是人甲,实得 %', current_user_employee(); END IF;

    -- ══════════════════════ G ★★ 两道守卫,两个方向 ══════════════════════
    v_msg := NULL; v_denied := false;
    BEGIN
        INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_l2b, e_a);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'ACCOUNT_IS_PRIMARY|FX206-B'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206G 失败:一个主账号被直插进额外表应当报 ACCOUNT_IS_PRIMARY,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    v_msg := NULL; v_denied := false;
    BEGIN
        UPDATE employees SET user_id = u_second WHERE id = e_nop;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'ACCOUNT_IS_ADDITIONAL|FX206-A'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206G 失败:把额外账号直写成某人的主账号应当报 ACCOUNT_IS_ADDITIONAL,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_main), true);
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM set_user_employee_link(u_second, e_nop);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'ACCOUNT_IS_ADDITIONAL|FX206-A'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206G 失败:经 set_user_employee_link 把额外账号设成主账号应当报 ACCOUNT_IS_ADDITIONAL,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ H ★★ 做过决定的账号不许被链(Q1)══════════════════════
    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, actor_user_id)
    VALUES ('stocktake', gen_random_uuid(), 'FX206-ST', 'approved', u_dec);
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM link_additional_account(u_dec, e_b);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'ACCOUNT_HAS_DECISIONS|1'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206H 失败:一个做过决定的账号被链应当报 ACCOUNT_HAS_DECISIONS|1,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ P1 ★★★ 按人认的提单人 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_second), true);
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM decide_expense_claim(c_forc, false, NULL, NULL, NULL, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206P1 失败:★ 第二个账号批主账号提的单应当报 |raiser —— 否则同一个人换个账号就绕过了四眼,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- 对照:人乙(另一个二级持有人)批得动同一类单
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l2b), true);
    PERFORM decide_expense_claim(c_ctl, false, NULL, NULL, NULL, '对照');
    SELECT self_decided INTO v_self FROM approval_log WHERE subject_id = c_ctl;
    IF v_self IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 206P1 失败:对照臂应当成功且不是自批,实得 self=%', v_self; END IF;

    -- ══════════════════════ P2 ★★ R2 按人记 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_second), true);
    PERFORM decide_expense_claim(c_own, false, NULL, NULL, NULL, '自己的,用第二个账号拒');
    SELECT self_decided INTO v_self FROM approval_log WHERE subject_id = c_own;
    IF v_self IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 206P2 失败:★ 第二个账号决定它主人自己的报销单,应当成功并标成 self_decided=true,实得 %', v_self; END IF;

    -- ══════════════════════ P3 ★★ 采购单那两句按人认 ══════════════════════
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM reject_purchase_order(po_id, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206P3 失败:第二个账号驳回主账号建的采购单应当报 SELF_APPROVAL_FORBIDDEN,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ P4 ★ assert_segregated 按人认 ══════════════════════
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM assert_segregated('FX206_SOD', ARRAY[u_main], 'subj');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'FX206_SOD|subj'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206P4 失败:第一步是主账号做的,第二个账号做第二步应当被拒,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM assert_segregated('FX206_SOD', ARRAY[u_l2b], 'subj');   -- 别人做的第一步 → 放行

    -- ══════════════════════ V ★★ 第二个账号的真身份:本人行 ══════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF auth.uid() IS DISTINCT FROM u_second OR current_user <> 'authenticated' THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 206V 布景失败:身份没有切过去'; END IF;
    SELECT count(*) FILTER (WHERE id = e_a), count(*) FILTER (WHERE id <> e_a)
      INTO v_n, v_m FROM employees WHERE code LIKE 'FX206-%';
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 OR v_m <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 206V 失败:第二个账号应当读到人甲自己那一行、别人的一行都没有,实得 自己 % / 别人 %', v_n, v_m; END IF;

    -- ══════════════════════ D ★ user_directory ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_main), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT account_kind, employee_id INTO v_kind, v_emp FROM user_directory WHERE user_id = u_second;
    EXECUTE 'RESET ROLE';
    IF v_kind IS DISTINCT FROM 'additional' OR v_emp IS DISTINCT FROM e_a THEN
        RAISE EXCEPTION 'FIXTURE 206D 失败:目录里第二个账号应当是 additional / 人甲,实得 % / %', v_kind, v_emp; END IF;

    -- ══════════════════════ R ★ 面板:账号数与人数(Q3)══════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_read := approvals_readiness();
    EXECUTE 'RESET ROLE';
    IF (v_read->>'level2_real_holders')::int <> 3 OR (v_read->>'level2_people')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 206R 失败:二级应当 3 个账号、2 个人,实得 % / %', v_read->>'level2_real_holders', v_read->>'level2_people'; END IF;

    -- ══════════════════════ U ★★ 解除(Q2)══════════════════════
    PERFORM unlink_additional_account(u_second);
    SELECT count(*) INTO v_n FROM employee_account_history WHERE user_id = u_second;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 206U 失败:链接 + 解除应当是两行史,实得 %', v_n; END IF;
    IF account_person(u_second) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 206U 失败:解除之后第二个账号不该再属于任何人'; END IF;
    SELECT self_decided INTO v_self FROM approval_log WHERE subject_id = c_own;
    IF v_self IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 206U 失败:解除链接不许改过去的 self_decided(那是做决定那一刻的事实)'; END IF;
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM link_additional_account(u_second, e_a);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'ACCOUNT_HAS_DECISIONS|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206U 失败:一个在链接期间做过决定的账号,再链应当报 ACCOUNT_HAS_DECISIONS,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- 史只增不改
    v_msg := NULL; v_denied := false;
    BEGIN
        DELETE FROM employee_account_history WHERE user_id = u_second;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'HISTORY_APPEND_ONLY'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206U 失败:链接史应当只增不改,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ M ★★ gm 只读 ══════════════════════
    SELECT count(*) INTO v_n FROM role_permissions
     WHERE role_id = r_gm AND (permission_code LIKE '%.edit' OR permission_code LIKE 'action.%');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 206M 失败:引导里的 gm 还有 % 个写码 / 动作码', v_n; END IF;
    SELECT count(*) INTO v_n FROM role_permissions
     WHERE role_id = r_gm AND permission_code IN ('module.finance.view', 'module.hr.view', 'data.view_prices',
                                                  'data.view_self_approvals', 'module.tasks.view');
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 206M 失败:gm 应当仍然持那五个读码,实得 %', v_n; END IF;
    INSERT INTO leave_types (code, name_en, name_zh, is_accrued, is_active) VALUES ('fx206-lv', 'f', 'f', false, true);
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by)
      VALUES (lv_id, 'FX206-LV-1', e_c, 'fx206-lv', DATE '2030-03-04', DATE '2030-03-04', 1, 'pending', u_main);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_gm), true);
    v_msg := NULL; v_denied := false;
    BEGIN
        PERFORM decide_leave_request(lv_id, false, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.decide_hr_requests'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206M 失败:只持 gm 的人决定请假应当报 PERMISSION_DENIED|action.decide_hr_requests,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF auth.uid() IS DISTINCT FROM u_gm THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 206M 布景失败:身份没有切到 gm'; END IF;
    v_msg := NULL; v_denied := false;
    BEGIN
        INSERT INTO tasks (title, owner_id) VALUES ('fx206 personal', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLSTATE IN ('42501', 'P0001') OR SQLERRM LIKE '%row-level security%' OR SQLERRM LIKE 'PERMISSION_DENIED%'); END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 206M 失败:只持 gm 的人建任务应当被拒(他从此连个人任务都建不了),实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- 对照:他仍然读得到(一个读码)
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_n := CASE WHEN has_permission('module.finance.view') THEN 1 ELSE 0 END;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 206M 失败:只持 gm 的人应当仍然持 module.finance.view'; END IF;

    RAISE NOTICE 'FIXTURE 206 全部通过:链接要先有主账号、成功落史且两处都认得这个人(L1/L2)· 两道守卫两个方向(G)· 做过决定的账号不许链(H)· 第二个账号批不了主账号提的单、对照批得动(P1)· R2 按人记(P2)· 采购单与职责分离按人认(P3/P4)· 第二个账号只读得到那个人自己的行(V)· 目录说它是 additional(D)· 面板 3 个账号 2 个人(R)· 解除落史、不改旧标记、再链被拒、史不可删(U)· gm 只读:没有写码、决定请假被拒、建任务被拒、读码还在(M)';
END $$;
ROLLBACK;
