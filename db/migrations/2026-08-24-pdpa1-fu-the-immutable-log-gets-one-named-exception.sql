-- 2026-08-24-pdpa1-fu-the-immutable-log-gets-one-named-exception.sql
-- PDPA-1 跟进:**匿名化在第一次真的运行时就崩了。** fixture 126 抓到的,不是推理出来的。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【实测的那一幕】fixture 126 的 E 臂造了一个【涨过薪的离职者】—— 也就是最可能
-- 走到保留期满的那种人 —— 然后调 anonymise_employee。得到的是:
--
--     ERROR: EMPLOYMENT_HISTORY_IMMUTABLE
--     CONTEXT: PL/pgSQL function reject_employment_history_mutation() line 3
--              SQL statement "UPDATE employment_history SET old_monthly_salary = NULL, ..."
--
-- **employment_history 是不可变的**(`trg_employment_history_immutable`,
-- BEFORE UPDATE OR DELETE,无条件 RAISE),而 PDPA-1 的函数里有一句 UPDATE。
-- 于是**任何一个有履历行的员工都匿名化不了 —— 而每个员工入职就有一行**。
-- 那支函数在真实数据上的成功率是【零】,而 PDPA-1 的三道门(预检、colgrant、
-- 库上应用)一道都没有看见它:**它们检查的是结构,而这是一条只在运行时才出现的路。**
--
-- 【第二层,藏在第一层后面】就算放开触发器,还有
-- `employment_history_salary_shape`:change_type='salary_change' 的行【必须】
-- 有 new_monthly_salary。把它置 NULL 会撞上这条 CHECK。
-- **两个缺陷叠在一起,而只有第一个会报错** —— 修掉触发器而不动 CHECK,
-- 换来的是同一支函数在同一条路上换个地方再崩一次。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【处置:不可变【不是】不可匿名化,而这条例外必须是【一个形状】,不是一个开关】
--
-- 一个 `set_config('anonymising','on')` 式的旁路会让"谁都可以在声称自己在匿名化
-- 的时候改历史"。所以这里的例外**由行本身的形状定义**:
--   * 留痕列 anonymised_at 从 NULL 变成非 NULL;
--   * 三个个人数据列(old_/new_monthly_salary、notes)全部变成 NULL;
--   * **其余每一列一字不动**(逐列 IS NOT DISTINCT FROM,白名单式);
--   * DELETE 照旧【永远】拒绝 —— 匿名化不删行,原则 7 的可审计靠的正是那些行还在。
-- 任何别的形状仍然 EMPLOYMENT_HISTORY_IMMUTABLE。
--
-- **这与 employees 那边是同一个调和,只是这次落在一张"更硬"的表上**:
-- 原则 7 要的是【可审计】,而匿名化把可审计留下、把个人数据拿走。
-- 记在 docs/as-built-divergences.md 第 2 条(那一条已经写了 employees 这一侧;
-- 本迁移把履历这一侧补进同一条,不另开一条 —— 同一件事一个家)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 一、履历行上的留痕列(遮蔽表加列 = 三件事,一支迁移)────────────────────
-- employment_history 同样是列清单式 SELECT 授权 + _masked 伴生视图,
-- 所以 ADD COLUMN / GRANT / 视图三件都在这里。见 AGENTS.md
-- 「Adding a column to a masked table」与 gate 的 colgrant 判据。
ALTER TABLE employment_history ADD COLUMN IF NOT EXISTS anonymised_at timestamptz;

COMMENT ON COLUMN employment_history.anonymised_at IS
'这一行的薪资与备注被覆盖掉的时刻。NULL = 从来没有匿名化过。

**它有两个身份,这是刻意的:**既是留痕,也是 `employment_history_salary_shape`
与不可变守卫【认得出匿名化】的凭据 —— 一条 salary_change 行在匿名化之后
说不出新薪资,而它有权不说,因为这一列在。';

-- 不敏感(它不是薪资,是"这一行还保不保有薪资"),所以授权。
GRANT SELECT (anonymised_at) ON public.employment_history TO authenticated;

