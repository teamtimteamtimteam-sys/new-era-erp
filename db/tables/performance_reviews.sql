-- db/tables/performance_reviews.sql
-- 绩效评估单据。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列 / RESTRICTED-ACCESS COLUMNS】
-- ════════════════════════════════════════════════════════════════════════════
--   new_monthly_salary   评估批准时谈定的新月薪 —— 归 data.view_pay,
--                        与 payroll_lines 的按人头金额同一条线。
-- 只能经 performance_reviews_masked 读取(遮蔽机制沿用 cut 2b,不另起一套)。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【评级 + 书面结论两者都要】rating_code 是可比的档位,summary_text 是说得出理由
-- 的那段话。只有档位的评估没法向员工交代,只有文字的评估没法横向看。
--
-- 【状态流】draft →(self_review)→ submitted → approved → acknowledged
--   self_review 是【可选的一步】:评估人可以 draft → submitted 直接走。
--   void 是第六个状态,不在流水线上 —— 单据靠作废重开更正,不靠改(void_review,同发票)。
--
-- 【为什么 reviewer_employee_id 可空】open_review_cycle 按部门经理默认评估人;
--   部门经理【本人】那一份找不到合法的默认值(自己不能评自己),留空由 HR 指派,
--   比塞一个错的人进去诚实。submit_review 在提交时要求它非空。
--
-- 【probation_outcome 的闸门在 submitted,不在 insert】非试用期评估恒为 NULL(任何
--   状态下都不许有);试用期评估自 submitted 起必须有 —— 与评级、结论同一道闸,
--   因为在 draft 阶段尚未做出的决定,不该被迫先填一个看起来像真的值进去。
--
-- 【试用期不能延长】所以没有 'extend' 这种结果,只有 confirm / not_confirm;
--   人员上限由 employees_probation_cap(三个月)在员工表那边挡。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.
-- First-run script (plain CREATEs).

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
    new_monthly_salary     numeric CHECK (new_monthly_salary IS NULL OR new_monthly_salary >= 0),  -- RESTRICTED
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

    -- 提交起,评级与书面结论都必须在场(空白串不算数)
    CONSTRAINT performance_reviews_submitted_shape CHECK (
        status IN ('draft','self_review','void')
        OR (rating_code IS NOT NULL AND summary_text IS NOT NULL AND btrim(summary_text) <> '')
    ),

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

-- 一轮里一名员工只有一份未作废的评估 —— open_review_cycle 幂等的兜底
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

-- 字段级遮蔽:表级 SELECT 授权【蕴含所有列】,所以先整表收回,再把非敏感列逐列授回。
-- new_monthly_salary 在 PostgREST 上是 42501 硬报错(不是静悄悄的泄露)。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.performance_reviews FROM authenticated, anon;
GRANT SELECT (id, employee_id, review_type, cycle_id, period_start, period_end,
              reviewer_employee_id, status, rating_code, summary_text, self_assessment_text,
              probation_outcome, salary_effective_date, submitted_at, submitted_by,
              approved_at, approved_by, acknowledged_at, void_reason, voided_at, voided_by,
              notes, created_at, created_by, updated_at, updated_by)
    ON public.performance_reviews TO authenticated;
