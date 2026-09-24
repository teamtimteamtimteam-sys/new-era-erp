-- db/tables/payroll_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- PAYROLL-APR-1(2026-09-24):工资过账与撤销的申请 —— 过账之前的那一格在途态
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md §5):**工资过账与撤销 —— 财务提,CFO 批每一张,不分档;
-- 批之前什么都不过账。** 付工资、CPF、扣款仍归财务、不再批,但只能跟在一次【批过的】过账后面
-- (付款三支函数本来就要 status = 'posted',而 posted 从此只经批过的申请到达)。
--
-- 【为什么另起一张表,而不是给 payroll_periods 加状态】(grilling Q2)
--   payroll_periods.status 只有 draft / posted,六处在读它(attendance_period_status_rows ·
--   preview_close_financial_year · cash_forecast_data · /me · 月结页 · HR 首页)。
--   申请另起一张表,那六处一个字都不用动 —— 与 payment_requests 同一个理由、同一个形状。
--
-- 【生命周期】
--   submitted ──批准──▶ approved ──执行(过账 / 撤销)──▶ executed
--       │                  │
--       ├──驳回(要理由)──▶ rejected
--       └──撤回──────────▶ withdrawn ◀── (approved 也可撤回,PAY-REQ-1 的第 1 条)
--   · 提:财务(module.hr.edit —— 工资期本来就归这个码)。审批关着时【生下来就是 approved】,
--     留痕写 auto_approved(采购单与付款申请同形)。
--   · 批:CFO —— 每一张都批,不分档(require_approver_for(2),不经 approval_level_for)。
--     提单人永远不能批(forbid_self_approval,按人认)。
--   · 执行:财务按「过账」/「撤销过账」;没有一张【这个期间、这一种】的已批申请,两支函数按名拒
--     (PAYROLL_NEEDS_APPROVED_REQUEST)。分录只在执行那一刻过账 —— 提与批都不碰总账。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ 工资期是【公司的单据】,主角那条腿对谁都不成立(Tim 的 Q1 (A),2026-09-24)★★
-- ════════════════════════════════════════════════════════════════════════════
--   一个工资期里有每一名员工 —— 包括 CFO 自己。拿"主角"去判,CFO 永远批不了任何一期
--   (Step 0 实测:forbid_self_approval 以 tim@ 判主角 = Tim → SELF_APPROVAL_FORBIDDEN|subject;
--   R2 永远不覆盖工资),而二级只有他一个人,于是每个月都卡死。
--   Tim 的理由,记在这里:**CFO 在这一步改不了他自己的月薪** —— 月薪只经绩效评估(Tim 自己的
--   由 cco 批)或调薪申请改动;**要紧的那道控制是"做的人不是批的人"**。
--   所以:subject = NULL(工单的形状);raiser 那条腿照判、按人认 —— 从 admin@ 提的申请,
--   tim@ 批不了(同一个人)。
--   审批页上说出「本期含你自己的工资行」,approval_log 的备注记下它;**不**标 self_decided
--   (approval_log_self_decided_scope 本来也不许,那是同一句裁定的第二道保险)。
--
-- 【两种申请】
--   post     —— 过账一个 draft 的期间。
--   reversal —— 撤销一个 posted 的期间;理由必填(审批人读的就是它,也是撤销分录上的那一句)。
--
-- 【批的是哪一组数 —— 以及它在等待期间被冻住】(grilling Q4)
--   snapshot = payroll_period_fingerprint(期间):五个合计、行数、逐行摘要、发薪日、币种、汇率。
--   申请开着的时候:upsert_payroll_period 按名拒(PAYROLL_REQUEST_OPEN);直连改行、改表头的
--   合计与日期按名拒(PAYROLL_LINES_FROZEN);那个月的考勤不许重开。批准与执行各再比一次
--   (PAYROLL_CHANGED_SINCE_REQUEST)—— 只有属主(迁移、fixture)写得动的那条路也逃不过。
--   ★ 月薪:过账与保存【都不读】employees.monthly_salary(Step 0 读过两支函数体)——
--     等待期间调薪,申请里的数一个都不变;工资行是服务商的数。
--
-- 【一个期间同时只挂一张未了结的申请】(payroll_requests_one_open_per_period)
--
-- 【没有自己的单据编号】申请不是一张有编号的单据,它是【对一个期间】的一次请求;
--   label = 期间编号 · 种类 · 第几次(例:PAY-2026-0002 · post #1),给留痕与屏幕读。
--   不进 document_types:一个编号序列意味着搜索、深链与"每一个码都照样铸"那几份登记,
--   而这里没有一样东西要人按编号去找。
--
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE TABLE public.payroll_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_period_id       uuid NOT NULL REFERENCES public.payroll_periods (id) ON DELETE RESTRICT,
    kind                    text NOT NULL CHECK (kind IN ('post', 'reversal')),
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'withdrawn', 'approved', 'rejected', 'executed')),
    label                   text NOT NULL,
    -- ── 冻结的那一组数(审批人批的就是它)──────────────────────────────────────
    snapshot                jsonb NOT NULL,
    currency                text NOT NULL REFERENCES public.currencies (code),
    fx_rate                 numeric NOT NULL CHECK (fx_rate > 0),
    gross_total             numeric NOT NULL,
    -- 留痕与分档用的金额 = gross_total 折本位币(Tim 的 N4:工资按 gross 路由)
    amount_base             numeric NOT NULL,
    notes                   text,
    -- ── 决定与执行 ───────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    executed_at             timestamptz,
    executed_by             uuid,
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT payroll_requests_reversal_reason CHECK (
        kind <> 'reversal' OR btrim(COALESCE(notes, '')) <> ''),
    CONSTRAINT payroll_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT payroll_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT payroll_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
    CONSTRAINT payroll_requests_executed_shape CHECK (
        (status = 'executed') = (executed_at IS NOT NULL)
        AND (executed_at IS NULL) = (executed_by IS NULL)
        AND (executed_at IS NULL) = (result_journal_entry_id IS NULL))
);

