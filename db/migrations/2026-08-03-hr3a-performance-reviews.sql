-- db/migrations/2026-08-03-hr3a-performance-reviews.sql
-- HR cut 3a:绩效评估、试用期转正,以及【与批准绑在一起的调薪】。
--
-- 文件日期说明:实际写于 2026-08-02,命名为 08-03 是为了让文件名排序落在
-- perm4(2026-08-02-perm4-self-service.sql)之后 —— 本切依赖 perm4 建立的
-- current_user_employee() 自助行谓词与 employees_masked 的当前形状,按文件名
-- 重放时顺序必须正确。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【落笔之前查证过的四件事,每一件都改变了实现】
--
-- (1) 【年假"转正才解锁"是读时派生的,不是账上的一行】
--     闸门在 submit_leave_request:
--         IF v_type.is_accrued AND v_emp.employment_status = 'probation'
--             THEN RAISE 'PROBATION_NO_ANNUAL_LEAVE';
--     leave_grants 的行只由 grant_annual_leave 写,那个函数【根本不看在职状态】——
--     试用期员工可以已经持有当年的授予,只是花不出去。leave_balance() 全部由
--     授予 − 消耗派生。
--     ⇒ 【approve_review 一个字都不写进假期台账】。把 employment_status 从
--       'probation' 翻成 'active',解锁就已经完整发生了。在这里补一笔授予,
--       就是把 HR-2a 那个结转重复计数的错误原样重演一遍:同一份年假会在
--       entitlement 授予与"转正授予"里【各算一次】。fixture 第 1 条专门断言
--       批准前后余额【逐位相同】。
--
-- (2) 【没有 'confirmed' 这个在职状态】employees_employment_status_check 只有
--     ('probation','active','notice','separated')。转正后的状态是 'active';
--     "转正"这个【事件】记在 employment_history.change_type = 'confirmed'
--     (该值早已存在)。不新增第五个状态值 —— 下游每一处 employment_status
--     = 'active' 的过滤(工资表、hr_alerts、本切 C4)都会把新值静悄悄地漏掉。
--
-- (3) 【全库没有"每月工资"这一列】薪酬只以 payroll_lines.gross_pay 存在,
--     一个周期一行,而且那张表的表头写得很清楚:数字全部来自外包服务商。
--     于是 C2 的"old → new"既没有落点、也没有 old 可读。经 Tim 决定:
--     新增 employees.monthly_salary =【合同月薪(HR 的数字)】,与
--     payroll_lines.gross_pay(服务商算出的实发口径,含津贴/加班)【是两个事实】。
--     ⚠️ 本列【永远不参与任何一次工资计算】,工资照旧由服务商算、由本系统记录。
--
-- (4) 【payroll_periods 没有起止日期两列】只有 period_month(恒为当月 1 号)
--     与 payment_date。"生效日落在已过账周期内"必须按
--         eff >= period_month AND eff < period_month + 1 month
--     去算,而不是找一对 start/end 列。
--
-- 【权限:不新增 data.view_reviews】线上 10 个角色里,module.hr.view/edit 只在
--   admin / gm / hr(view+edit)与 auditor(仅 view)手上;finance、procurement、
--   sales、operations、warehouse 【一个 HR 码都没有】。B7 要表达的东西,现有的
--   模块码已经逐字表达得了 —— 为了加而加只会让权限目录更难读。
--   代价说明白:auditor 会读到全部评估(只读),那是既有架构"审计看得见一切、
--   改不了任何东西";但它没有 data.view_pay,所以薪酬列对它仍是遮蔽的。
--
-- 【试用期三个月上限:线上零违规】加约束前查过全表,employees 只有一行
--   EMP-2026-0001(入职 2026-08-01,probation_end_date 为 NULL,状态 active),
--   没有任何一行会被新约束挡下,因此【没有改动过任何数据】。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- B0. 前置:三张既有表要先补上本切要用的字段
-- ════════════════════════════════════════════════════════════════════════════

