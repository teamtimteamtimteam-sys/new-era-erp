-- db/tables/payment_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- PAY-REQ-1(2026-09-23):付款申请 —— 钱离开之前的那一格在途态
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的裁定:**钱离开之前要先批。** 付款申请 → CFO 批准 → 付款。
-- APR-3 当时把付款从审批里拿掉,原话是「记一笔付款【就是】付款」:payments 的
-- 每一行都意味着分录已过、编号已取、钱已经走了(不可变表,编号无洞)。在那张表上
-- 加一个 'requested' 态,要松开它的不可变守卫,并且改遍每一处 status='posted'
-- 的结算求和 —— 所以申请【另起一张表】,存的是将来要递给引擎的那组参数。
--
-- 【生命周期】
--   submitted ──批准──▶ approved ──付款──▶ paid
--       │                  │
--       ├──驳回(要理由)──▶ rejected
--       └──撤回──────────▶ withdrawn ◀── (approved 也可撤回:见下)
--   · 提:财务(module.finance.edit)。审批关着时【生下来就是 approved】,
--     留痕写 auto_approved(与采购单同形,Tim 的 Q8)。
--   · 批:CFO —— 每一张都批,不分档(require_approver_for(2),不经 approval_level_for)。
--     提单人永远不能批(forbid_self_approval,按人认)。
--   · 付:财务;付款人可以就是提单人(Tim 的 Q3:四眼在"提"与"批"之间)。
--   · 分录只在【付】那一刻过账 —— 提与批都不碰总账。
--
-- 【两种申请】
--   payment_out      —— 一笔出款。存的是 record_payment 的那组参数(收款人、金额、
--                       币种、银行、计划日期、核销行)。付的时候原样递给引擎。
--   payment_reversal —— 冲销一笔已记账的付款(收款或出款都算,Tim 的 Q6)。
--                       金额、币种、收款人从原付款【抄过来】只供审批人看。
--   Batch B 会加银行转账、转账冲销与代扣税缴纳 —— 那时扩 CHECK。
--
-- 【一张单据同时只能挂在一张未了结的申请上】见 payment_request_conflict 与
--   submit_payment_request:两张申请各自都校验得过、合起来超付,是 dry-run
--   看不见的(dry-run 只看已过账的付款)。
--
-- 【approved 也可以撤回 —— 与 grilling Q3 的措辞不同,刻意的】
--   Q3 写的是"只在 submitted 时撤回"。但一张 approved 的申请在它要付的那张单
--   被作废、被别的路径付清之后就再也付不出去,而它仍然占着那张单(上一条)——
--   只许 submitted 撤回,它就会永远卡在那里。撤回不花钱、不过账,只是放弃。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE TABLE public.payment_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code               text NOT NULL UNIQUE,
    kind               text NOT NULL CHECK (kind IN ('payment_out', 'payment_reversal')),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'withdrawn', 'approved', 'rejected', 'paid')),
    -- ── 收款人(payment_out 由申请人给;payment_reversal 从原付款抄)──────────
    counterparty_type  text NOT NULL CHECK (counterparty_type IN ('supplier', 'employee', 'customer')),
    supplier_id        uuid REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    employee_id        uuid REFERENCES public.employees (id) ON DELETE RESTRICT,
    customer_id        uuid REFERENCES public.customers (id) ON DELETE RESTRICT,
    -- ── 冻结的金额(审批人批的就是这个数)─────────────────────────────────────
    amount_ccy         numeric NOT NULL CHECK (amount_ccy > 0),
    currency           text NOT NULL REFERENCES public.currencies (code),
    -- 提交时按计划日试算出来的本位币额 —— 给审批人看、给留痕冻结;真正入账的是付款那一刻的数
    amount_base        numeric NOT NULL,
    -- 跨币种时申请人给的水单成交价(付款时可以换成实际那一个);同币种为 NULL
    fx_rate            numeric CHECK (fx_rate IS NULL OR fx_rate > 0),
    bank_account_code  text,
    planned_date       date,
    allocations        jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- ── 冲销申请要冲的那一笔 ─────────────────────────────────────────────────
    payment_id         uuid REFERENCES public.payments (id) ON DELETE RESTRICT,
    notes              text,
    -- ── 决定与执行 ───────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    paid_at            timestamptz,
    paid_by            uuid,
    result_payment_id  uuid REFERENCES public.payments (id) ON DELETE RESTRICT,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT payment_requests_counterparty_shape CHECK (
        num_nonnulls(supplier_id, employee_id, customer_id) = 1
        AND (counterparty_type <> 'supplier' OR supplier_id IS NOT NULL)
        AND (counterparty_type <> 'employee' OR employee_id IS NOT NULL)
        AND (counterparty_type <> 'customer' OR customer_id IS NOT NULL)),
    CONSTRAINT payment_requests_kind_shape CHECK (
        (kind = 'payment_out' AND payment_id IS NULL AND planned_date IS NOT NULL
             AND counterparty_type IN ('supplier', 'employee'))
        OR
        (kind = 'payment_reversal' AND payment_id IS NOT NULL AND planned_date IS NULL
             AND jsonb_array_length(allocations) = 0 AND btrim(COALESCE(notes, '')) <> '')),
    CONSTRAINT payment_requests_allocations_array CHECK (jsonb_typeof(allocations) = 'array'),
    -- 驳回要理由;决定人与决定时刻同有同无(审批关着时生下来就 approved,两者皆空)
    CONSTRAINT payment_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT payment_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT payment_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
    CONSTRAINT payment_requests_paid_shape CHECK (
        (status = 'paid') = (result_payment_id IS NOT NULL)
        AND (result_payment_id IS NULL) = (paid_at IS NULL)
        AND (paid_at IS NULL) = (paid_by IS NULL))
);

