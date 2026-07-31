-- db/migrations/2026-08-01-hr1a-hr-core.sql
-- Phase HR-1a: HR core (DB only) —— 员工、部门、任职履历、外包工资导入与过账、
-- 培训记录、到期提醒。
--
-- 【工资是外包的】服务商算好一切,每月每人一行发过来;本系统【只记录结果并过账】,
-- 自己【不计算】CPF、个税或任何一分钱。upsert_payroll_period 唯一做的算术是校验
-- 服务商给的行自洽(net = gross − 员工 CPF − 其它扣款),把录错/解析错的行挡在
-- 总账之外。
--
-- 【本切全部由管理员录入】员工日后会自己登录,但不在这一切:employees.user_id
-- 是给权限切次预留的接口(见 B3 注释),这里只留列不建流程。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列 / RESTRICTED-ACCESS COLUMNS】—— 权限切次照这张单子设策略
-- ════════════════════════════════════════════════════════════════════════════
-- 员工档案里含身份证件号与薪酬,受《个人数据保护法》(PDPA)与公司手册约束。
-- 【刻意不把它们拆到额外的表里】—— 分散只会让"哪些字段敏感"变得含糊,反而更难管;
-- 集中列明、由权限层按列/按角色控制,是更清楚的做法。
--
--   employees.identity_no          身份证 / 护照号
--   employees.work_pass_no         工作准证号
--   employees.work_email           办公邮箱(可定位到个人)
--   employees.work_phone           办公电话(可定位到个人)
--   payroll_lines.gross_pay        个人薪酬
--   payroll_lines.employer_cpf     个人薪酬
--   payroll_lines.employee_cpf     个人薪酬
--   payroll_lines.other_deductions 个人薪酬
--   payroll_lines.net_pay          个人薪酬
--   employee_directory.current_gross_pay / current_pay_period(派生自上述)
--
-- 其余列(姓名、部门、职务、在职状态、入职日等)属于一般员工目录信息。
-- ════════════════════════════════════════════════════════════════════════════
--
-- Pieces:
--   B1. 科目 2400 CPF Payable
--   B2. departments(自引用父级 + 环路守卫)
--   B3. employees(含受限列;休假天数默认按手册;manager 环路守卫;user_id 预留)
--   B4. employment_history(不可变的变更轨迹)
--   B5. payroll_periods / payroll_lines
--   B6. upsert_payroll_period(整批替换 —— 服务商改文件重导要简单)
--   B7. post_payroll_period / unpost_payroll_period
--   B8. training_records
--   B9. 视图 employee_directory / hr_alerts

BEGIN;

-- ============================================================================
-- B1. 科目 2400
-- ============================================================================
-- 员工与雇主两侧的 CPF 都是在发薪时代扣/计提、之后【单独汇给公积金局】的,
-- 所以给它自己的负债科目,而不是混进 2200 应计费用 —— 混在一起就看不出"欠公积金局
-- 多少"这个独立的、有法定缴纳期限的义务。
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_active)
VALUES ('2400', 'CPF Payable', '公积金应付', 'liability', true);

-- 分录来源类型增加 'payroll'
ALTER TABLE public.journal_entries
    DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries
    ADD CONSTRAINT journal_entries_source_type_check CHECK (
        source_type IN ('manual','purchase','sale','processing_cost','allocation',
                        'stocktake','writeoff','payment','fx','expense','prepayment','payroll')
    );

-- ============================================================================
-- B2. departments
-- ============================================================================
CREATE TABLE public.departments (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                 text NOT NULL UNIQUE,
    name_en              text NOT NULL,
    name_zh              text NOT NULL,
    -- 浅层级(部门 → 下属组);环路由触发器挡住
    parent_department_id uuid REFERENCES public.departments (id),
    is_active            boolean NOT NULL DEFAULT true,
    notes                text,
    deleted_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid DEFAULT auth.uid()
);

CREATE INDEX idx_departments_parent ON public.departments (parent_department_id);

CREATE TRIGGER trg_departments_updated_at
    BEFORE UPDATE ON public.departments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on departments"
    ON public.departments AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- 环路守卫:自己不能是自己的(任意层)上级。逐级上溯,撞到自己就拒绝;
-- 同时带一个步数上限,万一历史数据已经成环也不会把这里挂死。
CREATE OR REPLACE FUNCTION public.guard_department_cycle()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_parent uuid := NEW.parent_department_id;
    v_steps  integer := 0;