-- ── employees:转正日 + 合同月薪 ────────────────────────────────────────────
ALTER TABLE public.employees
    ADD COLUMN confirmation_date date,
    -- RESTRICTED(data.view_pay)。【合同月薪】,不是工资单上的实发口径。
    ADD COLUMN monthly_salary numeric CHECK (monthly_salary IS NULL OR monthly_salary >= 0);

COMMENT ON COLUMN public.employees.confirmation_date IS
    '试用期转正日。由 approve_review 在批准 probation/confirm 的评估时写入;状态同时转为 active。';
COMMENT ON COLUMN public.employees.monthly_salary IS
    'RESTRICTED(data.view_pay)。合同月薪 —— HR 谈定的数字。【与 payroll_lines.gross_pay 是两个事实】:'
    '后者是外包服务商算出的当期实发口径(含津贴、加班、扣款)。本列不参与任何工资计算,'
    '只由 approve_review 在批准带调薪的评估时更新,并留痕于 employment_history。';

-- 【B5 试用期三个月上限】NULL 容忍:probation_end_date 本来就是可空的,
-- 没填不等于违规。加约束【之前】已查证线上无一行违反(见文件头)。
ALTER TABLE public.employees
    ADD CONSTRAINT employees_probation_cap CHECK (
        probation_end_date IS NULL
        OR probation_end_date <= (hire_date + interval '3 months')::date
    );

-- 新列要单独授权:cut 2b 已把 employees 的表级 SELECT 收回,逐列授回。
-- confirmation_date 授回(它不是敏感数据);monthly_salary【故意不授】——
-- 直接读原始列在 PostgREST 上是 42501 硬报错,只能经 employees_masked 读。
GRANT SELECT (confirmation_date) ON public.employees TO authenticated;

-- ── departments:部门经理 ───────────────────────────────────────────────────
-- C4 按这一列默认评估人。可空:新建部门时未必已经定下经理。
ALTER TABLE public.departments
    ADD COLUMN manager_employee_id uuid REFERENCES public.employees (id);

CREATE INDEX idx_departments_manager ON public.departments (manager_employee_id);

COMMENT ON COLUMN public.departments.manager_employee_id IS
    '部门经理。open_review_cycle 用它默认年度评估的评估人。可空 —— 未设时评估人留空,由 HR 手工指派。';

-- ── employment_history:调薪留痕 ────────────────────────────────────────────
-- 【为什么加两列而不是塞进 notes】D6 要断言 old 与 new 两个数字。塞进自由文本
-- 意味着断言要去解析字符串,而"这个人当时涨到多少"是个应当查得出来的事实。
ALTER TABLE public.employment_history
    ADD COLUMN old_monthly_salary numeric,   -- RESTRICTED(data.view_pay)
    ADD COLUMN new_monthly_salary numeric;   -- RESTRICTED(data.view_pay)

-- 词表加一个 'salary_change'。既有七个值一个不动。
ALTER TABLE public.employment_history
    DROP CONSTRAINT employment_history_change_type_check;
ALTER TABLE public.employment_history
    ADD CONSTRAINT employment_history_change_type_check CHECK (
        change_type = ANY (ARRAY['hired','confirmed','promotion','transfer',
                                 'type_change','status_change','separated','salary_change'])
    );

-- 调薪行必须两个数字都说得出来(old 可为 NULL:首次录入合同月薪时本来就没有旧值)
ALTER TABLE public.employment_history
    ADD CONSTRAINT employment_history_salary_shape CHECK (
        change_type <> 'salary_change' OR new_monthly_salary IS NOT NULL
    );

-- 遮蔽机制照 cut 2b 原样:表级 SELECT 蕴含所有列,所以先整表收回,再逐列授回。
REVOKE SELECT ON public.employment_history FROM authenticated, anon;
GRANT SELECT (id, employee_id, effective_date, change_type, job_title, department_id,
              employment_type, employment_status, notes, created_at, created_by)
    ON public.employment_history TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- B1. review_rating_scale —— 评级是【可编辑的数据,不是枚举】