CREATE OR REPLACE VIEW public.employment_history_masked WITH (security_invoker = off) AS
 SELECT id,
    employee_id,
    effective_date,
    change_type,
    job_title,
    department_id,
    employment_type,
    employment_status,
    notes,
    created_at,
    created_by,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN old_monthly_salary
            ELSE NULL::numeric
        END AS old_monthly_salary,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN new_monthly_salary
            ELSE NULL::numeric
        END AS new_monthly_salary,
    work_category,
    anonymised_at
   FROM employment_history
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();

-- ── 二、调薪行的形状约束:给匿名化一条【有名字】的出口 ──────────────────────
-- 原样保留"调薪行必须说得出新数字",只多一个析取项:**已匿名化的行有权不说。**
ALTER TABLE employment_history DROP CONSTRAINT employment_history_salary_shape;
ALTER TABLE employment_history ADD CONSTRAINT employment_history_salary_shape CHECK (
    change_type <> 'salary_change'
    OR new_monthly_salary IS NOT NULL
    OR anonymised_at IS NOT NULL
);

-- ── 三、不可变守卫:一条例外,由形状定义 ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reject_employment_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 【DELETE 永远拒绝】匿名化不删行 —— 原则 7 的可审计靠的正是那些行还在。
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EMPLOYMENT_HISTORY_IMMUTABLE';
    END IF;

    -- 【唯一允许的 UPDATE:匿名化的那个形状】
    -- 白名单式:每一个不该动的列都逐一断言没动过。刻意【不】写成"只要没动这几列
    -- 就放过" —— 那样将来加一列,新列会默认落在允许改的一侧。
    IF  OLD.anonymised_at IS NULL AND NEW.anonymised_at IS NOT NULL
        AND NEW.old_monthly_salary IS NULL
        AND NEW.new_monthly_salary IS NULL
        AND NEW.notes             IS NULL
        AND NEW.id                = OLD.id
        AND NEW.employee_id       = OLD.employee_id
        AND NEW.effective_date    = OLD.effective_date
        AND NEW.change_type       = OLD.change_type
        AND NEW.created_at        = OLD.created_at
        AND NEW.job_title         IS NOT DISTINCT FROM OLD.job_title
        AND NEW.department_id     IS NOT DISTINCT FROM OLD.department_id
        AND NEW.employment_type   IS NOT DISTINCT FROM OLD.employment_type
        AND NEW.employment_status IS NOT DISTINCT FROM OLD.employment_status
        AND NEW.work_category     IS NOT DISTINCT FROM OLD.work_category
        AND NEW.created_by        IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'EMPLOYMENT_HISTORY_IMMUTABLE';
END;
$fn$;

COMMENT ON FUNCTION public.reject_employment_history_mutation() IS
'任职履历的不可变守卫。DELETE 永远拒绝;UPDATE 只放过【一个形状】—— PDPA 匿名化:
anonymised_at 从 NULL 变成非 NULL、薪资两列与备注全部变 NULL、其余每一列一字不动。

**例外由形状定义,不由开关定义。** 一个"我正在匿名化"的会话标志会让任何人在
声称自己在匿名化的时候改历史;一个形状检查不会 —— 它只允许那一种结果存在。';

-- ── 四、anonymise_employee:带上留痕列 ──────────────────────────────────────
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
$fn$;

COMMENT ON FUNCTION anonymise_employee(uuid, text) IS
'就地匿名化一名【已离职且保留期已满】的员工:覆盖身份列,行留着。

【它拒绝的四件事,每一件都有名字】没有设保留期(PDPA_RETENTION_PERIOD_NOT_SET)·
人还在职(PDPA_EMPLOYEE_NOT_SEPARATED)· 保留期没满(PDPA_RETENTION_NOT_ELAPSED)·
已经匿名过(PDPA_ALREADY_ANONYMISED)。

**第一条最要紧:保留期是法律问题,这支函数不替人回答,也不用默认值替人回答。**

【它动两张表】employees 的身份列,与 employment_history 的薪资两列 + 备注。
后者是一张【不可变】的表 —— 匿名化是它唯一的 UPDATE 例外,而那条例外由行的形状
定义(见 reject_employment_history_mutation 的注释)。证据在 fixture 126。';

COMMIT;