COMMENT ON TABLE public.payment_requests IS
    'PAY-REQ-1:付款申请 —— 钱离开之前的在途态(Tim:钱离开之前要先批)。submitted → approved(CFO,每一张都批、不分档)→ paid(财务;分录只在这一刻过账)。另有 rejected(要理由)与 withdrawn。审批关着时生下来就是 approved(auto_approved,与采购单同形)。两种:payment_out 存 record_payment 的那组参数;payment_reversal 冲销一笔已记账的付款(收款或出款都算)。提单人永远不能批(按人认)。approved 也可撤回:一张付不出去的申请不许永远占着它要付的单据。';

COMMENT ON COLUMN public.payment_requests.amount_base IS
    'PAY-REQ-1:提交时按计划日试算出来的本位币额(dry-run 的返回值)—— 给审批人看、给 approval_log 冻结。真正入账的数是付款那一刻引擎算的那一个(付款日与成交价可以不同),记在 result_payment_id 那一行上。';

CREATE INDEX idx_payment_requests_open ON public.payment_requests (status)
    WHERE status IN ('submitted', 'approved');
CREATE INDEX payment_requests_supplier_id_rel ON public.payment_requests (supplier_id);
CREATE INDEX payment_requests_employee_id_rel ON public.payment_requests (employee_id);
CREATE INDEX payment_requests_customer_id_rel ON public.payment_requests (customer_id);
CREATE INDEX payment_requests_payment_id_rel ON public.payment_requests (payment_id);
CREATE INDEX payment_requests_result_payment_id_rel ON public.payment_requests (result_payment_id);
-- 一笔付款同时只能有一张未了结的冲销申请
CREATE UNIQUE INDEX payment_requests_one_open_reversal
    ON public.payment_requests (payment_id)
    WHERE kind = 'payment_reversal' AND status IN ('submitted', 'approved');
CREATE INDEX payment_requests_code_trgm ON public.payment_requests USING gin (code extensions.gin_trgm_ops);

ALTER TABLE public.payment_requests ENABLE ROW LEVEL SECURITY;

-- 读:财务模块。写:一条策略都不给 —— 只经 submit / withdraw / decide / pay 五支函数。
CREATE POLICY "payment_requests select by permission" ON public.payment_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.payment_requests FROM anon;