-- ════════════════════════════════════════════════════════════════════════════
-- 与 leave_types 同一套路:双语名 + description,is_active 停用而不删除,
-- sort_order 决定呈现次序。加第五档、停用一档,都不该再来一次迁移(fixture 第 9 条证明)。
CREATE TABLE public.review_rating_scale (
    code              text PRIMARY KEY,
    name_en           text NOT NULL,
    name_zh           text NOT NULL,
    description_en    text,
    description_zh    text,
    sort_order        integer NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    -- 【提示,不是规则】这一档"通常意味着试用期通过"。approve_review 【不读它】——
    -- 转正与否由 performance_reviews.probation_outcome 明说,不从评级推导。
    -- 推导出来的决定没法在单据上签字。
    is_probation_pass boolean NOT NULL DEFAULT false,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_review_rating_scale_updated_at
    BEFORE UPDATE ON public.review_rating_scale
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.review_rating_scale ENABLE ROW LEVEL SECURITY;
CREATE POLICY "review_rating_scale select by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "review_rating_scale insert by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_rating_scale update by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_rating_scale delete by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- 四档,sort_order 由高到低排列(升序取出即为 OUTSTANDING → BELOW,同 leave_types 的用法)
INSERT INTO public.review_rating_scale
    (code, name_en, name_zh, description_en, description_zh, sort_order, is_probation_pass) VALUES
    ('OUTSTANDING', 'Outstanding',        '卓越',
     'Consistently exceeded every objective set for the period.',
     '本期各项目标均持续超额达成。', 10, true),
    ('EXCEEDS',     'Exceeds Expectations','超出预期',
     'Exceeded most objectives set for the period.',
     '本期多数目标超出预期达成。', 20, true),
    ('MEETS',       'Meets Expectations', '符合预期',
     'Met the objectives set for the period.',
     '本期目标达成,符合预期。', 30, true),
    ('BELOW',       'Below Expectations', '低于预期',
     'Did not meet the objectives set for the period.',
     '本期目标未达成。', 40, false);

-- ════════════════════════════════════════════════════════════════════════════
-- B2. review_cycles —— 一轮有名字的年度评估
-- ════════════════════════════════════════════════════════════════════════════
-- 【试用期评估不属于任何 cycle】—— 它跟着人走,不跟着年度走(B3 的 check 强制)。
CREATE TABLE public.review_cycles (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text NOT NULL,
    period_start date NOT NULL,
    period_end   date NOT NULL,
    due_date     date NOT NULL,
    status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','open','closed')),
    notes        text,
    deleted_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT review_cycles_period_shape CHECK (period_end >= period_start)
);

CREATE UNIQUE INDEX idx_review_cycles_name_live
    ON public.review_cycles (name) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_review_cycles_updated_at
    BEFORE UPDATE ON public.review_cycles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.review_cycles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "review_cycles select by permission"
    ON public.review_cycles AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "review_cycles insert by permission"
    ON public.review_cycles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_cycles update by permission"
    ON public.review_cycles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_cycles delete by permission"
    ON public.review_cycles AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ════════════════════════════════════════════════════════════════════════════
-- B3. performance_reviews —— 评估单据本身
-- ════════════════════════════════════════════════════════════════════════════
-- 【评级 + 书面结论两者都要】rating_code 是可比的档位,summary_text 是说得出理由
-- 的那段话。只有档位的评估没法向员工交代,只有文字的评估没法横向看。
--
-- 【状态流】draft →(self_review)→ submitted → approved → acknowledged
--   self_review 是【可选的一步】:评估人可以 draft → submitted 直接走(C1 两个入口状态都收)。
--   void 是第六个状态,不在流水线上 —— 单据靠作废重开更正,不靠改(C5,同发票)。
--
-- 【为什么 reviewer_employee_id 可空】C4 按部门经理默认评估人;部门经理【本人】
--   的那份评估找不到合法的默认值(自己不能评自己),留空由 HR 指派,比塞一个
--   错的人进去诚实。C1 在提交时要求它非空。
CREATE TABLE public.performance_reviews (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id            uuid NOT NULL REFERENCES public.employees (id),
    review_type            text NOT NULL CHECK (review_type IN ('probation','annual')),
    cycle_id               uuid REFERENCES public.review_cycles (id),
    period_start           date NOT NULL,
    period_end             date NOT NULL,
    reviewer_employee_id   uuid REFERENCES public.employees (id),
    status                 text NOT NULL DEFAULT 'draft'
                           CHECK (status IN ('draft','self_review','submitted','approved','acknowledged','void')),
    rating_code            text REFERENCES public.review_rating_scale (code),
    summary_text           text,
    self_assessment_text   text,
    probation_outcome      text CHECK (probation_outcome IN ('confirm','not_confirm')),
    new_monthly_salary     numeric CHECK (new_monthly_salary IS NULL OR new_monthly_salary >= 0),  -- RESTRICTED(data.view_pay)
    salary_effective_date  date,
    submitted_at           timestamptz,
    submitted_by           uuid,
    approved_at            timestamptz,
    approved_by            uuid,
    acknowledged_at        timestamptz,
    void_reason            text,
    voided_at              timestamptz,
    voided_by              uuid,
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid DEFAULT auth.uid(),

    -- 年度评估必须属于一轮;试用期评估不属于任何一轮
    CONSTRAINT performance_reviews_cycle_shape CHECK (
        CASE review_type
            WHEN 'annual'    THEN cycle_id IS NOT NULL
            WHEN 'probation' THEN cycle_id IS NULL
        END
    ),

    -- 【提交起,评级与书面结论都必须在场】draft / self_review 还在写,void 是已作废
    -- 的历史(作废时的数据原样留着)。summary_text 空白串不算数。
    CONSTRAINT performance_reviews_submitted_shape CHECK (
        status IN ('draft','self_review','void')
        OR (rating_code IS NOT NULL AND summary_text IS NOT NULL AND btrim(summary_text) <> '')
    ),

    -- probation_outcome:【非试用期评估恒为 NULL】(任何状态下都不许有);
    -- 试用期评估自 submitted 起必须有 —— 与评级、结论同一道闸,因为在 draft 阶段
    -- 尚未做出的决定,不该被迫先填一个看起来像真的值进去。
    CONSTRAINT performance_reviews_probation_outcome_shape CHECK (
        CASE
            WHEN review_type <> 'probation' THEN probation_outcome IS NULL
            WHEN status IN ('draft','self_review','void') THEN true
            ELSE probation_outcome IS NOT NULL
        END
    ),

    -- 调薪:要么都空,要么都有 —— 一个没有生效日的新工资无法过账
    CONSTRAINT performance_reviews_salary_shape CHECK (
        (new_monthly_salary IS NULL) = (salary_effective_date IS NULL)
    ),

    -- 【自己不能评自己】
    CONSTRAINT performance_reviews_not_self_review CHECK (
        reviewer_employee_id IS DISTINCT FROM employee_id
    ),

    CONSTRAINT performance_reviews_period_shape CHECK (period_end >= period_start)
);

-- 【一名员工只有一份未作废的试用期评估】
CREATE UNIQUE INDEX idx_performance_reviews_one_probation
    ON public.performance_reviews (employee_id)
    WHERE review_type = 'probation' AND status <> 'void';

-- 一轮里一名员工只有一份未作废的评估 —— C4 幂等的兜底(函数里另有 NOT EXISTS)
CREATE UNIQUE INDEX idx_performance_reviews_one_per_cycle
    ON public.performance_reviews (employee_id, cycle_id)
    WHERE cycle_id IS NOT NULL AND status <> 'void';

CREATE INDEX idx_performance_reviews_employee ON public.performance_reviews (employee_id);
CREATE INDEX idx_performance_reviews_reviewer ON public.performance_reviews (reviewer_employee_id);
CREATE INDEX idx_performance_reviews_cycle ON public.performance_reviews (cycle_id);
CREATE INDEX idx_performance_reviews_status ON public.performance_reviews (status);

CREATE TRIGGER trg_performance_reviews_updated_at
    BEFORE UPDATE ON public.performance_reviews
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── B7 RLS ─────────────────────────────────────────────────────────────────
-- 策略只出现【权限码】,不出现角色名(cut 2a 架构)。三条 PERMISSIVE 的 SELECT
-- 或起来:HR 模块 / 本行的评估人 / 本人【且已批准或已确认】。
-- finance、procurement、sales、operations、warehouse 一个 HR 码都没有 ⇒ 读到 0 行,
-- 不需要为此写任何一条否定策略。评估不是财务表。
ALTER TABLE public.performance_reviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY "performance_reviews select by permission"
    ON public.performance_reviews AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));