COMMENT ON TABLE public.payroll_requests IS
    'PAYROLL-APR-1:工资过账与撤销的申请(Tim 的矩阵 §5:财务提,CFO 批每一张,不分档;批之前什么都不过账)。submitted → approved(CFO)→ executed(财务按过账 / 撤销;分录只在这一刻过账)。另有 rejected(要理由)与 withdrawn(submitted 或 approved)。审批关着时生下来就是 approved(auto_approved)。工资期是公司的单据:主角那条腿对谁都不成立(Tim 的 Q1 (A)),提单人那条照判、按人认。snapshot 冻结批的那一组数,批准与执行各比一次(PAYROLL_CHANGED_SINCE_REQUEST)。一个期间同时只挂一张未了结的申请。';

COMMENT ON COLUMN public.payroll_requests.amount_base IS
    'PAYROLL-APR-1:gross_total × fx_rate(期间自己的汇率),两位小数 —— approval_log 冻结的金额(Tim 的 N4:工资按 gross 路由;这条链不分档,金额只供审批人读与留痕)。';

CREATE UNIQUE INDEX payroll_requests_one_open_per_period
    ON public.payroll_requests (payroll_period_id)
    WHERE status IN ('submitted', 'approved');
CREATE INDEX payroll_requests_payroll_period_id_rel ON public.payroll_requests (payroll_period_id);
CREATE INDEX payroll_requests_result_journal_entry_id_rel ON public.payroll_requests (result_journal_entry_id);

ALTER TABLE public.payroll_requests ENABLE ROW LEVEL SECURITY;

-- 读:与 payroll_periods 同一个码。写:一条策略都不给 —— 只经 submit / withdraw / decide 与
-- post_payroll_period / unpost_payroll_period 五支函数(全是 SECURITY DEFINER)。
CREATE POLICY "payroll_requests select by permission" ON public.payroll_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.payroll_requests FROM anon;
