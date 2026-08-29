-- KPI-1 fu3:三支还在读 employees.job_title 的函数,跟着改。
--
-- 【它们是 gate 帮我数出来的,不是我事先想全的】主迁移之后 gate 报了四个红 fixture,
-- 而红的原因都是同一件事:employees.job_title 没了,而这三支函数还在读它。
--   · anonymise_employee —— 清个人数据时清的那一列
--   · approve_review     —— 转正/调薪时写任职履历
--   · export_my_personal_data —— 导出个人数据
-- 【处置各不相同,而差别正是本刀的主题】
--   匿名化清的是【职位指针】(position_id):职位本身是主数据不是个人数据,
--   但"这一行的人曾经担任 X"仍然是关于那个人的事实;
--   而 approve_review 写履历时存的是【当时那个职位的名称文本】——
--   履历是快照,不该变成指针,否则删一个职位就改写了一段发生过的履历。
BEGIN;
-- db/functions/anonymise_employee.sql
-- PDPA 的"目的结束后不再保留":把一名【已离职且保留期已满】的员工就地匿名化 ——
-- 覆盖身份列,行留着。与 Doc 2 原则 7 的调和见 docs/as-built-divergences.md 第 2 条;
-- 范围、待决项与那条法律问题见 docs/pdpa.md。
--
-- 【四条按名拒绝】PDPA_RETENTION_PERIOD_NOT_SET(最要紧的一条:保留期是法律问题,
-- 这支函数不用默认值替人回答;而 2026-08-24 的裁定让它成为【今天唯一走得到】的
-- 那一条 —— 其余三条在这条裁定之下永远到不了)· PDPA_EMPLOYEE_NOT_SEPARATED
-- · PDPA_RETENTION_NOT_ELAPSED · PDPA_ALREADY_ANONYMISED。证据在 db/fixtures/126。
--
-- ★★ 【这支函数将不会被使用 —— 而这是一个决定,不是一件没做完的活】(Tim,2026-08-24)★★
-- 本函数存在、正确、有 fixture 覆盖,而在 Tim 2026-08-24 的裁定之下【将不会被使用】:
--   **员工个人数据无限期保留。没有保留期,而且不会有。**
-- 它因 hr_settings.personal_data_retention_months 为 NULL 而按名拒绝
-- (PDPA_RETENTION_PERIOD_NOT_SET),而在这条裁定之下那一列【保持 NULL】。
-- 它是一件【建好了、刻意休眠】的机制,不是没做完的活。
--
-- 【不要删掉它,不要放宽这条拒绝,不要设一个期限。】那句拒绝正是这次休眠诚实的地方 ——
-- 路是关着的,而且它说得出自己为什么关着。裁定哪天改口,把那一列设上就是全部的改动。
-- 裁定本身、它没有 settle 掉的东西(保留限制仍是 PDPA 的义务,无限期保留是公司
-- 采取的立场,不是本系统给出的豁免)、以及待决清单里它从 OPEN 变成 DECIDED 的那一行,
-- 都在 docs/pdpa.md 第二节与第五节。
--
-- 【它动两张表】employees 的身份列,与 employment_history 的薪资两列 + 备注。
-- 后者是【不可变】的表 —— 匿名化是它唯一的 UPDATE 例外,而那条例外由行的形状定义
-- (见 db/tables/employment_history.sql 里的 reject_employment_history_mutation)。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql;
--       fixed by db/migrations/2026-08-24-pdpa1-fu-the-immutable-log-gets-one-named-exception.sql
--       (第一版在真实数据上必崩:履历不可变,而它有一句 UPDATE)。