CREATE POLICY "performance_reviews select as reviewer"
    ON public.performance_reviews AS PERMISSIVE FOR SELECT TO authenticated
    USING (reviewer_employee_id = current_user_employee());

-- 【本人只在批准之后看得见】草稿与已提交未批准的评估对被评估人不可见 ——
-- 那还是评估人手上没定稿的东西,提前泄露会把一份未完成的判断变成既成事实。
CREATE POLICY "performance_reviews select own approved"
    ON public.performance_reviews AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee() AND status IN ('approved','acknowledged'));

CREATE POLICY "performance_reviews insert by permission"
    ON public.performance_reviews AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "performance_reviews update by permission"
    ON public.performance_reviews AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "performance_reviews delete by permission"
    ON public.performance_reviews AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- 字段级遮蔽,机制与 cut 2b 完全一致(不另起一套):
-- 表级 SELECT 授权蕴含所有列 ⇒ 先整表收回,再把非敏感列逐列授回。
-- new_monthly_salary 只能经 performance_reviews_masked 读。
REVOKE SELECT ON public.performance_reviews FROM authenticated, anon;
GRANT SELECT (id, employee_id, review_type, cycle_id, period_start, period_end,
              reviewer_employee_id, status, rating_code, summary_text, self_assessment_text,
              probation_outcome, salary_effective_date, submitted_at, submitted_by,
              approved_at, approved_by, acknowledged_at, void_reason, voided_at, voided_by,
              notes, created_at, created_by, updated_at, updated_by)
    ON public.performance_reviews TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- B4. review_goals —— 目标与结果,【不是能力评分】
