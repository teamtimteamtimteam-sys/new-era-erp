-- db/tables/employees.sql
-- 员工主档。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列 / RESTRICTED-ACCESS COLUMNS】
-- ════════════════════════════════════════════════════════════════════════════
-- 受《个人数据保护法》(PDPA)与公司手册约束,权限切次按这张单子设列级/角色策略:
--   identity_no    身份证 / 护照号
--   work_pass_no   工作准证号
--   work_email     办公邮箱(可定位到个人)
--   work_phone     办公电话(可定位到个人)
--   monthly_salary 月固定工资总额(HR-3a 新增;HR-3b 重新定义,归 data.view_pay)
-- 【monthly_salary 与 payroll_lines 是两个事实】:本列是【合同底薪 + 固定经常性津贴】,
-- 不含加班、奖金、AWS、佣金与报销 —— 即 MOM 的 "gross rate of pay" 口径,是假期补偿
-- 及其它法定计算的取数来源;payroll_lines.gross_pay 是外包服务商算出的当期实发口径。
-- 本列【不参与任何一次工资计算】,只由 approve_review 在批准带调薪的评估时更新,
-- 并留痕于 employment_history 的 old_/new_monthly_salary。
-- 【两者之间刻意没有自动对账】—— 它们设计上就是两个数,互相不是对方的校验对象。
--
-- monthly_salary_set 是派生列:【金额敏感,有无不敏感】。hr_alerts 是 SECURITY INVOKER,
-- 直接引用被收回的 monthly_salary 会让整张待办视图对所有人 42501。
-- 【刻意不把敏感列拆到额外的表里】—— 分散只会让"哪些字段敏感"变含糊、更难管;
-- 集中列明 + 权限层按列控制,是更清楚的做法。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 其它约定:
--   * code 'EMP-YYYY-NNNN' 无缝编号(next_employee_code + BEFORE INSERT 触发器);
--   * work_category(办公室/车间)决定【年假的每月累积费率】—— 费率表在
--     leave_accrual_rates(HR-2c),按月解析;谈定了别的天数就在那张表加一条 override;
--   * manager_id 自引用,环路由 guard_manager_cycle 挡住;
--   * user_id 是【给权限切次预留】的登录账号接口 —— 可空、【不建到 auth 架构的
--     外键】(与较新的表一致,只存 uuid),部分唯一索引保证两名员工不共用一个登录。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.employees (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                 text NOT NULL UNIQUE,  -- gapless 'EMP-YYYY-NNNN'
    legal_name           text NOT NULL,
    preferred_name       text,
    department_id        uuid REFERENCES public.departments (id),
    job_title            text,
    manager_id           uuid REFERENCES public.employees (id),
    employment_type      text NOT NULL
                         CHECK (employment_type IN ('full_time','part_time','internship','contract')),
    work_category        text NOT NULL CHECK (work_category IN ('office','shopfloor')),
    hire_date            date NOT NULL,
    probation_end_date   date,
    employment_status    text NOT NULL DEFAULT 'probation'
                         CHECK (employment_status IN ('probation','active','notice','separated')),
    separation_date      date,
    separation_type      text CHECK (separation_type IN ('resignation','retirement','redundancy','dismissal','contract_expiry')),
    separation_notes     text,
    work_email           text,  -- RESTRICTED
    work_phone           text,  -- RESTRICTED
    residency_status     text CHECK (residency_status IN ('citizen','pr','work_pass')),
    identity_no          text,  -- RESTRICTED
    work_pass_type       text,
    work_pass_no         text,  -- RESTRICTED
    work_pass_issue_date date,
    work_pass_expiry_date date,
    user_id              uuid,  -- 权限切次预留(见文件头)
    notes                text,
    deleted_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid DEFAULT auth.uid(),
    -- ── HR-3a 追加的两列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    confirmation_date    date,     -- 转正日,由 approve_review 写入
    monthly_salary       numeric CHECK (monthly_salary IS NULL OR monthly_salary >= 0),  -- RESTRICTED
    -- ── HR-3b 追加 ───────────────────────────────────────────────────────────
    -- 派生列:是否已录固定工资。可单独授权,金额本身仍只能经 employees_masked 读。
    monthly_salary_set   boolean GENERATED ALWAYS AS (monthly_salary IS NOT NULL) STORED,
    -- 免于年度评估(组织架构顶端)。open_review_cycle 整个跳过 —— 不建评估,也不报"无评估人"。
    review_exempt        boolean NOT NULL DEFAULT false,
    -- 持工作准证的必须有准证类型与到期日 —— 否则到期提醒无从谈起
    CONSTRAINT employees_work_pass_shape CHECK (
        residency_status IS DISTINCT FROM 'work_pass'
        OR (work_pass_type IS NOT NULL AND work_pass_expiry_date IS NOT NULL)
    ),
    -- 离职必须有离职日
    CONSTRAINT employees_separation_shape CHECK (
        employment_status <> 'separated' OR separation_date IS NOT NULL
    ),
    -- 【HR-3a 试用期上限三个月,不可延长】NULL 容忍:probation_end_date 本来就可空,
    -- 没填不等于违规。加约束前查过线上,无一行违反,故未改动过任何数据。
    CONSTRAINT employees_probation_cap CHECK (
        probation_end_date IS NULL
        OR probation_end_date <= (hire_date + interval '3 months')::date
    )
);