CREATE OR REPLACE FUNCTION public.anonymise_employee(p_employee_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_months int;
    v_emp    employees%ROWTYPE;
    v_due    date;
BEGIN
    PERFORM require_permission('module.hr.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PDPA_REASON_REQUIRED';
    END IF;

    -- 【没有保留期就【拒绝】,不走任何默认】默认值 = 一次法律表态。
    SELECT personal_data_retention_months INTO v_months FROM hr_settings LIMIT 1;
    IF v_months IS NULL THEN
        RAISE EXCEPTION 'PDPA_RETENTION_PERIOD_NOT_SET';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    -- 【在职的人不许匿名化】目的还没有结束 —— 那不是合规,那是把在用的数据毁掉。
    IF v_emp.separation_date IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_SEPARATED|%', v_emp.code;
    END IF;
    v_due := (v_emp.separation_date + make_interval(months => v_months))::date;
    IF v_due > CURRENT_DATE THEN
        RAISE EXCEPTION 'PDPA_RETENTION_NOT_ELAPSED|%|%', v_emp.code, v_due;
    END IF;

    -- 【覆盖身份列;结构性的列留着】
    -- 留下的那些(编号、雇佣类型、工种、入离职日、部门)**不指向一个人** ——
    -- 它们是让总账、历史与统计还读得懂所必需的,而原则 7 要的正是这个。
    UPDATE employees SET
        legal_name           = 'ANONYMISED ' || code,
        preferred_name       = NULL,
        identity_no          = NULL,
        work_email           = NULL,
        work_phone           = NULL,
        work_pass_no         = NULL,
        work_pass_type       = NULL,
        work_pass_issue_date = NULL,
        work_pass_expiry_date= NULL,
        residency_status     = NULL,
        monthly_salary       = NULL,
        notes                = NULL,
        separation_notes     = NULL,
        -- KPI-1:employees.job_title 已删,清的是【职位指针】。
        -- 【为什么职位也要清】职位本身是主数据、不是个人数据,但"这一行的人
        -- 曾经担任 CFO"仍然是一条关于那个人的事实 —— 匿名化要断掉的正是这种关联。
        -- **employment_history 上那一行不动**(那是不可变的履历,见 fixture 126)。
        position_id          = NULL,
        user_id              = NULL,          -- 与登录账号解绑
        anonymised_at        = now(),
        anonymised_by        = auth.uid()
    WHERE id = p_employee_id;

    -- 薪资历史也是个人数据。**其余每一张表都只按 employee_id 引用他**,
    -- 身份列一旦从这一行拿掉,那些行就不再指向一个可识别的人(化名化)。
    -- 【anonymised_at 必须一起写】—— 它是不可变守卫认得出这个形状的凭据,
    -- 也是 salary_change 行有权不说新薪资的凭据。少了它,这句 UPDATE 会被守卫
    -- 拒掉,而那正是 fixture 126 抓到的那一幕。
    UPDATE employment_history
       SET old_monthly_salary = NULL,
           new_monthly_salary = NULL,
           notes              = NULL,
           anonymised_at      = now()
     WHERE employee_id = p_employee_id
       AND anonymised_at IS NULL;

    RETURN jsonb_build_object(
        'employee_code', v_emp.code, 'anonymised_at', now(),
        'retention_months', v_months, 'due_since', v_due, 'reason', p_reason);
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_period   text;
    v_old_sal  numeric;
    v_conf     date;
    v_confirmed boolean := false;
    v_salaried  boolean := false;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    -- 【提交人不能自批】四眼原则。与"评估人不能是本人"是两条不同的规则:
    -- 一条防自我评价,这一条防自我批准。
    IF v_r.submitted_by IS NOT NULL AND v_r.submitted_by = auth.uid() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = v_r.employee_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    UPDATE performance_reviews
    SET status = 'approved', approved_at = now(), approved_by = auth.uid()
    WHERE id = p_review_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'approved', NULL, NULL);

    -- ── 试用期转正 ────────────────────────────────────────────────────────
    IF v_r.review_type = 'probation' AND v_r.probation_outcome = 'confirm' THEN
        IF v_emp.employment_status = 'separated' THEN
            RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
        END IF;
        v_conf := COALESCE(v_emp.probation_end_date, CURRENT_DATE);

        UPDATE employees
        SET employment_status = 'active',      -- 【没有 'confirmed' 这个状态,见文件头 (2)】
            confirmation_date = v_conf
        WHERE id = v_emp.id;

        -- 【恰好一行】履历。
        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, notes)
        VALUES (v_emp.id, v_conf, 'confirmed',
                -- KPI-1:履历存的是【当时那个职位的名称文本】,不是指针
                (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id),
                v_emp.department_id,
                v_emp.employment_type, 'active',
                format('Probation confirmed by performance review %s', p_review_id));

        -- 【假期台账一个字都不写】年假的解锁是读时按 employment_status 派生的
        -- (submit_leave_request 的 PROBATION_NO_ANNUAL_LEAVE)。在这里补一笔授予
        -- 就是 HR-2a 结转重复计数的翻版。见文件头 (1)。
        v_confirmed := true;
    END IF;

    -- ── 不予转正:【什么都不改】 ──────────────────────────────────────────
    -- 决定记在评估单据上,提醒由 hr_alerts 的 probation_not_confirmed 一支发出。
    -- 【绝不把在职状态改成 separated,也绝不触发任何离职逻辑】——
    -- 离职是手工流程:人一旦 separated 就掉出工资表,而最后一个月的工资还没录。
    -- 先掉出去,那笔钱就再也发不出来了。

    -- ── 调薪 ──────────────────────────────────────────────────────────────
    IF v_r.new_monthly_salary IS NOT NULL THEN
        -- payroll_periods 没有起止两列:周期就是 period_month 那个整月(见文件头 (4))
        SELECT p.code INTO v_period
        FROM payroll_periods p
        WHERE p.deleted_at IS NULL AND p.status = 'posted'
          AND v_r.salary_effective_date >= p.period_month
          AND v_r.salary_effective_date < (p.period_month + interval '1 month')::date
        ORDER BY p.period_month
        LIMIT 1;

        IF v_period IS NOT NULL THEN
            -- 【连同上面的转正一起回滚】总账已经认了那个月的工资,
            -- 追改一个已过账周期里的薪酬会让账实不符。
            RAISE EXCEPTION 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|%', v_period;
        END IF;

        v_old_sal := v_emp.monthly_salary;

        UPDATE employees SET monthly_salary = v_r.new_monthly_salary WHERE id = v_emp.id;

        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes)
        SELECT e.id, v_r.salary_effective_date, 'salary_change',
               (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
               e.employment_type, e.employment_status, v_old_sal, v_r.new_monthly_salary,
               format('Salary change approved with performance review %s', p_review_id)
        FROM employees e WHERE e.id = v_emp.id;

        v_salaried := true;
    END IF;

    RETURN jsonb_build_object(
        'review_id', p_review_id, 'status', 'approved',
        'employee_code', v_emp.code,
        'review_type', v_r.review_type,
        'probation_outcome', v_r.probation_outcome,
        'confirmed', v_confirmed,
        'confirmation_date', v_conf,
        'salary_changed', v_salaried,
        'old_monthly_salary', v_old_sal,
        'new_monthly_salary', v_r.new_monthly_salary,
        'salary_effective_date', v_r.salary_effective_date);
END;
$function$;
-- db/functions/export_my_personal_data.sql
-- PDPA 的当事人查阅:把【关于调用者自己】的个人数据导成一份 jsonb。
-- **没有参数** —— 它拿不到别人的。SECURITY DEFINER 只用来越过列级遮蔽,
-- 不用来放宽主语(遮蔽保护的是"别人看不到",不是"他自己看不到")。
--
-- 【不含绩效评估的正文】PDPA 对评价性用途(evaluative purpose)有豁免,而它怎么
-- 适用是一个【法律判断】。所以只给存在性与时间,并在返回的 note 里【对当事人说出来】——
-- 一次沉默的省略与一次说明了的排除不是一回事。
-- 【范围只到员工】往来户联系人的个人数据在库里,而这条路不通向它们。两条都记在
-- docs/pdpa.md,本文件不复述。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql.

CREATE OR REPLACE FUNCTION public.export_my_personal_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_emp employees%ROWTYPE;
BEGIN
    -- 【它只导出【调用者自己】的数据】—— 没有参数,拿不到别人的。
    SELECT * INTO v_emp FROM employees WHERE user_id = auth.uid() AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_NO_EMPLOYEE_RECORD';
    END IF;

    RETURN jsonb_build_object(
        'generated_at', now(),
        'about', jsonb_build_object(
            'employee_code', v_emp.code, 'legal_name', v_emp.legal_name,
            'preferred_name', v_emp.preferred_name, 'identity_no', v_emp.identity_no,
            'work_email', v_emp.work_email, 'work_phone', v_emp.work_phone,
            'residency_status', v_emp.residency_status,
            'work_pass', jsonb_build_object('type', v_emp.work_pass_type, 'number', v_emp.work_pass_no,
                'issued', v_emp.work_pass_issue_date, 'expires', v_emp.work_pass_expiry_date),
            'employment', jsonb_build_object('type', v_emp.employment_type,
                'category', v_emp.work_category, 'status', v_emp.employment_status,
                'job_title', (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id), 'hire_date', v_emp.hire_date,
                'confirmation_date', v_emp.confirmation_date,
                'separation_date', v_emp.separation_date, 'separation_type', v_emp.separation_type),
            'monthly_salary', v_emp.monthly_salary),
        'employment_history', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.effective_date)
            FROM employment_history h WHERE h.employee_id = v_emp.id), '[]'::jsonb),
        'leave_requests', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.created_at)
            FROM leave_requests l WHERE l.employee_id = v_emp.id), '[]'::jsonb),
        'medical_claims', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.created_at)
            FROM medical_claims m WHERE m.employee_id = v_emp.id), '[]'::jsonb),
        'payroll_lines', COALESCE((SELECT jsonb_agg(to_jsonb(pl) ORDER BY pl.created_at)
            FROM payroll_lines pl WHERE pl.employee_id = v_emp.id), '[]'::jsonb),
        -- 【绩效评估的【正文】刻意不在这里,而这是一个【法律】问题不是设计问题】
        -- PDPA 对"评价性用途"(evaluative purpose)有豁免,而这一份导出要不要
        -- 包含评估的书面结论,取决于那条豁免怎么适用 —— 那不是我能裁的。
        -- 所以这里只给【存在性与时间】,正文留白,并在 docs/pdpa.md 里点名为待决。
        'performance_reviews_metadata_only', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'review_type', r.review_type, 'period_start', r.period_start,
                'period_end', r.period_end, 'status', r.status) ORDER BY r.period_start)
            FROM performance_reviews r WHERE r.employee_id = v_emp.id), '[]'::jsonb),
        'note', 'Performance review content is deliberately excluded pending a legal view on the PDPA evaluative-purpose exemption. See docs/pdpa.md.');
END;
$function$;

COMMIT;
