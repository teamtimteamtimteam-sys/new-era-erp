-- db/fixtures/209-the-matrix-moves-the-keys-and-nobody-is-left-without-a-decider.sql
-- ROLE-1 · Batch 1 —— Tim 的角色与审批矩阵(2026-09-23,docs/role-matrix.md)。
--
-- 这一刀把一整族码拆开、把几把钥匙换了人。每一臂问的都是【一把钥匙开不开它该开的那扇门,
-- 以及不开它不该开的那扇】,而且每一臂都带一个【会通过】的对照 —— 否则一个"谁都不许"
-- 的实现能让所有拒绝臂全绿。
--
--   A  重开已关的月 / 年结 / 重开年度:只持 module.finance.edit → PERMISSION_DENIED|action.finance_reopen;
--      持 action.finance_reopen → 重开得了(对照)
--   B  手动锁那扇侧门:直连把锁搬回一个已关的月之前 → REOPEN_THROUGH_CLOSE_ONLY;
--      往回搬【不越线】(撤销一次手动锁)→ 放行(对照)
--   C  加工成本分摊与采购质保金释放改归财务:只持旧码 → PERMISSION_DENIED|module.finance.edit
--   D  人事拆开:只持 action.hr_reviews 决定不了请假;只持 action.decide_hr_requests 开不了评估;
--      只持 module.hr.edit 匿名化不了(→ action.anonymise_employee)
--   E  批评估的门:review_approval_code —— CFO 是主角 / 是提交人 → action.hr_reviews;
--      否则 action.approve_review。端到端一臂:CFO 是主角时,只持 approve_review 的人被拒
--   F  月薪:直连 UPDATE / INSERT 带月薪 / 直连插一行带薪资的履历 → SALARY_DIRECT_WRITE_REFUSED;
--      set_initial_salary 只许一次(第二次 SALARY_ALREADY_SET),没有 data.view_pay 被拒,
--      写了一行 salary_change 履历(old = NULL);批量导入的禁列里有 monthly_salary。
--      ★ 故障注入:关掉那支守卫,同一句直连 UPDATE 就【成功】了 —— 证明 F1 不是空转
--   G  employee_lookup:只持 action.manage_permissions 的人【读得到名字】(SET LOCAL ROLE
--      authenticated 之下),同一会话里一个什么都不持的人读到 0 行(对照)
--
-- 自带数据(README 第 2 条);不继承 locked_before(第 4 条)。
BEGIN;
DO $$
DECLARE
    u_fin    uuid := gen_random_uuid();   -- module.finance.edit + view(财务的日常)
    u_reop   uuid := gen_random_uuid();   -- action.finance_reopen + module.finance.view(CFO)
    u_proc   uuid := gen_random_uuid();   -- module.processing.edit + purchasing.edit(旧码)
    u_rev    uuid := gen_random_uuid();   -- action.hr_reviews + hr.view + view_reviews(cco)
    u_dec    uuid := gen_random_uuid();   -- action.decide_hr_requests + hr.view
    u_hr     uuid := gen_random_uuid();   -- module.hr.edit + hr.view + view_pay(财务的人事那一半)
    u_hrnp   uuid := gen_random_uuid();   -- module.hr.edit + hr.view,【没有】view_pay
    u_appr   uuid := gen_random_uuid();   -- action.approve_review + hr.view + view_reviews
    u_cfo    uuid := gen_random_uuid();   -- 二级审批角色的真持有人(“CFO”)
    u_other  uuid := gen_random_uuid();   -- 普通提交人
    u_adm    uuid := gen_random_uuid();   -- 只持 action.manage_permissions
    u_none   uuid := gen_random_uuid();   -- 什么都不持
    r uuid;
    e_cfo uuid := gen_random_uuid(); e_x uuid := gen_random_uuid(); e_y uuid := gen_random_uuid();
    pr_cfo uuid := gen_random_uuid();
    v_rating text;
    v_m1 date := DATE '2031-01-31'; v_m2 date := DATE '2031-02-28';
    v_msg text; v_denied boolean; v_n integer; v_txt text; v_r jsonb;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_reop, now()), (u_proc, now()), (u_rev, now()), (u_dec, now()),
        (u_hr, now()), (u_hrnp, now()), (u_appr, now()), (u_cfo, now()), (u_other, now()),
        (u_adm, now()), (u_none, now());

    -- 每个人一个角色、恰好那几个码
    FOR v_txt, r IN SELECT * FROM (VALUES
        ('fx209-fin',  u_fin), ('fx209-reop', u_reop), ('fx209-proc', u_proc), ('fx209-rev', u_rev),
        ('fx209-dec',  u_dec), ('fx209-hr',   u_hr),   ('fx209-hrnp', u_hrnp), ('fx209-appr', u_appr),
        ('fx209-cfo',  u_cfo), ('fx209-oth',  u_other), ('fx209-adm', u_adm), ('fx209-none', u_none)) t(c, u) LOOP
        INSERT INTO roles (code, name_en, name_zh, is_active) VALUES (v_txt, 'f', 'f', true);
        INSERT INTO user_roles (user_id, role_id) SELECT r, id FROM roles WHERE code = v_txt;
    END LOOP;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT ro.id, x.code FROM roles ro JOIN (VALUES
        ('fx209-fin',  'module.finance.edit'), ('fx209-fin', 'module.finance.view'),
        ('fx209-reop', 'action.finance_reopen'), ('fx209-reop', 'module.finance.view'),
        ('fx209-proc', 'module.processing.edit'), ('fx209-proc', 'module.processing.view'),
        ('fx209-proc', 'module.purchasing.edit'), ('fx209-proc', 'module.purchasing.view'),
        ('fx209-rev',  'action.hr_reviews'), ('fx209-rev', 'module.hr.view'), ('fx209-rev', 'data.view_reviews'),
        ('fx209-dec',  'action.decide_hr_requests'), ('fx209-dec', 'module.hr.view'),
        ('fx209-hr',   'module.hr.edit'), ('fx209-hr', 'module.hr.view'), ('fx209-hr', 'data.view_pay'),
        ('fx209-hrnp', 'module.hr.edit'), ('fx209-hrnp', 'module.hr.view'),
        ('fx209-appr', 'action.approve_review'), ('fx209-appr', 'module.hr.view'), ('fx209-appr', 'data.view_reviews'),
        ('fx209-cfo',  'module.finance.view'),
        ('fx209-adm',  'action.manage_permissions')) x(role_code, code) ON x.role_code = ro.code;

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_cfo, 'FX209-CFO', 'The CFO',  'full_time', 'office', DATE '2020-01-01', u_cfo),
        (e_x,   'FX209-X',   'X person', 'full_time', 'office', DATE '2020-01-01', u_other),
        (e_y,   'FX209-Y',   'Y person', 'full_time', 'office', DATE '2020-01-01', NULL);

    -- 二级审批角色 = fx209-cfo(直写四列要显式举旗,APR-1);开关保持关着 —— 本支不验路由
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false,
                                approval_level2_role_code = 'fx209-cfo';

    -- ══════════ A · 重开已关的月、年结、重开年度 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    PERFORM close_period(v_m1, 'fixture 209 A 关 m1');
    PERFORM close_period(v_m2, 'fixture 209 A 关 m2');
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM reopen_period(v_m2, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.finance_reopen'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209A 失败:只持 module.finance.edit 的人重开已关的月应当报 PERMISSION_DENIED|action.finance_reopen,实得 %', COALESCE(v_msg,'(重开了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM close_financial_year(DATE '2031-12-31', 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.finance_reopen'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209A 失败:只持 module.finance.edit 的人年结应当报 PERMISSION_DENIED|action.finance_reopen,实得 %', COALESCE(v_msg,'(结了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM reopen_financial_year(DATE '2031-12-31', 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.finance_reopen'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209A 失败:只持 module.finance.edit 的人重开年度应当报 PERMISSION_DENIED|action.finance_reopen,实得 %', COALESCE(v_msg,'(重开了)'); END IF;
    -- 对照:CFO 重开得了,锁回到 m1 的次日
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_reop), true);
    PERFORM reopen_period(v_m2, 'fixture 209 A CFO 重开');
    IF (SELECT locked_before FROM finance_settings) <> v_m1 + 1 THEN
        RAISE EXCEPTION 'FIXTURE 209A 失败:CFO 重开之后锁应当回到 m1 的次日'; END IF;

    -- ══════════ B · 手动锁那扇侧门 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    -- 手动锁往前推到 m2 之后(不关账),再往回撤到 m1 的次日:没越过任何已关的月 → 放行
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE finance_settings SET locked_before = v_m2 + 1;
    UPDATE finance_settings SET locked_before = v_m1 + 1;
    EXECUTE 'RESET ROLE';
    IF (SELECT locked_before FROM finance_settings) <> v_m1 + 1 THEN
        RAISE EXCEPTION 'FIXTURE 209B 失败:撤销一次手动锁(不越过已关的月)应当放行'; END IF;
    -- 越线:清空 / 搬到 m1 之前 → 按名拒
    FOR v_txt IN SELECT unnest(ARRAY['NULL', (v_m1 - 10)::text]) LOOP
        v_denied := false; v_msg := NULL;
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            IF v_txt = 'NULL' THEN
                UPDATE finance_settings SET locked_before = NULL;
            ELSE
                UPDATE finance_settings SET locked_before = v_txt::date;
            END IF;
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            v_msg := SQLERRM; v_denied := (SQLERRM = 'REOPEN_THROUGH_CLOSE_ONLY|' || to_char(v_m1, 'YYYY-MM-DD'));
        END;
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 209B 失败:直连把锁搬到 % 越过了已关的 %,应当报 REOPEN_THROUGH_CLOSE_ONLY,实得 %',
                v_txt, v_m1, COALESCE(v_msg,'(搬过去了)'); END IF;
    END LOOP;

    -- ══════════ C · 分摊与质保金释放归财务 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_proc), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM allocate_processing_costs(gen_random_uuid(), 'weight');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|module.finance.edit'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209C 失败:只持 module.processing.edit 的人分摊加工成本应当报 PERMISSION_DENIED|module.finance.edit,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM release_purchase_order_retention(gen_random_uuid(), 1, 0);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|module.finance.edit'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209C 失败:只持 module.purchasing.edit 的人释放质保金应当报 PERMISSION_DENIED|module.finance.edit,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- 对照:持 module.finance.edit 的人过了门,撞上的是"那一行不存在"(不是权限)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_msg := NULL;
    BEGIN PERFORM allocate_processing_costs(gen_random_uuid(), 'weight');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 209C 失败:持 module.finance.edit 的人不该在权限上被拒,实得 %', v_msg; END IF;

    -- ══════════ D · 人事拆开 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_rev), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decide_leave_request(gen_random_uuid(), false, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.decide_hr_requests'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209D 失败:只持 action.hr_reviews(cco)的人决定请假应当被拒,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decide_medical_claim(gen_random_uuid(), false, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.decide_hr_requests'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209D 失败:只持 action.hr_reviews 的人决定医疗申报应当被拒,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_dec), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM void_review(gen_random_uuid(), 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.hr_reviews'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209D 失败:只持 action.decide_hr_requests 的人动得了评估,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM anonymise_employee(e_y, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.anonymise_employee'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209D 失败:只持 module.hr.edit 的人匿名化员工应当报 PERMISSION_DENIED|action.anonymise_employee,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- 对照:决定码的持有人过得了门(撞上的是"单据不存在")
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_dec), true);
    v_msg := NULL;
    BEGIN PERFORM decide_leave_request(gen_random_uuid(), false, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'REQUEST_NOT_FOUND' THEN
        RAISE EXCEPTION 'FIXTURE 209D 失败:决定码的持有人应当过门、撞上 REQUEST_NOT_FOUND,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ E · 批评估的门 ══════════
    IF review_approval_code(u_other, e_cfo) <> 'action.hr_reviews' THEN
        RAISE EXCEPTION 'FIXTURE 209E 失败:CFO 是主角时应当要 action.hr_reviews,实得 %', review_approval_code(u_other, e_cfo); END IF;
    IF review_approval_code(u_cfo, e_x) <> 'action.hr_reviews' THEN
        RAISE EXCEPTION 'FIXTURE 209E 失败:CFO 是提交人时应当要 action.hr_reviews,实得 %', review_approval_code(u_cfo, e_x); END IF;
    IF review_approval_code(u_other, e_x) <> 'action.approve_review' THEN
        RAISE EXCEPTION 'FIXTURE 209E 失败:一般情形应当要 action.approve_review,实得 %', review_approval_code(u_other, e_x); END IF;
    IF review_approval_code(NULL, NULL) IS DISTINCT FROM 'action.approve_review' THEN
        RAISE EXCEPTION 'FIXTURE 209E 失败:主语缺席(NULL)时应当是一般情形,永不返回 NULL'; END IF;
    -- 端到端:CFO 是主角的一张已提交评估,只持 approve_review 的人批不了
    SELECT code INTO v_rating FROM review_rating_scale ORDER BY code LIMIT 1;
    INSERT INTO performance_reviews
        (id, employee_id, review_type, period_start, period_end, reviewer_employee_id,
         status, rating_code, summary_text, probation_outcome, submitted_at, submitted_by) VALUES
        (pr_cfo, e_cfo, 'probation', DATE '2030-01-01', DATE '2030-03-01', e_x,
         'submitted', v_rating, 's', 'not_confirm', now(), u_other);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_appr), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM approve_review(pr_cfo);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.hr_reviews'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209E 失败:CFO 自己的评估应当由 cco 批 —— 只持 approve_review 的人应当报 PERMISSION_DENIED|action.hr_reviews,实得 %', COALESCE(v_msg,'(批了)'); END IF;
    -- 对照:cco(action.hr_reviews)批得了
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_rev), true);
    PERFORM approve_review(pr_cfo);
    IF (SELECT status FROM performance_reviews WHERE id = pr_cfo) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 209E 失败:cco 批 CFO 的评估应当成功'; END IF;

    -- ══════════ F · 月薪 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    -- F1 直连 UPDATE
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        UPDATE employees SET monthly_salary = 9999 WHERE id = e_x;
        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SALARY_DIRECT_WRITE_REFUSED');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209F1 失败:直连改月薪应当报 SALARY_DIRECT_WRITE_REFUSED,实得 %', COALESCE(v_msg,'(改了)'); END IF;
    -- F2 直连 INSERT 带月薪
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, monthly_salary)
        VALUES ('FX209-Z', 'Z', 'full_time', 'office', DATE '2020-01-01', 5000);
        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SALARY_DIRECT_WRITE_REFUSED');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209F2 失败:直连建员工带月薪应当报 SALARY_DIRECT_WRITE_REFUSED,实得 %', COALESCE(v_msg,'(建了)'); END IF;
    -- F3 直连插一行带薪资的履历
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO employment_history (employee_id, effective_date, change_type, employment_type, employment_status, new_monthly_salary)
        VALUES (e_x, DATE '2030-01-01', 'salary_change', 'full_time', 'active', 8000);
        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SALARY_DIRECT_WRITE_REFUSED');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209F3 失败:直连插一行调薪履历应当报 SALARY_DIRECT_WRITE_REFUSED,实得 %', COALESCE(v_msg,'(插了)'); END IF;
    -- F4 set_initial_salary:没有 view_pay → 拒
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrnp), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_initial_salary(e_x, 4000, DATE '2030-01-01');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|data.view_pay'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209F4 失败:看不见工资的人录第一份月薪应当报 PERMISSION_DENIED|data.view_pay,实得 %', COALESCE(v_msg,'(录了)'); END IF;
    -- F5 set_initial_salary:一次成功、留痕、第二次拒;生效日必填
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_initial_salary(e_x, 4000, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SALARY_EFFECTIVE_DATE_REQUIRED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209F5 失败:生效日为空应当报 SALARY_EFFECTIVE_DATE_REQUIRED(不给默认),实得 %', COALESCE(v_msg,'(录了)'); END IF;
    v_r := set_initial_salary(e_x, 4000, DATE '2030-01-01', 'fixture 209');
    IF (SELECT monthly_salary FROM employees WHERE id = e_x) <> 4000 THEN
        RAISE EXCEPTION 'FIXTURE 209F5 失败:第一份月薪没有落到 employees 上'; END IF;
    SELECT count(*) INTO v_n FROM employment_history
     WHERE employee_id = e_x AND change_type = 'salary_change'
       AND old_monthly_salary IS NULL AND new_monthly_salary = 4000;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 209F5 失败:第一份月薪应当恰好留一行 salary_change 履历(old = NULL),实得 %', v_n; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_initial_salary(e_x, 4500, DATE '2030-02-01');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SALARY_ALREADY_SET|FX209-X'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 209F5 失败:第二次录月薪应当报 SALARY_ALREADY_SET —— 之后的变动走评估或调薪申请,实得 %', COALESCE(v_msg,'(改了)'); END IF;
    -- F6 批量导入的禁列
    IF NOT ('monthly_salary' = ANY (master_import_forbidden_columns())) THEN
        RAISE EXCEPTION 'FIXTURE 209F6 失败:master_import_forbidden_columns 里没有 monthly_salary —— 一份员工 CSV 就能绕过整条规矩'; END IF;
    -- ★ 故障注入:关掉守卫,同一句直连 UPDATE 就成功了 —— F1 不是空转
    ALTER TABLE employees DISABLE TRIGGER trg_employees_salary_write;
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE employees SET monthly_salary = 9999 WHERE id = e_x;
    EXECUTE 'RESET ROLE';
    ALTER TABLE employees ENABLE TRIGGER trg_employees_salary_write;
    IF (SELECT monthly_salary FROM employees WHERE id = e_x) <> 9999 THEN
        RAISE EXCEPTION 'FIXTURE 209F 注入 失败:关掉守卫之后直连 UPDATE 仍然没改 —— 那么 F1 的拒绝不是这支守卫给的,这一臂在空转'; END IF;

    -- ══════════ G · employee_lookup:系统管理员读得到名字 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM employee_lookup WHERE code LIKE 'FX209-%';
    EXECUTE 'RESET ROLE';
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 209G 失败:只持 action.manage_permissions 的人应当读得到 3 个名字(账号↔员工关联要用),实得 %', v_n; END IF;
    -- 对照:同一会话里,什么都不持的人读到 0 行
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM employee_lookup WHERE code LIKE 'FX209-%';
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 209G 失败:什么都不持的人不该读到任何名字,实得 %', v_n; END IF;

    RAISE NOTICE 'FIXTURE 209 全部通过';
END $$;
ROLLBACK;
