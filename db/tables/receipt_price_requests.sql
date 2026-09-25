-- db/tables/receipt_price_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- ROLE-1 Batch 4b(2026-09-25):收货定价的申请 —— 一个价格只有 CFO 批了才进账
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md「收货定价与改价 | 财务 | CFO」,[LC]):财务提,CFO 批每一张,
-- 不分档;批准那一刻就过账(Tim 的 Q2 (A))—— 没有单独的"执行"一步,所以状态里没有 executed。
--
-- 【生命周期】
--   submitted ──批准(当场过账)──▶ approved
--       ├──驳回(要理由)──────────▶ rejected
--       └──撤回───────────────────▶ withdrawn
--   · 提:四个来源(Tim 的 Q6)——
--       manual           定价面板(set_inbound_unit_price,action.price_receipts)
--       committed_terms  按已承诺条款改价(reprice_from_committed_terms,同一个码)
--       desk             收货台建单时带的价(create_inbound_batch,同一个码)
--       assay            应用化验(apply_assay_result,action.apply_assay;提单人 = 按应用的那个人)
--     审批关着时【生下来就是 approved】并当场过账,留痕写 auto_approved(PAY-REQ-1 的 Q8 同形)。
--   · 批:CFO(require_approver_for(2),不分档)。门 module.inbound.view + data.view_purchase_prices
--     (Tim 的 Q2)。提单人永远不能批(forbid_self_approval,按人认)。
--   · 撤回:提单人本人(按人认),或任何持 action.price_receipts 的人(Tim 的 Q7);撤销应用一份化验
--     也撤回它那张在等的申请;一份新化验取代它时同样(Tim 的 Q5)。撤回写在本行上(谁、何时、为什么),
--     【不】写 approval_log —— 撤回不是一次决定(付款申请、工资申请同一条)。
--
-- 【冻结的是什么】(Tim 的 Q2)
--   unit_price_ccy + currency —— 原币的那个价。本位币价、分录都在【批准那一天】按那天的 tt_sell 算
--   (引擎 reprice_inbound_batch 只认当天的牌价)。所以 amount_base 是【最近一次估算】:提交时按提交日
--   的牌价算、写进 submitted 那一行留痕;批准时按批准日重算、写回本行并写进 approved 那一行留痕
--   (Tim 的 Q4:每一行留痕按它自己那天的牌价)。
--   snapshot = receipt_price_fingerprint(收货):数量、供应商、采购单与采购行、单价、含量、承诺、
--   最近一份已应用的化验。批准时再比一次(RECEIPT_PRICE_CHANGED_SINCE_REQUEST)。牌价不在其中(Q4)。
--
-- 【一张收货同时只挂一张在等的申请】(receipt_price_requests_one_open_per_receipt;
--   函数里先按名拒 RECEIPT_PRICE_REQUEST_OPEN,唯一索引是第二道)。
--
-- 【没有自己的单据编号】label = 收货编号 · price #n(例:IN-2026-0153 · price #1),
--   给留痕与屏幕读;不进 document_types(与 payroll_requests 同一条理由)。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE TABLE public.receipt_price_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id        uuid NOT NULL REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    source                  text NOT NULL CHECK (source IN ('manual', 'committed_terms', 'desk', 'assay')),
    -- 来源是化验时,是哪一份;承诺条款(committed_terms / assay)是哪一份副本
    assay_result_id         uuid REFERENCES public.assay_results (id) ON DELETE RESTRICT,
    commitment_id           uuid REFERENCES public.pricing_term_commitments (id) ON DELETE RESTRICT,
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label                   text NOT NULL,
    -- ── 冻结的那个价(原币)与那一组事实 ──────────────────────────────────────
    unit_price_ccy          numeric NOT NULL CHECK (unit_price_ccy > 0),
    currency                text NOT NULL REFERENCES public.currencies (code),
    snapshot                jsonb NOT NULL,
    -- 提交时的旧本位币单价(首次定价为 NULL)
    old_unit_price          numeric,
    -- |Δ 应付| 本位币,最近一次估算(提交日;批准后 = 实际过账的那一个)
    amount_base             numeric NOT NULL CHECK (amount_base >= 0),
    notes                   text,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    -- 批准当场过账:过账后的本位币单价与那一笔分录(价差为 0 时没有分录)
    posted_unit_price       numeric,
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    withdraw_reason         text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT receipt_price_requests_assay_shape CHECK (
        (source = 'assay') = (assay_result_id IS NOT NULL)),
    CONSTRAINT receipt_price_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT receipt_price_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT receipt_price_requests_approved_shape CHECK (
        (status = 'approved') = (posted_unit_price IS NOT NULL)
        AND (result_journal_entry_id IS NULL OR status = 'approved')),
    CONSTRAINT receipt_price_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.receipt_price_requests IS
    'ROLE-1 Batch 4b:收货定价的申请(Tim 的矩阵:财务提,CFO 批每一张,不分档;批准当场过账)。submitted → approved(CFO,当场按批准日牌价过账)· rejected(要理由)· withdrawn(提单人本人或 action.price_receipts;撤销应用化验、新化验取代时由系统撤回)。来源 manual / committed_terms / desk / assay。冻结原币单价与 snapshot(receipt_price_fingerprint),批准时再比(RECEIPT_PRICE_CHANGED_SINCE_REQUEST)。审批关着时生下来就是 approved 并当场过账(auto_approved)。一张收货同时只挂一张在等的申请。';

COMMENT ON COLUMN public.receipt_price_requests.amount_base IS
    'ROLE-1 Batch 4b(Tim 的 Q4):|Δ 应付| 本位币 = |round(数量 × (新本位币单价 − 旧), 2)|,由引擎试跑算出。提交时按提交日牌价(写进 submitted 留痕);批准时按批准日牌价重算并写回(= 实际过账额,写进 approved 留痕)。';

CREATE UNIQUE INDEX receipt_price_requests_one_open_per_receipt
    ON public.receipt_price_requests (inbound_batch_id)
    WHERE status = 'submitted';
CREATE INDEX receipt_price_requests_inbound_batch_id_rel ON public.receipt_price_requests (inbound_batch_id);
CREATE INDEX receipt_price_requests_assay_result_id_rel ON public.receipt_price_requests (assay_result_id);
CREATE INDEX receipt_price_requests_commitment_id_rel ON public.receipt_price_requests (commitment_id);
CREATE INDEX receipt_price_requests_result_journal_entry_id_rel ON public.receipt_price_requests (result_journal_entry_id);

ALTER TABLE public.receipt_price_requests ENABLE ROW LEVEL SECURITY;

-- 读:收货页的门 + 看得见采购价(申请上全是采购价)。写:一条策略都不给 —— 只经
-- 提交(四扇门)、decide / withdraw 与应用 / 撤销化验(全是 SECURITY DEFINER)。
CREATE POLICY "receipt_price_requests select by permission" ON public.receipt_price_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text) AND has_permission('data.view_purchase_prices'::text));

-- APR-7(grilling Q3):一张在等 CFO 的注销申请冻住那一批 —— 上面不许再开定价申请(改价会改注销的价值)。
CREATE TRIGGER trg_receipt_price_requests_warehouse_request_freeze
    BEFORE INSERT ON public.receipt_price_requests
    FOR EACH ROW EXECUTE FUNCTION public.guard_warehouse_request_freeze();

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.receipt_price_requests FROM anon;
