-- db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql
-- HR cut 3b:HR-3a 的四处数据层更正。【本切没有界面,界面是 HR-3c】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【第一处更正最重】它改的是【发给离职员工的钱】。
--
-- 更正前:compute_leave_encashment 把【最近一个已过账期间的 payroll_lines.gross_pay】
--   当作月薪基数。那个数字是外包服务商算出来的当期实发口径 —— 里面【含加班、奖金、
--   一次性补发】。于是同一个人,离职月恰好加过班,补偿就凭空变多;这不是政策,
--   是取数取错了地方。
--
-- 更正后:基数取 employees.monthly_salary,并把这一列重新定义为
--   【月固定工资总额】= 合同底薪 + 固定经常性津贴,不含加班/奖金/AWS/佣金/报销。
--   那正是 MOM 的 "gross rate of pay" 口径,也正是法定补偿该用的基数。
--   fixture 第 2 条是本切的立身之本:给同一个人的工资单加一笔加班费,
--   补偿金额必须【一分不动】。动了就说明 B2 没做完。
--
-- 【不做自动对账】monthly_salary 与 payroll_lines.gross_pay 【设计上就是两个数】,
--   前者是合同口径、后者是实发口径。写一条"两者不符就报警"的规则只会天天误报,
--   并且暗示其中一个是另一个的校验对象 —— 它们不是。
--
-- 【不回填】existing 行保持 NULL,由 HR 手工录入。从 gross_pay 回填等于把加班费
--   永久地写进新基数里,那恰好是本切要拔掉的东西。B5 的提醒负责让空值浮上来。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 四处更正:
--   B. 补偿基数迁到 employees.monthly_salary + NULL 守卫 + 空值提醒
--   C. 自评写入路径(HR-3a 漏掉的那条 —— 当时 self_review 状态到得了却没人写得进)
--   D. data.view_reviews:auditor 保留 module.hr.view,但失去评估正文
--   E. 没有评估人的评估(HR-3a 自己的 fixture 里 6 份有 2 份如此)

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- B1. 重新定义 employees.monthly_salary
-- ════════════════════════════════════════════════════════════════════════════
COMMENT ON COLUMN public.employees.monthly_salary IS
    'RESTRICTED (data.view_pay). Monthly FIXED gross: contracted basic plus fixed recurring '
    'allowances. EXCLUDES overtime, bonus, AWS, commission and reimbursements. This is the MOM '
    '"gross rate of pay" basis and is the source for leave encashment and any other statutory '
    'computation. It is NOT the provider''s actual gross — that is payroll_lines.gross_pay — '
    'and it never feeds a payroll run. '
    '【月固定工资总额】合同底薪 + 固定经常性津贴;不含加班、奖金、AWS、佣金与报销。'
    '这是 MOM "gross rate of pay" 口径,是假期补偿及其它法定计算的取数来源。'
    '它【不是】服务商算出的实发工资(那是 payroll_lines.gross_pay),也永远不参与任何一次工资计算。';

-- 【B4:不回填】。这里【刻意没有】任何 UPDATE ... SET monthly_salary = (SELECT gross_pay ...)。
-- 从实发口径回填会把加班费永久地写进固定工资基数里。现有行保持 NULL,由 HR 手工录入,
-- 空着的会被下面 B5 的提醒一直顶在 HR 待办上。

-- 【薪酬"有没有"不是敏感信息,"是多少"才是】。hr_alerts 是 SECURITY INVOKER 视图,
-- 直接在里面引用 monthly_salary 会要求每个调用者都持有该列的列权限 —— 而那一列
-- 恰恰是对所有人收回的,结果是整张待办视图对所有人 42501。
-- 因此把【是否已录入】做成生成列单独授权:金额仍然只能经 employees_masked 读。
ALTER TABLE public.employees
    ADD COLUMN monthly_salary_set boolean
        GENERATED ALWAYS AS (monthly_salary IS NOT NULL) STORED;

COMMENT ON COLUMN public.employees.monthly_salary_set IS
    '派生列:monthly_salary 是否已录入。【金额敏感,有无不敏感】—— hr_alerts(SECURITY INVOKER)'
    '与列表页要能问"谁还没录",但不该因此拿到金额本身。';

