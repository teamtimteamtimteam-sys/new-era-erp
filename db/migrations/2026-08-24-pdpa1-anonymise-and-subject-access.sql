-- 2026-08-24-pdpa1-anonymise-and-subject-access.sql
-- PDPA-1:两件【只有代码答得了】的义务 —— 当事人查阅,与"目的结束后不再保留"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【范围:两件事,不是一套框架】
-- PDPA 的义务里,**通知/同意**与**泄露通报**是【组织上的】—— 一份合同条款、
-- 一套流程,人去执行。它们在 docs/pdpa.md 里被【点名为组织性的】,
-- 而不是留在那里看起来像代码盖住了。
-- **只有两件事一份政策文件答不了:**
--   ① 有人要一份自己的数据 → 得导得出来;
--   ② 有人要求删除 / 保留期满 → 得真的不再保留。
-- 这支迁移只建这两件。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【与 Doc 2 原则 7 的冲突,以及它是怎么调和的】
-- 原则 7 写着「软删,永不硬删。系统不做任何物理删除」;PDPA 要求目的结束后
-- **不再保留**个人数据。一行软删掉的员工**仍然带着他的身份证号**。
--
-- **调和的办法是【就地匿名化】:把身份列覆盖掉,行留着。**
-- 理由是原则 7 的**目的是可审计**,不是"名字的那几个字节":
-- 外键不断、每一笔过账都还在、历史读得回来 —— 而个人数据不再在那里。
-- 这一条已经写进 docs/as-built-divergences.md 的第 2 条,
-- **免得那一条继续声称系统永不删除,而代码在做一件看起来被它禁止的事。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【保留多久:【没有决定】,而且这支函数拒绝替人决定】
-- 保留期是一个**法律问题** —— 新加坡《雇佣法》与公积金各有各的最短保留年限。
-- 所以这里**不给默认值**:`personal_data_retention_months` 可空、无默认,
-- 而 `anonymise_employee` 在它为空时**按名拒绝**。
--
-- **一个默认值在这里就是一次【由默认值代替人做出的法律表态】。** 宁可拒绝。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 一、保留期:一个必须由人填的参数 ──────────────────────────────────────
ALTER TABLE hr_settings ADD COLUMN IF NOT EXISTS personal_data_retention_months integer
    CHECK (personal_data_retention_months IS NULL OR personal_data_retention_months > 0);

COMMENT ON COLUMN hr_settings.personal_data_retention_months IS
'离职之后,员工个人数据还保留多少个月 —— 到期即可匿名化(PDPA 的"目的结束后不再保留")。

**可空,而且【没有默认值】,这是刻意的。** 这是一个法律问题:新加坡《雇佣法》与
公积金各有各的最短保留年限,而这套系统不该替人回答。`anonymise_employee` 在它为空时
**按名拒绝运行** —— 一个默认值在这里等于让一个数字替人做出法律表态。
Tim 正在拿这个答案;拿到之前这条路是关着的,而它关着的事实是看得见的。';

-- ── 二、匿名化在行上留痕 ──────────────────────────────────────────────────
ALTER TABLE employees ADD COLUMN IF NOT EXISTS anonymised_at timestamptz;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS anonymised_by uuid;

COMMENT ON COLUMN employees.anonymised_at IS
'这一行的身份列被覆盖掉的时刻。NULL = 从来没有匿名化过 —— **不是"刚好没有数据"**。
留在行上而不是另立一张日志表:要证明"已经不再保留"的正是这一行自己。';