-- ════════════════════════════════════════════════════════════════════════════
-- "Measure Outcomes, Not Time":这里只有"期初说好要做成什么"与"做成了什么"。
-- 【没有权重、没有逐条打分】—— 一旦有了分数,谈话就会围着分数转,而不是围着结果转。
CREATE TABLE public.review_goals (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    review_id                uuid NOT NULL REFERENCES public.performance_reviews (id) ON DELETE CASCADE,
    sequence                 integer NOT NULL,
    objective_text           text NOT NULL,          -- 期初定下的期望
    employee_result_text     text,                   -- 自评阶段由员工写
    reviewer_assessment_text text,                   -- 评估人写
    created_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid DEFAULT auth.uid(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    updated_by               uuid DEFAULT auth.uid(),
    UNIQUE (review_id, sequence),
    CONSTRAINT review_goals_objective_not_blank CHECK (btrim(objective_text) <> '')
);

CREATE INDEX idx_review_goals_review ON public.review_goals (review_id);

CREATE TRIGGER trg_review_goals_updated_at
    BEFORE UPDATE ON public.review_goals
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- RLS:与 performance_reviews 逐条对应,经 review_id 上溯。
ALTER TABLE public.review_goals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "review_goals select by permission"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));

CREATE POLICY "review_goals select as reviewer"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM performance_reviews r
                   WHERE r.id = review_goals.review_id
                     AND r.reviewer_employee_id = current_user_employee()));

CREATE POLICY "review_goals select own approved"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM performance_reviews r
                   WHERE r.id = review_goals.review_id
                     AND r.employee_id = current_user_employee()
                     AND r.status IN ('approved','acknowledged')));

CREATE POLICY "review_goals insert by permission"
    ON public.review_goals AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_goals update by permission"
    ON public.review_goals AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_goals delete by permission"
    ON public.review_goals AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ════════════════════════════════════════════════════════════════════════════