BEGIN
    WHILE v_parent IS NOT NULL LOOP
        IF v_parent = NEW.id THEN
            RAISE EXCEPTION 'DEPARTMENT_CYCLE';
        END IF;
        v_steps := v_steps + 1;
        IF v_steps > 50 THEN
            RAISE EXCEPTION 'DEPARTMENT_CYCLE';
        END IF;
        SELECT parent_department_id INTO v_parent FROM departments WHERE id = v_parent;
    END LOOP;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_departments_no_cycle
    BEFORE INSERT OR UPDATE OF parent_department_id ON public.departments
    FOR EACH ROW EXECUTE FUNCTION public.guard_department_cycle();

-- 【不预置任何部门】—— 替 Tim 编一份组织架构就是猜。

-- ============================================================================
-- B3. employees
-- 受限访问列见文件头的清单(identity_no / work_pass_no / work_email / work_phone)。
-- ============================================================================
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
    -- 手册按办公室/车间两类给不同的年假基数,故它同时是休假默认值的依据
    work_category        text NOT NULL CHECK (work_category IN ('office','shopfloor')),
    hire_date            date NOT NULL,
    probation_end_date   date,
    employment_status    text NOT NULL DEFAULT 'probation'
                         CHECK (employment_status IN ('probation','active','notice','separated')),
    separation_date      date,
    separation_type      text CHECK (separation_type IN ('resignation','retirement','redundancy','dismissal','contract_expiry')),
    separation_notes     text,
    annual_leave_days    numeric NOT NULL DEFAULT 0 CHECK (annual_leave_days >= 0),
    work_email           text,  -- RESTRICTED
    work_phone           text,  -- RESTRICTED
    residency_status     text CHECK (residency_status IN ('citizen','pr','work_pass')),
    identity_no          text,  -- RESTRICTED
    work_pass_type       text,
    work_pass_no         text,  -- RESTRICTED
    work_pass_issue_date date,
    work_pass_expiry_date date,
    -- 【为权限切次预留】日后员工自助登录时,这一列指向 auth.users。
    -- 刻意【不建到 auth 架构的外键】(与较新的表一致 —— 只存 uuid);
    -- 唯一性靠下面的部分唯一索引:两名员工绝不能共用一个登录账号。
    user_id              uuid,
    notes                text,
    deleted_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid DEFAULT auth.uid(),
    -- 持工作准证的必须有准证类型与到期日 —— 否则到期提醒无从谈起
    CONSTRAINT employees_work_pass_shape CHECK (
        residency_status IS DISTINCT FROM 'work_pass'
        OR (work_pass_type IS NOT NULL AND work_pass_expiry_date IS NOT NULL)
    ),
    -- 离职必须有离职日
    CONSTRAINT employees_separation_shape CHECK (
        employment_status <> 'separated' OR separation_date IS NOT NULL
    )
);