-- ── 三、匿名化 ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION anonymise_employee(p_employee_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_months int;
    v_emp    employees%ROWTYPE;
    v_due    date;
BEGIN
    PERFORM require_permission('module.hr.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PDPA_REASON_REQUIRED';
    END IF;

    -- 【没有保留期就【拒绝】,不走任何默认】见本文件抬头:默认值 = 法律表态。
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
        job_title            = NULL,
        user_id              = NULL,          -- 与登录账号解绑
        anonymised_at        = now(),
        anonymised_by        = auth.uid()
    WHERE id = p_employee_id;

    -- 薪资历史也是个人数据。**其余每一张表都只按 employee_id 引用他**,
    -- 身份列一旦从这一行拿掉,那些行就不再指向一个可识别的人(化名化)。
    -- 这条推理写在这里,因为它是"为什么只动两张表"的全部理由。
    UPDATE employment_history
       SET old_monthly_salary = NULL, new_monthly_salary = NULL, notes = NULL
     WHERE employee_id = p_employee_id;

    RETURN jsonb_build_object(
        'employee_code', v_emp.code, 'anonymised_at', now(),
        'retention_months', v_months, 'due_since', v_due, 'reason', p_reason);
END;
$fn$;

COMMENT ON FUNCTION anonymise_employee(uuid, text) IS
'就地匿名化一名【已离职且保留期已满】的员工:覆盖身份列,行留着。

【它拒绝的四件事,每一件都有名字】没有设保留期(PDPA_RETENTION_PERIOD_NOT_SET)·
人还在职(PDPA_EMPLOYEE_NOT_SEPARATED)· 保留期没满(PDPA_RETENTION_NOT_ELAPSED)·
已经匿名过(PDPA_ALREADY_ANONYMISED)。

**第一条最要紧:保留期是法律问题,这支函数不替人回答,也不用默认值替人回答。**';

-- ── 四、当事人查阅:把"关于我的数据"导出来 ────────────────────────────────
CREATE OR REPLACE FUNCTION export_my_personal_data()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
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
                'job_title', v_emp.job_title, 'hire_date', v_emp.hire_date,
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
$fn$;

COMMENT ON FUNCTION export_my_personal_data() IS
'当事人查阅:把【关于调用者自己】的个人数据导成一份 jsonb。**没有参数** —— 它拿不到别人的。

【不含什么,以及为什么】绩效评估的**正文**不在里面:PDPA 对评价性用途有豁免,
而它怎么适用是一个**法律判断**,不是一次设计选择。这里只给存在性与时间,
并在 docs/pdpa.md 里把它记成待决 —— 而不是替人决定,也不是默默省掉。

【只覆盖员工,不覆盖往来户联系人】customers.contact_person / email / phone
**同样是个人数据、同样有这些权利**,但它们的形状不同(一名员工横跨十几张表,
一个联系人只在一张),而且今天没有任何一个真实请求。记在 docs/pdpa.md。';

-- ── 五、遮蔽表加列是【三件事,一支迁移】────────────────────────────────────
-- 【这一节是补上的,而缺了它这支迁移会【绿着上线、红在闸上】】
-- employees 是列清单式 SELECT 授权的遮蔽表,而且有 employees_masked 伴生视图。
-- AGENTS.md「Adding a column to a masked table」那一条:列清单式 SELECT 授权
-- **不会**随 ADD COLUMN 自动延伸(表级 INSERT/UPDATE 会 —— 这个不对称就是全部陷阱),
-- 而 gate 的 colgrant 判据是
--     (NOT granted AND NOT in_view) OR (has_view AND NOT in_view)
-- —— **一张表一旦有了 _masked 伴生视图,它的每一列都必须在那个视图里,给不给授权都一样。**
-- 所以上面第二节那两个 ADD COLUMN 只是三件事里的第一件。WO-1a 把三件拆成三支迁移,
-- **每一步单独看都像做完了**,而闸一直是红的。这里三件在同一支里。
--
-- 【两列都授权,因为两列都不敏感】anonymised_at 是"这一行还保不保有个人数据",
-- anonymised_by 是操作人的 uuid —— 都不是个人数据本身。刻意【不】藏进遮蔽:
-- 一个人必须看得见"这一行已经匿名过了",否则他会把那些空列当成【漏填】,
-- 然后动手去补 —— 那正是这支迁移要防的事。
GRANT SELECT (anonymised_at, anonymised_by) ON public.employees TO authenticated;

-- 【新列只能追加在视图【末尾】】CREATE OR REPLACE VIEW 不许改动既有列的名字、
-- 类型与次序,新列一律追加。所以这两列排在三个年假派生列之后,而不是按 attnum
-- 插在 review_exempt 后面 —— 视图的列序与表的 attnum 本来就不必一致。
-- 【刻意不 DROP 再建】DROP 会连带打断依赖它的东西,REPLACE 不会。
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
    review_exempt,
        CASE
            WHEN deleted_at IS NULL THEN annual_leave_rate_per_year(id)
            ELSE NULL::numeric
        END AS annual_leave_rate_days,
        CASE
            WHEN deleted_at IS NULL THEN accrued_annual_leave(id)
            ELSE NULL::numeric
        END AS annual_leave_accrued_days,
        CASE
            WHEN deleted_at IS NULL THEN (leave_balance_internal(id, 'annual'::text) ->> 'available'::text)::numeric
            ELSE NULL::numeric
        END AS annual_leave_available_days,
    anonymised_at,
    anonymised_by
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

COMMIT;