-- ════════════════════════════════════════════════════════════════════════════
-- E1. 免评估标记(组织架构顶端的那几个人)
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.employees
    ADD COLUMN review_exempt boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.employees.review_exempt IS
    '免于年度评估(组织架构顶端)。open_review_cycle 【整个跳过】这些人:不建评估,也不报"没有评估人"。'
    '这与"暂时没定评估人"是两回事 —— 后者是待办,前者是决定。';

-- 新列逐列授回(employees 的表级 SELECT 在 cut 2b 已整表收回);monthly_salary 仍不授。
GRANT SELECT (monthly_salary_set, review_exempt) ON public.employees TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- C. 自评:评估表上加一个"自评已定稿"的时点
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.performance_reviews
    ADD COLUMN self_assessment_submitted_at timestamptz;

COMMENT ON COLUMN public.performance_reviews.self_assessment_submitted_at IS
    '员工把自评定稿的时点。非空即锁死:save_self_assessment 不再受理写入,'
    '要重开须由评估人再调一次 open_for_self_assessment。';

GRANT SELECT (self_assessment_submitted_at) ON public.performance_reviews TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- D1. data.view_reviews —— HR-3a 拒绝加它,现在有了加它的理由
-- ════════════════════════════════════════════════════════════════════════════
-- HR-3a 的判断是"没有任何策略会因为它而分叉,加了只是让目录更难读"。那个判断在
-- 当时是对的。现在分叉出现了:auditor 必须【保留 module.hr.view】(它还要审 HR 的
-- 其余部分:员工档案、工资周期、履历、培训),但【不该读到绩效评估的正文】——
-- 那是一个人对另一个人的评价,不是可审计的账。一个权限码正好表达这条界线。
INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_reviews', 'data', 'View performance review content', '查看绩效评估正文',
     'Ratings, written conclusions, self-assessments and goal results in performance reviews',
     '绩效评估中的评级、书面结论、自评与目标结果', 250);

-- D3:给持有 module.hr.edit 的角色 + admin / GM。【不给 auditor】。
INSERT INTO role_permissions (role_id, permission_code)
SELECT DISTINCT r.id, 'data.view_reviews'
FROM roles r
WHERE r.code IN ('admin', 'gm')
   OR EXISTS (SELECT 1 FROM role_permissions rp
              WHERE rp.role_id = r.id AND rp.permission_code = 'module.hr.edit');

-- ── D2. 一般性读取改为 module.hr.view AND data.view_reviews ─────────────────
-- 【评估人与被评估人的两条豁免原样不动,且不依赖新码】:评估人要读自己评的那份,
-- 被评估人要读自己那份已批准的 —— 这两件事与"有没有资格通读全公司的评估"无关。
DROP POLICY "performance_reviews select by permission" ON public.performance_reviews;
CREATE POLICY "performance_reviews select by permission"
    ON public.performance_reviews AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view') AND has_permission('data.view_reviews'));

DROP POLICY "review_goals select by permission" ON public.review_goals;
CREATE POLICY "review_goals select by permission"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view') AND has_permission('data.view_reviews'));

-- D4:review_cycles 与 review_rating_scale 是【配置,不是正文】—— 轮次的名字、
-- 档位的名字本身不泄露任何人的评价,留在 module.hr.view 上不动。

-- ════════════════════════════════════════════════════════════════════════════
-- 遮蔽视图跟着改:属主权限的视图必须把行谓词原样加回(cut 2b 铁律)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW public.performance_reviews_masked WITH (security_invoker = off) AS
 SELECT id,
    employee_id,
    review_type,
    cycle_id,
    period_start,
    period_end,
    reviewer_employee_id,
    status,
    rating_code,
    summary_text,
    self_assessment_text,
    probation_outcome,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN new_monthly_salary
            ELSE NULL::numeric
        END AS new_monthly_salary,
    salary_effective_date,
    submitted_at,
    submitted_by,
    approved_at,
    approved_by,
    acknowledged_at,
    void_reason,
    voided_at,
    voided_by,
    notes,
    created_at,
    created_by,
    updated_at,
    updated_by,
    self_assessment_submitted_at
   FROM performance_reviews
  WHERE (has_permission('module.hr.view'::text) AND has_permission('data.view_reviews'::text))
     OR reviewer_employee_id = current_user_employee()
     OR (employee_id = current_user_employee() AND status IN ('approved','acknowledged'));

