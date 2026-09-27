-- db/tables/salary_change_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-9(2026-09-27):调薪申请 —— 财务提,CFO 批,批准之前月薪一分不动
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md §5「调薪 | 只经绩效评估或调薪申请 | CFO」):第一份月薪之外的每一次变动,
-- 走一张绩效评估(cco 做,CFO 批)或走这里。对 employees.monthly_salary 的直连写仍一律拒(ROLE-1)。
--
-- 【生命周期】与 APR-7 / APR-8 同形,少一样东西:它【不看审批开关】(APR-9 grilling Q3)
--   submitted ──批准(当场生效)──▶ approved
--       ├──驳回(要理由)─────────▶ rejected
--       └──撤回──────────────────▶ withdrawn
--   · 提:财务 —— module.hr.edit + data.view_pay(第一份月薪那扇门的同一对码,Q4)。
--     **谁都不能给自己提调薪**(按人认:SALARY_CHANGE_OWN_REFUSED)。
--   · 批:pay_decision_code(提单人, 员工) —— CFO(action.approve_review);CFO 这个【人】是提单人或主角时,
--     cco(action.hr_reviews)。与绩效评估【同一份】判据(review_approval_code 委托给它,Q2)。
--     另要 module.hr.view + data.view_pay:批的人看得见他批的那个数(docs/approvals.md §5)。
--     提单人与主角永远不能批(forbid_self_approval,按人认;R2 永远不覆盖调薪)。
--     提单人之外没人批得动 → 提交就拒 SALARY_CHANGE_NO_OTHER_DECIDER。
--   · 撤回:提单人本人(按人认),或持提单那一对码的人。撤回不写 approval_log。
--   · ★ 审批关着也要等(Q3):生下来永远是 submitted,从不 auto_approved;它【不挡】关审批
--     (approval_pending_documents 里 blocks_disable = false —— 关着时照样批得了)。
--   · ★ 不在 approval_chain_gates 里(Q2):那本名册按"级"找人,而这条链按【人】路由(CFO 是当事人 → cco)。
--
-- 【生效日】(Q5)必填;提交时与批准时各判一次:落在一个已过账的工资期里,或落在一个挂着在途工资申请的
--   工资期里 → 按名拒(salary_effective_period_block 一份判据)。批准当场写 employees.monthly_salary,
--   履历那一行带这个生效日(与绩效评估批准同形 —— 工资表本身从不读月薪,数字来自外包服务商)。
-- 【只改已有的月薪】monthly_salary 为 NULL 的人,第一份月薪只经 set_initial_salary(SALARY_NOT_SET_USE_INITIAL)。
-- 【一个人同一时刻只有一次在途调薪】(Q6)跨两条路:一张在等的申请,或一张带调薪、已提交的绩效评估
--   (salary_change_open 一份判据;SALARY_CHANGE_OPEN)。
-- 【fingerprint】(Q6)snapshot = 提交那一刻的月薪与在职状态;批准时再比,变了 → SALARY_CHANGED_SINCE_REQUEST,
--   申请仍在等(驳回或撤回)。
-- 【读】module.hr.view + data.view_pay —— 月薪是 PDPA 受限的个人数据。主角在等待中读不到这张申请
--   (绩效评估"本人只在批准之后看得见"同一条);批准之后他从自己的档案与履历上看得见新的月薪。
--
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE TABLE public.salary_change_requests (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status              text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label               text NOT NULL,
    employee_id         uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组(RESTRICTED:两个月薪数)────────────────────────────────
    old_monthly_salary  numeric NOT NULL CHECK (old_monthly_salary >= 0),
    new_monthly_salary  numeric NOT NULL CHECK (new_monthly_salary >= 0),
    effective_date      date NOT NULL,
    reason              text NOT NULL CHECK (btrim(reason) <> ''),
    -- fingerprint:{monthly_salary, employment_status} —— 批准时与活数再比
    snapshot            jsonb NOT NULL,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at          timestamptz,
    decided_by          uuid,
    -- 按哪一个码批的(action.approve_review = CFO;action.hr_reviews = CFO 是当事人时的 cco)
    decided_via         text,
    decision_notes      text,
    executed_at         timestamptz,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at        timestamptz,
    withdrawn_by        uuid,
    withdraw_reason     text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid NOT NULL,
    CONSTRAINT salary_change_requests_changes_something CHECK (new_monthly_salary <> old_monthly_salary),
    CONSTRAINT salary_change_requests_decision_shape CHECK (
        (decided_at IS NULL) = (decided_by IS NULL) AND (decided_at IS NULL) = (decided_via IS NULL)),
    CONSTRAINT salary_change_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT salary_change_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT salary_change_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.salary_change_requests IS
    'APR-9:调薪申请 —— 财务提(module.hr.edit + data.view_pay,不许给自己提),CFO 批(CFO 是提单人或主角时 cco 批;pay_decision_code 一份判据,与绩效评估同一份),批准当场写 employees.monthly_salary 与一行带生效日的履历。submitted → approved · rejected(要理由)· withdrawn。不看审批开关:永远等人批,从不 auto_approved,不挡关审批。生效日落在已过账或挂着在途工资申请的工资期里按名拒(提交与批准各判一次)。一个人同一时刻只有一次在途调薪(跨绩效评估)。只改已有的月薪;第一份月薪只经 set_initial_salary。';

COMMENT ON COLUMN public.salary_change_requests.snapshot IS
    'APR-9(grilling Q6):提交那一刻的 {monthly_salary, employment_status}。批准时与活数再比,不一样 → SALARY_CHANGED_SINCE_REQUEST,申请仍在等。';

COMMENT ON COLUMN public.salary_change_requests.decided_via IS
    'APR-9:批(或驳回)这一张时用的那个码 —— action.approve_review(CFO)或 action.hr_reviews(CFO 这个人是提单人或主角时的 cco)。由 pay_decision_code 在决定那一刻算出。';

CREATE UNIQUE INDEX salary_change_requests_one_open
    ON public.salary_change_requests (employee_id) WHERE status = 'submitted';
CREATE INDEX salary_change_requests_employee_id_rel ON public.salary_change_requests (employee_id);

ALTER TABLE public.salary_change_requests ENABLE ROW LEVEL SECURITY;

-- 读:两个码同时成立(人事模块 + 看得见工资)。写:一条策略都不给 —— 只经 submit / decide / withdraw
-- (全是 SECURITY DEFINER)。屏幕读 salary_change_requests_visible()(带提单人 / 决定人邮箱与"我能不能批")。
CREATE POLICY "salary_change_requests select by permission" ON public.salary_change_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text) AND has_permission('data.view_pay'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.salary_change_requests FROM anon;