-- 遮蔽伴生视图 —— 属主权限 + 在视图体里把行谓词原样加回(cut 2b 的两条铁律)
-- ════════════════════════════════════════════════════════════════════════════

-- employees_masked:补 confirmation_date(不敏感)与 monthly_salary(要 data.view_pay)。
-- 【对本人让路】与既有的身份列一致 —— 那是这个人自己的工资。
-- 【新列一律追加在末尾】employee_directory 依赖本视图,DROP 会连它一起要 CASCADE;
-- 只在尾部加列,CREATE OR REPLACE 就能原地改,依赖视图一个都不用动。
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
        END AS monthly_salary
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

-- employment_history_masked:本切新增(调薪两列是薪酬数据)。
-- 行谓词照抄基表策略:module.hr.view 或本人。
CREATE VIEW public.employment_history_masked WITH (security_invoker = off) AS
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
        END AS new_monthly_salary
   FROM employment_history
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();

-- performance_reviews_masked:行谓词是基表三条 SELECT 策略的【逐字重述】——
-- 属主权限的视图必须自己把行访问加回来,不能比基表更宽。
CREATE VIEW public.performance_reviews_masked WITH (security_invoker = off) AS
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
    updated_by
   FROM performance_reviews
  WHERE has_permission('module.hr.view'::text)
     OR reviewer_employee_id = current_user_employee()
     OR (employee_id = current_user_employee() AND status IN ('approved','acknowledged'));

-- ════════════════════════════════════════════════════════════════════════════
-- B6. hr_alerts 扩展
-- ════════════════════════════════════════════════════════════════════════════
-- 【试用期那一支拆成三支】,因为"试用期不能延长"改变了什么该留在看板上:
--   probation_ending      还没到期、且还没有【批准且 confirm】的评估   → warning / critical
--   probation_overdue     已过期、且还没有任何批准的评估               → expired,【不设 30 天下限】
--   probation_not_confirmed 已批准 not_confirm 但人还挂在试用期        → expired,这就是 C2 说的"raise the alert"
--
-- 【为什么 overdue 不设下限】原视图的 -30 天下限是"过期太久就不再是提醒而是历史"。
-- 那条理由对工作准证成立(准证到期后事情已经发生了),对试用期【不成立】——
-- 试用期不能延长,一份没做出的转正决定不会随时间自己了结,它只会一直欠着。
-- 让它从看板上消失,等于把唯一会提醒人的东西关掉。
--
--   review_cycle_overdue  已开启的评估轮过了 due_date、仍有未提交的评估 → 每份一行
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
    -- 【批准且 confirm 的试用期评估让这条提醒消失】。批准了 not_confirm 不算清除:
    -- 那份决定还欠着一个手工的离职动作,见下一支。
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

-- ════════════════════════════════════════════════════════════════════════════
-- PART C. 函数 —— 全部 SECURITY DEFINER,各自检查【自己这个动作】所需的权限
-- ════════════════════════════════════════════════════════════════════════════

-- ── C1. submit_review ──────────────────────────────────────────────────────
-- 权限:本行的评估人,或 module.hr.edit。评估人本身未必是 HR。
CREATE OR REPLACE FUNCTION public.submit_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      performance_reviews%ROWTYPE;
    v_goals  integer;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('module.hr.edit')
            OR v_r.reviewer_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    -- self_review 是可选的一步,所以两个入口状态都收
    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF v_r.rating_code IS NULL THEN
        RAISE EXCEPTION 'RATING_REQUIRED';
    END IF;
    IF v_r.summary_text IS NULL OR btrim(v_r.summary_text) = '' THEN
        RAISE EXCEPTION 'SUMMARY_REQUIRED';
    END IF;
    IF v_r.review_type = 'probation' AND v_r.probation_outcome IS NULL THEN
        RAISE EXCEPTION 'PROBATION_OUTCOME_REQUIRED';
    END IF;

    SELECT count(*) INTO v_goals FROM review_goals WHERE review_id = p_review_id;
    IF v_goals = 0 THEN
        RAISE EXCEPTION 'GOALS_REQUIRED';
    END IF;

    UPDATE performance_reviews
    SET status = 'submitted', submitted_at = now(), submitted_by = auth.uid()
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'submitted',
                              'rating_code', v_r.rating_code, 'goals', v_goals);