-- employees_masked:尾部补两个新列(都不敏感)。只在末尾加列,依赖它的
-- employee_directory 不用动。
CREATE OR REPLACE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
    separation_notes,
    annual_leave_days,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set,
    review_exempt
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

-- ════════════════════════════════════════════════════════════════════════════
-- B2 + B3. 补偿基数迁到 monthly_salary,并加 NULL 守卫
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.compute_leave_encashment(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   record;
    v_bal   jsonb;
    v_days  numeric;
    v_basis numeric;
    v_dpw   numeric;
    v_daily numeric;
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, legal_name, monthly_salary INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 【B3 NULL 守卫】没录固定工资就【报错】,不算 0,也不退回 gross_pay。
    -- 这里是整个切次最要紧的三行:一个静悄悄的 0 会变成一个离职的人少拿的钱,
    -- 而且没有任何人会看见它发生。退回 gross_pay 更糟 —— 那正是本切拔掉的东西,
    -- 一个"兜底"会把它悄悄接回来。
    -- ══════════════════════════════════════════════════════════════════════
    IF v_emp.monthly_salary IS NULL THEN
        RAISE EXCEPTION 'SALARY_NOT_SET|%', v_emp.code;
    END IF;

    v_bal := leave_balance(p_employee_id, 'annual', p_as_of);
    v_days := (v_bal->>'available')::numeric;
    v_basis := v_emp.monthly_salary;

    SELECT working_days_per_week INTO v_dpw FROM hr_settings WHERE id;

    -- 【日薪口径】MOM 对月薪员工的定义:12 × 月薪 ÷ (52 × 每周工作天数)。
    -- 月薪取【固定工资总额】(见 employees.monthly_salary 的注释),不取实发口径。
    -- 【取整规则】先把日薪取到分,再乘天数、再取到分 —— 与财务层"每个分量各自取到分"
    -- 的做法一致(见 allocate_processing_costs 的分摊与余额补差)。日薪是要写在
    -- 结算单上、要被人核对的一个数,所以它先成为一个真实的分值,而不是中间态。
    v_daily := round((12.0 * v_basis) / (52.0 * v_dpw), 2);

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'as_of', p_as_of,
        'unused_days', v_days,
        -- 【键名换了】原来叫 monthly_gross_basis,那个名字现在会误导 ——
        -- "gross" 在本系统里已经专指服务商的实发口径。
        'monthly_fixed_gross_basis', v_basis,
        'basis_source', 'employees.monthly_salary (contracted fixed gross; excludes overtime, bonus, AWS, commission)',
        'daily_rate', v_daily,
        'daily_rate_formula', format('12 x monthly fixed gross / (52 x %s working days per week)', v_dpw),
        'rounding', 'daily rate rounded to 2 dp, then multiplied by days and rounded to 2 dp',
        'indicative_amount', round(v_daily * v_days, 2),
        -- 【这一面旗子是有意放在返回值里的】:调用方看得见"这只是参考,没有入账"
        'journal_posted', false,
        'note', 'Indicative only. Payment is made by the outsourced payroll provider; no journal entry is created by this system.',
        'balance_detail', v_bal);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- PART C. 自评写入路径
-- ════════════════════════════════════════════════════════════════════════════

-- ── C1. open_for_self_assessment ───────────────────────────────────────────
-- 评估人或 HR edit;draft → self_review。已定稿的自评也从这里【重开】
-- (清掉 self_assessment_submitted_at)—— 重开是评估人的决定,不是员工自己能做的。
CREATE OR REPLACE FUNCTION public.open_for_self_assessment(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_reopened boolean := false;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('module.hr.edit')
            OR v_r.reviewer_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    v_reopened := (v_r.status = 'self_review' AND v_r.self_assessment_submitted_at IS NOT NULL);

    UPDATE performance_reviews
    SET status = 'self_review', self_assessment_submitted_at = NULL
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'self_review',
                              'previous_status', v_r.status, 'reopened', v_reopened);