CREATE INDEX idx_employees_department ON public.employees (department_id);
CREATE INDEX idx_employees_manager ON public.employees (manager_id);
CREATE INDEX idx_employees_status ON public.employees (employment_status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_employees_user_id ON public.employees (user_id) WHERE user_id IS NOT NULL;

CREATE TRIGGER trg_employees_updated_at
    BEFORE UPDATE ON public.employees
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on employees"
    ON public.employees AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.next_employee_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('employee_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM employees
    WHERE code LIKE 'EMP-' || v_year::text || '-%';
    RETURN 'EMP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$fn$;

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

-- 年假默认值:手册写的是办公室 24 天、车间 18 天。
-- 【这是默认值,不是约束】—— 只在调用方没给(仍是 0)时套用,谈定了别的天数照样存得进去。
CREATE OR REPLACE FUNCTION public.default_employee_leave_days()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.annual_leave_days = 0 THEN
        NEW.annual_leave_days := CASE NEW.work_category
            WHEN 'office' THEN 24
            WHEN 'shopfloor' THEN 18
            ELSE 0
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_employees_leave_default
    BEFORE INSERT ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.default_employee_leave_days();

-- 汇报关系环路守卫(同部门那套上溯法)
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

-- ============================================================================
-- B4. employment_history
-- 员工【当前】的状态住在 employees 那一行;这张表是"怎么走到今天"的轨迹,
-- 由应用在改动实质字段(职务/部门/用工类型/在职状态)时写入。不可变。
-- ============================================================================
CREATE TABLE public.employment_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id       uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    effective_date    date NOT NULL,
    change_type       text NOT NULL
                      CHECK (change_type IN ('hired','confirmed','promotion','transfer','type_change','status_change','separated')),
    job_title         text,
    department_id     uuid REFERENCES public.departments (id),
    employment_type   text,
    employment_status text,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid()
);

CREATE INDEX idx_employment_history_employee ON public.employment_history (employee_id);

CREATE OR REPLACE FUNCTION public.reject_employment_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'EMPLOYMENT_HISTORY_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_employment_history_immutable
    BEFORE UPDATE OR DELETE ON public.employment_history
    FOR EACH ROW EXECUTE FUNCTION public.reject_employment_history_mutation();

ALTER TABLE public.employment_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on employment_history"
    ON public.employment_history FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on employment_history"
    ON public.employment_history FOR INSERT TO authenticated WITH CHECK (true);

-- ============================================================================
-- B5. payroll_periods / payroll_lines
-- 金额一律是【周期币种】的原币;USD 侧由分录按 fx_rate 换算。
-- 数字全部来自外包服务商 —— 本系统记录并过账,从不自己算 CPF 或个税。
-- ============================================================================
CREATE TABLE public.payroll_periods (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,  -- gapless 'PAY-YYYY-NNNN'
    period_month           date NOT NULL,         -- 存当月 1 号
    payment_date           date NOT NULL,
    currency               text NOT NULL DEFAULT 'SGD' REFERENCES public.currencies (code),
    fx_rate                numeric NOT NULL CHECK (fx_rate > 0),
    status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted')),
    gross_total            numeric NOT NULL DEFAULT 0,
    employer_cpf_total     numeric NOT NULL DEFAULT 0,
    employee_cpf_total     numeric NOT NULL DEFAULT 0,
    other_deductions_total numeric NOT NULL DEFAULT 0,
    net_pay_total          numeric NOT NULL DEFAULT 0,
    journal_entry_id       uuid REFERENCES public.journal_entries (id),
    source_note            text,   -- 服务商文件/批次的出处
    notes                  text,
    deleted_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid DEFAULT auth.uid()
);

-- 一个月只能有一个在册周期(删除后可重建)
CREATE UNIQUE INDEX idx_payroll_periods_month_live
    ON public.payroll_periods (period_month) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_payroll_periods_updated_at
    BEFORE UPDATE ON public.payroll_periods
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.payroll_periods ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on payroll_periods"
    ON public.payroll_periods AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- 已过账的周期不能软删 —— 总账里已经有它了,删掉单据只会让账实不符
CREATE OR REPLACE FUNCTION public.guard_payroll_period_delete()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_POSTED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_payroll_periods_no_delete_posted
    BEFORE UPDATE OF deleted_at ON public.payroll_periods
    FOR EACH ROW EXECUTE FUNCTION public.guard_payroll_period_delete();

CREATE TABLE public.payroll_lines (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_period_id uuid NOT NULL REFERENCES public.payroll_periods (id) ON DELETE CASCADE,
    employee_id       uuid NOT NULL REFERENCES public.employees (id),
    gross_pay         numeric NOT NULL CHECK (gross_pay >= 0),          -- RESTRICTED
    employer_cpf      numeric NOT NULL DEFAULT 0 CHECK (employer_cpf >= 0),      -- RESTRICTED
    employee_cpf      numeric NOT NULL DEFAULT 0 CHECK (employee_cpf >= 0),      -- RESTRICTED
    other_deductions  numeric NOT NULL DEFAULT 0 CHECK (other_deductions >= 0),  -- RESTRICTED
    net_pay           numeric NOT NULL CHECK (net_pay >= 0),            -- RESTRICTED
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (payroll_period_id, employee_id)
);

CREATE INDEX idx_payroll_lines_period ON public.payroll_lines (payroll_period_id);
CREATE INDEX idx_payroll_lines_employee ON public.payroll_lines (employee_id);

ALTER TABLE public.payroll_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on payroll_lines"
    ON public.payroll_lines AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.next_payroll_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('payroll_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM payroll_periods
    WHERE code LIKE 'PAY-' || v_year::text || '-%';
    RETURN 'PAY-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$fn$;

-- ============================================================================
-- B6. upsert_payroll_period —— 草稿周期的明细【整批替换】
-- 服务商发来更正过的文件时,重导一次就该覆盖干净,不该让人去逐行比对。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.upsert_payroll_period(
    p_period_month date,
    p_payment_date date,
    p_currency text,
    p_fx_rate numeric,
    p_source_note text,
    p_notes text,
    p_lines jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_period   record;
    v_id       uuid;
    v_code     text;
    v_el       jsonb;
    v_emp      record;
    v_seen     uuid[] := ARRAY[]::uuid[];
    v_gross    numeric;
    v_er_cpf   numeric;
    v_ee_cpf   numeric;
    v_other    numeric;
    v_net      numeric;
    v_expected numeric;
    v_count    integer := 0;
    v_t_gross  numeric := 0;
    v_t_er     numeric := 0;
    v_t_ee     numeric := 0;
    v_t_other  numeric := 0;
    v_t_net    numeric := 0;
BEGIN
    IF p_period_month IS NULL OR p_period_month <> date_trunc('month', p_period_month)::date THEN
        RAISE EXCEPTION 'PERIOD_MONTH_INVALID|%', COALESCE(p_period_month::text, '?');
    END IF;
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_fx_rate IS NULL OR p_fx_rate <= 0 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', COALESCE(p_fx_rate::text, '?');
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    SELECT * INTO v_period FROM payroll_periods
    WHERE period_month = p_period_month AND deleted_at IS NULL
    FOR UPDATE;

    IF FOUND THEN
        -- 已过账的周期不接受重导:先 unpost 才能改(总账已经认了这批数)
        IF v_period.status = 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_POSTED|%', v_period.code;
        END IF;
        v_id := v_period.id;
        v_code := v_period.code;
        UPDATE payroll_periods
        SET payment_date = p_payment_date, currency = p_currency, fx_rate = p_fx_rate,
            source_note = p_source_note, notes = p_notes, updated_by = v_user
        WHERE id = v_id;
        DELETE FROM payroll_lines WHERE payroll_period_id = v_id;
    ELSE
        v_id := gen_random_uuid();
        v_code := next_payroll_code(p_period_month);
        INSERT INTO payroll_periods (id, code, period_month, payment_date, currency, fx_rate,
                                     source_note, notes, created_by, updated_by)
        VALUES (v_id, v_code, p_period_month, p_payment_date, p_currency, p_fx_rate,
                p_source_note, p_notes, v_user, v_user);
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        SELECT id, code INTO v_emp FROM employees
        WHERE id = (v_el->>'employee_id')::uuid AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(v_el->>'employee_id', '?');
        END IF;
        IF v_emp.id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_EMPLOYEE|%', v_emp.code;
        END IF;
        v_seen := v_seen || v_emp.id;

        v_gross  := (v_el->>'gross_pay')::numeric;
        v_er_cpf := COALESCE((v_el->>'employer_cpf')::numeric, 0);
        v_ee_cpf := COALESCE((v_el->>'employee_cpf')::numeric, 0);
        v_other  := COALESCE((v_el->>'other_deductions')::numeric, 0);
        v_net    := (v_el->>'net_pay')::numeric;

        IF v_gross IS NULL OR v_net IS NULL
           OR v_gross < 0 OR v_er_cpf < 0 OR v_ee_cpf < 0 OR v_other < 0 OR v_net < 0 THEN
            RAISE EXCEPTION 'AMOUNT_INVALID|%', v_emp.code;
        END IF;

        -- 服务商给的行必须自洽。这是本函数【唯一】的算术 —— 不是在算工资,
        -- 是在把录错/解析错的一行挡在总账之外。
        v_expected := round(v_gross - v_ee_cpf - v_other, 2);
        IF v_expected <> round(v_net, 2) THEN
            RAISE EXCEPTION 'LINE_NOT_BALANCED|%|%|%', v_emp.code, v_expected, round(v_net, 2);
        END IF;

        INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, employer_cpf,
                                   employee_cpf, other_deductions, net_pay, notes)
        VALUES (v_id, v_emp.id, v_gross, v_er_cpf, v_ee_cpf, v_other, v_net, v_el->>'notes');

        v_count := v_count + 1;
        v_t_gross := v_t_gross + v_gross;
        v_t_er    := v_t_er + v_er_cpf;
        v_t_ee    := v_t_ee + v_ee_cpf;
        v_t_other := v_t_other + v_other;
        v_t_net   := v_t_net + v_net;
    END LOOP;

    UPDATE payroll_periods
    SET gross_total = round(v_t_gross, 2),
        employer_cpf_total = round(v_t_er, 2),
        employee_cpf_total = round(v_t_ee, 2),
        other_deductions_total = round(v_t_other, 2),
        net_pay_total = round(v_t_net, 2),
        updated_by = v_user
    WHERE id = v_id;

    RETURN jsonb_build_object(
        'payroll_period_id', v_id,
        'code', v_code,
        'line_count', v_count,
        'gross_total', round(v_t_gross, 2),
        'employer_cpf_total', round(v_t_er, 2),
        'employee_cpf_total', round(v_t_ee, 2),
        'other_deductions_total', round(v_t_other, 2),
        'net_pay_total', round(v_t_net, 2)
    );
END;
$function$;

-- ============================================================================
-- B7. post_payroll_period / unpost_payroll_period
-- ============================================================================
CREATE OR REPLACE FUNCTION public.post_payroll_period(p_payroll_period_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_p     record;
    v_bank  text;
    v_lines jsonb := '[]'::jsonb;
    v_je    jsonb;
    v_cpf   numeric;
BEGIN
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_payroll_period_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 发薪走哪个银行账户由周期币种定;别的币种目前没有对应的银行科目
    v_bank := CASE v_p.currency WHEN 'SGD' THEN '1000' WHEN 'USD' THEN '1010' END;
    IF v_bank IS NULL THEN
        RAISE EXCEPTION 'PAYROLL_CURRENCY_UNSUPPORTED|%', v_p.currency;
    END IF;

    -- 借 6100 工资薪金(服务商口径的 gross)
    IF v_p.gross_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6100', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.gross_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 借 6110 公积金-雇主部分(公司成本,不从员工工资里出)
    IF v_p.employer_cpf_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6110', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.employer_cpf_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2400 公积金应付:雇主 + 员工两侧合计,汇给公积金局之前都欠着
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2400', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_cpf, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2200 应计费用:服务商【代公司扣下】的其它款项,在汇出去之前挂在这里。
    -- 【注意区分】如果某项扣款本质上是"公司成本变少"(而不是替员工代扣代缴),
    -- 那它就不该出现在这里 —— 应该让服务商把它并进 gross 里去。
    IF v_p.other_deductions_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2200', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.other_deductions_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 银行:实发净额
    IF v_p.net_pay_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_bank, 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.net_pay_total, 'fx_rate', v_p.fx_rate);
    END IF;

    -- 期间锁在 post_journal_entry 内生效(PERIOD_LOCKED 原样上抛)
    v_je := post_journal_entry(
        v_p.payment_date,
        'Payroll ' || v_p.code,
        'payroll',
        v_p.id,
        v_lines
    );

    UPDATE payroll_periods
    SET status = 'posted', journal_entry_id = (v_je->>'entry_id')::uuid, updated_by = v_user
    WHERE id = p_payroll_period_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_payroll_period_id,
        'code', v_p.code,
        'journal_code', v_je->>'code',
        'gross_total', v_p.gross_total,
        'employer_cpf_total', v_p.employer_cpf_total,
        'employee_cpf_total', v_p.employee_cpf_total,
        'net_pay_total', v_p.net_pay_total
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.unpost_payroll_period(p_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_p    record;
    v_je   jsonb;
BEGIN
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 冲销分录(冲销日 = 今天);原分录留在账上并被标记为已冲销 —— 不删账
    v_je := reverse_journal_entry(v_p.journal_entry_id, CURRENT_DATE, 'Payroll reversal ' || v_p.code);

    UPDATE payroll_periods
    SET status = 'draft',
        journal_entry_id = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unposted] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_id,
        'code', v_p.code,
        'status', 'draft',
        'reversal_journal_code', v_je->>'code'
    );
END;
$function$;

-- ============================================================================
-- B8. training_records
-- 安全与合规类证书【会过期】,合规切次要靠这张表做上岗资格检查。
-- ============================================================================
CREATE TABLE public.training_records (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    training_name   text NOT NULL,
    category        text CHECK (category IN ('induction','safety','compliance','cybersecurity','technical','leadership','other')),
    completed_date  date NOT NULL,
    expiry_date     date,
    provider        text,
    certificate_ref text,
    notes           text,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid()
);

CREATE INDEX idx_training_records_employee ON public.training_records (employee_id);
CREATE INDEX idx_training_records_expiry ON public.training_records (expiry_date) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_training_records_updated_at
    BEFORE UPDATE ON public.training_records
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.training_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on training_records"
    ON public.training_records AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B9. 视图
-- ============================================================================
-- 员工目录:一名在册员工一行。部门名【中英两列都给】—— 视图不猜界面语言。
-- 【受限访问】current_gross_pay / current_pay_period 是个人薪酬,权限切次按薪酬口径管控。
CREATE OR REPLACE VIEW public.employee_directory
WITH (security_invoker = on) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    e.department_id,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    e.job_title,
    e.manager_id,
    mgr.code AS manager_code,
    mgr.legal_name AS manager_name,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    e.annual_leave_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_expiry_date,
    CASE WHEN e.work_pass_expiry_date IS NULL THEN NULL::integer
         ELSE (e.work_pass_expiry_date - CURRENT_DATE) END AS days_to_work_pass_expiry,
    CASE WHEN e.work_pass_expiry_date IS NULL THEN NULL::text
         WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
         WHEN e.work_pass_expiry_date - CURRENT_DATE <= 30 THEN 'critical'::text
         WHEN e.work_pass_expiry_date - CURRENT_DATE <= 90 THEN 'warning'::text
         ELSE NULL::text END AS work_pass_alert,
    pay.gross_pay AS current_gross_pay,
    pay.period_month AS current_pay_period,
    COALESCE(tr.training_count, 0::bigint) AS training_count
   FROM employees e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT pl.gross_pay, pp.period_month
           FROM payroll_lines pl
             JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND pp.status = 'posted'::text AND pp.deleted_at IS NULL
          ORDER BY pp.period_month DESC
         LIMIT 1) pay ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS training_count
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
  WHERE e.deleted_at IS NULL;