END;
$function$;

-- ── C2. approve_review ─────────────────────────────────────────────────────
-- 【一次原子事务】批准 + 转正 + 调薪。函数体就是事务边界:任何一步 RAISE,
-- 前面几步一起回滚 —— fixture 第 7 条正是为了证明这一点(调薪被拒时转正也没发生)。
-- 【顺序刻意如此】先批准、再转正、最后校验调薪,好让"调薪失败必须把转正也撤掉"
-- 这条要求成为一个真的会被走到的路径,而不是一句注释。
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
        VALUES (v_emp.id, v_conf, 'confirmed', v_emp.job_title, v_emp.department_id,
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
        SELECT e.id, v_r.salary_effective_date, 'salary_change', e.job_title, e.department_id,
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

-- ── C3. acknowledge_review ─────────────────────────────────────────────────
-- 只有被评估人本人能确认,且只能从 approved 出发。HR 替员工点"已阅"就把
-- 这个动作的全部意义抹掉了,所以这里【不给 module.hr.edit 开口子】。
CREATE OR REPLACE FUNCTION public.acknowledge_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF v_r.employee_id IS DISTINCT FROM current_user_employee() THEN
        RAISE EXCEPTION 'NOT_REVIEW_SUBJECT';
    END IF;

    IF v_r.status <> 'approved' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    UPDATE performance_reviews
    SET status = 'acknowledged', acknowledged_at = now()
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'acknowledged');
END;
$function$;

-- ── C4. open_review_cycle ──────────────────────────────────────────────────
-- 每名【在职且已转正】的员工生成一份 draft。评估人默认取部门经理。
-- 【幂等】:同一轮同一名员工永不生成第二份(NOT EXISTS + 部分唯一索引双保险)。
CREATE OR REPLACE FUNCTION public.open_review_cycle(p_cycle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        review_cycles%ROWTYPE;
    v_created  integer;
    v_total    integer;
    v_noreviewer integer;
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
               -- 部门经理;经理本人那一份没有合法默认值(自己不能评自己)⇒ 留空
               NULLIF(d.manager_employee_id, e.id),
               'draft'
        FROM employees e
        LEFT JOIN departments d ON d.id = e.department_id
        WHERE e.deleted_at IS NULL
          -- 【'active' = 在职且已转正】。probation 与 separated 按题意排除;
          -- 'notice'(在离职通知期内)同样不生成 —— 它不是 active,而且一份
          -- 走完流程要几周的年度评估对一个正在走人的人没有意义。
          AND e.employment_status = 'active'
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

    RETURN jsonb_build_object(
        'cycle_id', p_cycle_id, 'cycle_name', v_c.name, 'status', 'open',
        'created', v_created, 'total_reviews', v_total,
        'without_reviewer', v_noreviewer);
END;
$function$;

-- ── C5. void_review ────────────────────────────────────────────────────────
-- 评估是单据:更正靠【作废 + 重开】,不靠改一份已批准的。同发票那一套。
-- 【作废不回滚已经发生的雇佣事实】—— 转正与调薪已经写进 employees 与不可变的
-- employment_history。要改那些,靠新的评估或 HR 的手工更正再补一行,
-- 而不是靠把历史抹掉(employment_history 本来就 UPDATE/DELETE 全拒)。
CREATE OR REPLACE FUNCTION public.void_review(p_review_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r performance_reviews%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status = 'void' THEN
        RAISE EXCEPTION 'REVIEW_ALREADY_VOID|%', p_review_id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE performance_reviews
    SET status = 'void', void_reason = btrim(p_reason),
        voided_at = now(), voided_by = auth.uid()
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'void',
                              'previous_status', v_r.status,
                              'employment_facts_unchanged', true);
END;
$function$;

COMMIT;