END;
$function$;

-- ── C2. save_self_assessment ───────────────────────────────────────────────
-- 【只有被评估人本人能调】。HR 与评估人【都不行】—— 一份别人代写的自评没有价值,
-- 那正是这份文书唯一的作用所在。所以这里【没有】自助函数惯常的
-- "has_permission('module.hr.edit') OR 本人" 那一半。
--
-- 【写得到什么,是由这个函数的形状决定的,不是由调用方的自觉决定的】:
-- 它只 UPDATE 两个字段(performance_reviews.self_assessment_text 与
-- review_goals.employee_result_text),全是静态 SQL、没有一处动态拼接,
-- 所以 objective_text / reviewer_assessment_text / rating_code / summary_text /
-- probation_outcome / 薪酬两列 / status 【在结构上就够不到】。
--
-- p_goal_results 形如 '[{"goal_id":"<uuid>","result_text":"..."}]'。
-- 每个 goal_id 必须属于本评估,否则 GOAL_NOT_IN_REVIEW。
-- 幂等:起草期间可以反复调用,每次整份覆盖。
CREATE OR REPLACE FUNCTION public.save_self_assessment(p_review_id uuid, p_self_assessment_text text, p_goal_results jsonb DEFAULT NULL::jsonb, p_final boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       performance_reviews%ROWTYPE;
    v_me      uuid := current_user_employee();
    v_el      jsonb;
    v_goal_id uuid;
    v_n       integer := 0;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    -- 本人,且只有本人
    IF v_me IS NULL OR v_r.employee_id IS DISTINCT FROM v_me THEN
        RAISE EXCEPTION 'NOT_REVIEW_SUBJECT';
    END IF;

    IF v_r.status <> 'self_review' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.self_assessment_submitted_at IS NOT NULL THEN
        RAISE EXCEPTION 'SELF_ASSESSMENT_LOCKED|%', v_r.self_assessment_submitted_at;
    END IF;

    IF p_goal_results IS NOT NULL THEN
        IF jsonb_typeof(p_goal_results) <> 'array' THEN
            RAISE EXCEPTION 'GOAL_RESULTS_NOT_ARRAY';
        END IF;
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_goal_results) LOOP
            v_goal_id := (v_el->>'goal_id')::uuid;
            IF v_goal_id IS NULL THEN
                RAISE EXCEPTION 'GOAL_ID_REQUIRED';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM review_goals g
                           WHERE g.id = v_goal_id AND g.review_id = p_review_id) THEN
                RAISE EXCEPTION 'GOAL_NOT_IN_REVIEW|%', v_goal_id;
            END IF;
            UPDATE review_goals
            SET employee_result_text = v_el->>'result_text'
            WHERE id = v_goal_id;
            v_n := v_n + 1;
        END LOOP;
    END IF;

    UPDATE performance_reviews
    SET self_assessment_text = p_self_assessment_text,
        self_assessment_submitted_at = CASE WHEN p_final THEN now() ELSE NULL END
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', v_r.status,
                              'goals_written', v_n, 'final', p_final,
                              'self_assessment_submitted_at',
                              (SELECT self_assessment_submitted_at FROM performance_reviews
                                WHERE id = p_review_id));
END;
$function$;

-- C3:【本切一个字都没有放宽 HR-3a 的读取规则】。被评估人在批准之前仍然读不到自己
-- 那份评估 —— 他是【盲写】进去的,对一份自评而言这恰恰是对的:自评不该被评估人
-- 已经写好的评语带着走。

-- ════════════════════════════════════════════════════════════════════════════
-- PART E. 没有评估人的评估
-- ════════════════════════════════════════════════════════════════════════════

