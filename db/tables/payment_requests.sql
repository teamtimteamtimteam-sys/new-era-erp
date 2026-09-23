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
--   ★ Batch B(2026-09-23,Tim 的 Q15 / Batch B grilling Q2–Q4)加四种,都【没有收款人】:
--   bank_transfer           —— 一笔行内转账。存 record_bank_transfer 的那组参数。
--   bank_transfer_reversal  —— 冲销一笔转账(transfer_id);冲销日在执行时给。
--   wht_remittance          —— 缴一个代扣月的预提税。金额是【提交那一刻】从
--                              wht_liability_by_month 推导出来的数,执行时推导值变了就按名拒。
--   wht_remittance_reversal —— 冲销一笔缴纳(wht_remittance_id);冲销日在执行时给。
--   审批与付款两种完全相同:财务提,CFO 批每一张,财务执行;分录只在执行那一刻过账。
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
    kind               text NOT NULL CHECK (kind IN ('payment_out', 'payment_reversal', 'bank_transfer', 'bank_transfer_reversal', 'wht_remittance', 'wht_remittance_reversal')),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'withdrawn', 'approved', 'rejected', 'paid')),
    -- ── 收款人(payment_out 由申请人给;payment_reversal 从原付款抄)──────────
    -- Batch B:转账与代扣税两族【没有收款人】—— 为 NULL(见 counterparty_shape)
    counterparty_type  text CHECK (counterparty_type IN ('supplier', 'employee', 'customer')),
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
    -- ── PAY-REQ-1 Batch B(ALTER 加的列,在表尾)────────────────────────────────
    -- 转账:bank_account_code 是【转出】户,to_account_code 是转入户;amount_ccy 是转出
    -- 金额(转出户本币),amount_in 是转入金额(转入户本币)—— 两边都照水单。
    to_account_code    text,
    amount_in          numeric CHECK (amount_in IS NULL OR amount_in > 0),
    bank_reference     text,
    transfer_id        uuid REFERENCES public.bank_transfers (id) ON DELETE RESTRICT,
    -- 代扣税:哪一个代扣月、IRAS 回执号;冲销那一种指着原缴纳
    period_month       date CHECK (period_month IS NULL OR period_month = date_trunc('month', period_month)::date),
    filed_reference    text,
    wht_remittance_id  uuid REFERENCES public.wht_remittances (id) ON DELETE RESTRICT,
    -- 执行结果:四种新申请都记它过账的那张分录;转账另记它生出来的那一行转账
    result_transfer_id      uuid REFERENCES public.bank_transfers (id) ON DELETE RESTRICT,
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    CONSTRAINT payment_requests_counterparty_shape CHECK (
        (counterparty_type IS NULL AND num_nonnulls(supplier_id, employee_id, customer_id) = 0)
        OR
        (num_nonnulls(supplier_id, employee_id, customer_id) = 1
        AND (counterparty_type <> 'supplier' OR supplier_id IS NOT NULL)
        AND (counterparty_type <> 'employee' OR employee_id IS NOT NULL)
        AND (counterparty_type <> 'customer' OR customer_id IS NOT NULL))),
    CONSTRAINT payment_requests_kind_shape CHECK (
        (kind = 'payment_out' AND payment_id IS NULL AND planned_date IS NOT NULL
             AND counterparty_type IN ('supplier', 'employee')
             AND num_nonnulls(to_account_code, amount_in, transfer_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'payment_reversal' AND payment_id IS NOT NULL AND planned_date IS NULL
             AND jsonb_array_length(allocations) = 0 AND btrim(COALESCE(notes, '')) <> ''
             AND num_nonnulls(to_account_code, amount_in, transfer_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'bank_transfer' AND counterparty_type IS NULL AND planned_date IS NOT NULL
             AND bank_account_code IS NOT NULL AND to_account_code IS NOT NULL AND amount_in IS NOT NULL
             AND jsonb_array_length(allocations) = 0
             AND num_nonnulls(payment_id, transfer_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'bank_transfer_reversal' AND counterparty_type IS NULL AND transfer_id IS NOT NULL
             AND planned_date IS NULL AND jsonb_array_length(allocations) = 0
             AND btrim(COALESCE(notes, '')) <> ''
             AND num_nonnulls(payment_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'wht_remittance' AND counterparty_type IS NULL AND planned_date IS NOT NULL
             AND period_month IS NOT NULL AND btrim(COALESCE(filed_reference, '')) <> ''
             AND bank_account_code IS NOT NULL AND jsonb_array_length(allocations) = 0
             AND num_nonnulls(payment_id, to_account_code, amount_in, transfer_id, wht_remittance_id) = 0)
        OR
        (kind = 'wht_remittance_reversal' AND counterparty_type IS NULL AND wht_remittance_id IS NOT NULL
             AND planned_date IS NULL AND jsonb_array_length(allocations) = 0
             AND btrim(COALESCE(notes, '')) <> ''
             AND num_nonnulls(payment_id, to_account_code, amount_in, transfer_id) = 0)),
    CONSTRAINT payment_requests_allocations_array CHECK (jsonb_typeof(allocations) = 'array'),
    -- 驳回要理由;决定人与决定时刻同有同无(审批关着时生下来就 approved,两者皆空)
    CONSTRAINT payment_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT payment_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT payment_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
    -- 执行过 ⇔ 付款人与时刻同有,且【这一种该有的那个结果】也在:
    -- 付款两种 → result_payment_id;另外四种 → result_journal_entry_id(转账另加 result_transfer_id)。
    CONSTRAINT payment_requests_paid_shape CHECK (
        (status = 'paid') = (paid_at IS NOT NULL)
        AND (paid_at IS NULL) = (paid_by IS NULL)
        AND CASE WHEN kind IN ('payment_out', 'payment_reversal')
                 THEN (result_payment_id IS NULL) = (paid_at IS NULL)
                      AND result_journal_entry_id IS NULL AND result_transfer_id IS NULL
                 ELSE result_payment_id IS NULL
                      AND (result_journal_entry_id IS NULL) = (paid_at IS NULL)
                      AND (result_transfer_id IS NULL) = (kind <> 'bank_transfer' OR paid_at IS NULL)
            END)
);

COMMENT ON TABLE public.payment_requests IS
    'PAY-REQ-1:付款申请 —— 钱离开之前的在途态(Tim:钱离开之前要先批)。submitted → approved(CFO,每一张都批、不分档)→ paid(财务;分录只在这一刻过账)。另有 rejected(要理由)与 withdrawn。审批关着时生下来就是 approved(auto_approved,与采购单同形)。六种:payment_out 存 record_payment 的那组参数;payment_reversal 冲销一笔已记账的付款(收款或出款都算);Batch B 加 bank_transfer / bank_transfer_reversal / wht_remittance / wht_remittance_reversal(没有收款人;代扣税的金额冻结提交那一刻的推导值)。提单人永远不能批(按人认)。approved 也可撤回:一张付不出去的申请不许永远占着它要付的单据。';

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
-- Batch B:一笔转账 / 一笔代扣税缴纳同时只能有一张未了结的冲销申请;一个代扣月同时只能有一张未了结的缴纳申请
CREATE UNIQUE INDEX payment_requests_one_open_transfer_reversal
    ON public.payment_requests (transfer_id)
    WHERE kind = 'bank_transfer_reversal' AND status IN ('submitted', 'approved');
CREATE UNIQUE INDEX payment_requests_one_open_wht_month
    ON public.payment_requests (period_month)
    WHERE kind = 'wht_remittance' AND status IN ('submitted', 'approved');
CREATE UNIQUE INDEX payment_requests_one_open_wht_reversal
    ON public.payment_requests (wht_remittance_id)
    WHERE kind = 'wht_remittance_reversal' AND status IN ('submitted', 'approved');
CREATE INDEX payment_requests_transfer_id_rel ON public.payment_requests (transfer_id);
CREATE INDEX payment_requests_wht_remittance_id_rel ON public.payment_requests (wht_remittance_id);
CREATE INDEX payment_requests_result_transfer_id_rel ON public.payment_requests (result_transfer_id);
CREATE INDEX payment_requests_result_journal_entry_id_rel ON public.payment_requests (result_journal_entry_id);
CREATE INDEX payment_requests_code_trgm ON public.payment_requests USING gin (code extensions.gin_trgm_ops);

ALTER TABLE public.payment_requests ENABLE ROW LEVEL SECURITY;

-- 读:财务模块。写:一条策略都不给 —— 只经 submit / withdraw / decide / pay 五支函数。
CREATE POLICY "payment_requests select by permission" ON public.payment_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.payment_requests FROM anon;
