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
        job_title            = NULL,
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