-- HR 待办:需要有人去处理的事,一件一行。
-- 【只列还来得及处理的】超期 30 天以上的不再出现 —— 那已经不是"提醒"而是历史,
-- 留在清单里只会把真正紧急的几条淹掉;要查历史去各自的明细表。
-- 档期:工作准证与培训用 30/90 天,试用期用 14/30 天(试用期本来就短)。
CREATE OR REPLACE VIEW public.hr_alerts
WITH (security_invoker = on) AS
 SELECT 'work_pass_expiry'::text AS alert_type,
    CASE WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
         WHEN e.work_pass_expiry_date - CURRENT_DATE <= 30 THEN 'critical'::text
         ELSE 'warning'::text END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
    e.work_pass_expiry_date AS due_date,
    (e.work_pass_expiry_date - CURRENT_DATE) AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text
    AND e.work_pass_expiry_date IS NOT NULL
    AND e.work_pass_expiry_date - CURRENT_DATE <= 90
    AND e.work_pass_expiry_date - CURRENT_DATE >= -30
UNION ALL
 SELECT 'probation_ending'::text AS alert_type,
    CASE WHEN e.probation_end_date < CURRENT_DATE THEN 'expired'::text
         WHEN e.probation_end_date - CURRENT_DATE <= 14 THEN 'critical'::text
         ELSE 'warning'::text END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation'::text AS subject,
    e.probation_end_date AS due_date,
    (e.probation_end_date - CURRENT_DATE) AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text
    AND e.probation_end_date IS NOT NULL
    AND e.probation_end_date - CURRENT_DATE <= 30
    AND e.probation_end_date - CURRENT_DATE >= -30
UNION ALL
 SELECT 'training_expiry'::text AS alert_type,
    CASE WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
         WHEN t.expiry_date - CURRENT_DATE <= 30 THEN 'critical'::text
         ELSE 'warning'::text END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    t.training_name AS subject,
    t.expiry_date AS due_date,
    (t.expiry_date - CURRENT_DATE) AS days_remaining
   FROM training_records t
     JOIN employees e ON e.id = t.employee_id
  WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL
    AND e.employment_status <> 'separated'::text
    AND t.expiry_date IS NOT NULL
    AND t.expiry_date - CURRENT_DATE <= 90
    AND t.expiry_date - CURRENT_DATE >= -30;

COMMIT;