CREATE INDEX idx_employees_department ON public.employees (department_id);
CREATE INDEX idx_employees_manager ON public.employees (manager_id);
CREATE INDEX idx_employees_status ON public.employees (employment_status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_employees_user_id ON public.employees (user_id) WHERE user_id IS NOT NULL;

CREATE TRIGGER trg_employees_updated_at
    BEFORE UPDATE ON public.employees
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 编号:取号函数在 db/functions/next_employee_code.sql(同 pricing_formulas 的分工)
CREATE OR REPLACE FUNCTION public.assign_employee_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := next_employee_code(COALESCE(NEW.hire_date, CURRENT_DATE));
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_employees_code
    BEFORE INSERT ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.assign_employee_code();

-- 【年假默认值的触发器已随 HR-2c 删除】24/18 不再是这里的字面量,也不再复制成
-- 每一行的 annual_leave_days —— 费率住在 leave_accrual_rates(生效日期式),
-- 按月累积由 accrued_annual_leave() 逐月解析。一个事实一个家。
-- 汇报关系环路守卫(同 departments 那套上溯法)
CREATE OR REPLACE FUNCTION public.guard_manager_cycle()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_mgr   uuid := NEW.manager_id;
    v_steps integer := 0;
BEGIN
    WHILE v_mgr IS NOT NULL LOOP
        IF v_mgr = NEW.id THEN
            RAISE EXCEPTION 'MANAGER_CYCLE';
        END IF;
        v_steps := v_steps + 1;
        IF v_steps > 50 THEN
            RAISE EXCEPTION 'MANAGER_CYCLE';
        END IF;
        SELECT manager_id INTO v_mgr FROM employees WHERE id = v_mgr;
    END LOOP;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_employees_no_manager_cycle
    BEFORE INSERT OR UPDATE OF manager_id ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.guard_manager_cycle();

ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
CREATE POLICY "employees select by permission"
    ON public.employees
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

CREATE POLICY "employees insert by permission"
    ON public.employees
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "employees update by permission"
    ON public.employees
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit'::text)) WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "employees delete by permission"
    ON public.employees
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 employees_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.employees FROM authenticated, anon;
-- HR-3a:confirmation_date 授回(不敏感);monthly_salary【故意不授】,
-- 直读原始列在 PostgREST 上是 42501,只能经 employees_masked 读。
-- HR-3b:monthly_salary_set 与 review_exempt 同样授回 —— 都不是敏感数据。
GRANT SELECT (id, code, legal_name, preferred_name, department_id, job_title, manager_id, employment_type, work_category, hire_date, probation_end_date, employment_status, separation_date, separation_type, separation_notes, residency_status, work_pass_type, work_pass_issue_date, work_pass_expiry_date, user_id, notes, deleted_at, created_at, created_by, updated_at, updated_by, confirmation_date, monthly_salary_set, review_exempt)
    ON public.employees TO authenticated;

-- cut 4 员工自助:【追加】一条 PERMISSIVE 策略,与既有模块策略【或】起来。
-- 自助是行级的 —— 给普通员工 module.hr.view 会让他看见所有人,那恰好是反的。
CREATE POLICY "employees select own row"
    ON public.employees AS PERMISSIVE FOR SELECT TO authenticated
    USING (id = current_user_employee());

-- HR-3a 部门经理外键。【定在这一侧而不是 departments.sql】—— 两张表互相引用
-- (employees.department_id ↔ departments.manager_employee_id),镜像重放靠拓扑排序,
-- 把环写进任何一个 CREATE TABLE 里都会让排序无解。employees 本来就排在 departments
-- 之后,所以由它补上这条 ALTER。
ALTER TABLE public.departments
    ADD CONSTRAINT departments_manager_employee_id_fkey
    FOREIGN KEY (manager_employee_id) REFERENCES public.employees (id);

-- 列注释:说明写在数据库里,重建出来的库也带着它们(OPS-1 补齐)。
COMMENT ON COLUMN public.employees.confirmation_date IS
    '试用期转正日。由 approve_review 在批准 probation/confirm 的评估时写入;状态同时转为 active。';
COMMENT ON COLUMN public.employees.monthly_salary IS
    'RESTRICTED (data.view_pay). Monthly FIXED gross: contracted basic plus fixed recurring allowances. EXCLUDES overtime, bonus, AWS, commission and reimbursements. This is the MOM "gross rate of pay" basis and is the source for leave encashment and any other statutory computation. It is NOT the provider''s actual gross — that is payroll_lines.gross_pay — and it never feeds a payroll run. 【月固定工资总额】合同底薪 + 固定经常性津贴;不含加班、奖金、AWS、佣金与报销。这是 MOM "gross rate of pay" 口径,是假期补偿及其它法定计算的取数来源。它【不是】服务商算出的实发工资(那是 payroll_lines.gross_pay),也永远不参与任何一次工资计算。';
COMMENT ON COLUMN public.employees.monthly_salary_set IS
    '派生列:monthly_salary 是否已录入。【金额敏感,有无不敏感】—— hr_alerts(SECURITY INVOKER)与列表页要能问"谁还没录",但不该因此拿到金额本身。';
COMMENT ON COLUMN public.employees.review_exempt IS
    '免于年度评估(组织架构顶端)。open_review_cycle 【整个跳过】这些人:不建评估,也不报"没有评估人"。这与"暂时没定评估人"是两回事 —— 后者是待办,前者是决定。';