-- ── E2. 默认评估人:部门经理 → 上级部门经理 → NULL ─────────────────────────
CREATE OR REPLACE FUNCTION public.open_review_cycle(p_cycle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c          review_cycles%ROWTYPE;
    v_created    integer;
    v_total      integer;
    v_noreviewer integer;
    v_exempt     integer;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_c FROM review_cycles WHERE id = p_cycle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CYCLE_NOT_FOUND|%', COALESCE(p_cycle_id::text, '?');
    END IF;
    IF v_c.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'CYCLE_NOT_FOUND|%', v_c.name;
    END IF;
    IF v_c.status = 'closed' THEN
        RAISE EXCEPTION 'CYCLE_CLOSED|%', v_c.name;
    END IF;

    WITH ins AS (
        INSERT INTO performance_reviews
            (employee_id, review_type, cycle_id, period_start, period_end,
             reviewer_employee_id, status)
        SELECT e.id, 'annual', v_c.id, v_c.period_start, v_c.period_end,
               -- 【E2 三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理
               -- → 再不行留 NULL(E3 的提醒会把它顶出来,不会悄悄躺着)。
               -- 每一级都排除"解析到本人",因为自己不能评自己(表上的 check 也会拦)。
               COALESCE(
                   NULLIF(d.manager_employee_id, e.id),
                   NULLIF(pd.manager_employee_id, e.id)
               ),
               'draft'
        FROM employees e
        LEFT JOIN departments d  ON d.id = e.department_id
        LEFT JOIN departments pd ON pd.id = d.parent_department_id
        WHERE e.deleted_at IS NULL
          -- 【'active' = 在职且已转正】。probation 与 separated 按题意排除;
          -- 'notice'(在离职通知期内)同样不生成。
          AND e.employment_status = 'active'
          -- 【E1 免评估的整个跳过】不建评估,也就不会有"没有评估人"的提醒。
          AND NOT e.review_exempt
          AND NOT EXISTS (
              SELECT 1 FROM performance_reviews pr
              WHERE pr.employee_id = e.id AND pr.cycle_id = v_c.id AND pr.status <> 'void')
        RETURNING 1
    )
    SELECT count(*) INTO v_created FROM ins;

    UPDATE review_cycles SET status = 'open' WHERE id = p_cycle_id AND status <> 'open';

    SELECT count(*), count(*) FILTER (WHERE reviewer_employee_id IS NULL)
    INTO v_total, v_noreviewer
    FROM performance_reviews WHERE cycle_id = p_cycle_id AND status <> 'void';

    SELECT count(*) INTO v_exempt FROM employees
    WHERE deleted_at IS NULL AND employment_status = 'active' AND review_exempt;

    RETURN jsonb_build_object(
        'cycle_id', p_cycle_id, 'cycle_name', v_c.name, 'status', 'open',
        'created', v_created, 'total_reviews', v_total,
        -- 【故意留在返回值里】没有评估人的份数是要有人去处理的,不是可以忽略的余数。
        'without_reviewer', v_noreviewer,
        'skipped_review_exempt', v_exempt);
END;
$function$;

-- ── E4. set_review_reviewer ────────────────────────────────────────────────
-- HR edit;拒绝自评;补上之后 E3 的提醒【自动消失】(那条提醒是派生的,不是存储的)。
CREATE OR REPLACE FUNCTION public.set_review_reviewer(p_review_id uuid, p_reviewer_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   performance_reviews%ROWTYPE;
    v_rev record;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status = 'void' THEN
        RAISE EXCEPTION 'REVIEW_ALREADY_VOID|%', p_review_id;
    END IF;

    IF p_reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF p_reviewer_employee_id = v_r.employee_id THEN
        RAISE EXCEPTION 'SELF_REVIEW_FORBIDDEN';
    END IF;

    SELECT id, code, employment_status INTO v_rev
    FROM employees WHERE id = p_reviewer_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF v_rev.employment_status = 'separated' THEN
        RAISE EXCEPTION 'REVIEWER_SEPARATED|%', v_rev.code;
    END IF;

    UPDATE performance_reviews
    SET reviewer_employee_id = p_reviewer_employee_id
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id,
                              'reviewer_employee_id', p_reviewer_employee_id,
                              'reviewer_code', v_rev.code,
                              'previous_reviewer', v_r.reviewer_employee_id);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- B5 + E3. hr_alerts 两条新支
-- ════════════════════════════════════════════════════════════════════════════
--   salary_not_set      在册(probation/active/notice)但固定工资未录 —— 这个数现在是
--                       承重的,空着只会在离职那天才浮出来,那时已经来不及悄悄补。
--                       notice 的人给 critical:钱马上就要算了。
--   review_no_reviewer  非作废、未批准的评估没有评估人 —— 在开轮当天就说出来,
--                       好过到了 due_date 才发现,那时已经补不回流程。
--
-- 【为什么用 monthly_salary_set 而不是 monthly_salary IS NULL】本视图是
--   SECURITY INVOKER,引用 monthly_salary 会要求每个调用者持有该列的列权限 ——
--   而那一列对所有人收回,结果会是整张待办视图 42501。生成列把"有没有"与
--   "是多少"分开了。
CREATE OR REPLACE VIEW public.hr_alerts
WITH (security_invoker = on) AS
 SELECT 'work_pass_expiry'::text AS alert_type,
        CASE
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
    e.work_pass_expiry_date AS due_date,
    e.work_pass_expiry_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND e.work_pass_expiry_date IS NOT NULL AND (e.work_pass_expiry_date - CURRENT_DATE) <= 90 AND (e.work_pass_expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
 SELECT 'probation_ending'::text AS alert_type,
        CASE
            WHEN (e.probation_end_date - CURRENT_DATE) <= 14 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text
    AND e.probation_end_date IS NOT NULL
    AND e.probation_end_date >= CURRENT_DATE
    AND (e.probation_end_date - CURRENT_DATE) <= 30
    AND NOT EXISTS (
        SELECT 1 FROM performance_reviews r
        WHERE r.employee_id = e.id AND r.review_type = 'probation'::text
          AND r.status IN ('approved','acknowledged')
          AND r.probation_outcome = 'confirm'::text)
UNION ALL
 SELECT 'probation_overdue'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation ended without a decision'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text
    AND e.probation_end_date IS NOT NULL
    AND e.probation_end_date < CURRENT_DATE
    AND NOT EXISTS (
        SELECT 1 FROM performance_reviews r
        WHERE r.employee_id = e.id AND r.review_type = 'probation'::text
          AND r.status IN ('approved','acknowledged')
          AND r.probation_outcome IS NOT NULL)
UNION ALL
 SELECT 'probation_not_confirmed'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation not confirmed — separation is a manual decision'::text AS subject,
    COALESCE(e.probation_end_date, r.approved_at::date) AS due_date,
    COALESCE(e.probation_end_date, r.approved_at::date) - CURRENT_DATE AS days_remaining
   FROM employees e
     JOIN performance_reviews r ON r.employee_id = e.id
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text
    AND r.review_type = 'probation'::text
    AND r.status IN ('approved','acknowledged')
    AND r.probation_outcome = 'not_confirm'::text
UNION ALL
 SELECT 'salary_not_set'::text AS alert_type,
        CASE WHEN e.employment_status = 'notice'::text THEN 'critical'::text
             ELSE 'warning'::text END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Monthly fixed gross not set — leave encashment cannot be computed'::text AS subject,
    NULL::date AS due_date,
    NULL::integer AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL
    AND e.employment_status IN ('probation','active','notice')
    AND NOT e.monthly_salary_set
UNION ALL
 SELECT 'review_no_reviewer'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(c.name, 'Probation review'::text) || ' — no reviewer assigned'::text AS subject,
    c.due_date AS due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id IS NULL
    AND r.status NOT IN ('approved','acknowledged','void')
    AND e.deleted_at IS NULL
UNION ALL
 SELECT 'review_cycle_overdue'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.name AS subject,
    c.due_date AS due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN review_cycles c ON c.id = r.cycle_id
     JOIN employees e ON e.id = r.employee_id
  WHERE c.deleted_at IS NULL AND c.status = 'open'::text
    AND c.due_date < CURRENT_DATE
    AND r.status IN ('draft','self_review')
UNION ALL
 SELECT 'training_expiry'::text AS alert_type,
        CASE
            WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (t.expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    t.training_name AS subject,
    t.expiry_date AS due_date,
    t.expiry_date - CURRENT_DATE AS days_remaining
   FROM training_records t
     JOIN employees e ON e.id = t.employee_id
  WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer;

COMMIT;
