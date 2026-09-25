-- db/tables/invoice_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-5a(2026-09-25):贷项通知与作废发票的申请 —— 财务提,CFO 批每一张,批准当场过账
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md「贷项通知、作废发票 | 财务 | CFO」,[LC] APR-5):财务提,CFO 批每一张,
-- 不分档,没有门槛。批准那一刻就过账(APR-5 grilling Q9,收货定价申请的形状)—— 没有单独的"执行"
-- 一步,所以状态里没有 executed。
--
-- 【生命周期】
--   submitted ──批准(当场过账)──▶ approved
--       ├──驳回(要理由)──────────▶ rejected
--       └──撤回───────────────────▶ withdrawn
--   · 提:财务(module.finance.edit)。两种:
--       credit_note  submit_credit_note_request(发票, 凭证日, 理由, 行)—— 与 create_credit_note 同一组参数
--       void         submit_invoice_void_request(发票, 理由, 冲销日)   —— 与 void_invoice 同一组参数
--     审批关着时【生下来就是 approved】并当场过账,留痕写 auto_approved(PAY-REQ-1 的 Q8 同形)。
--   · 批:CFO(二级,不分档)。门 module.finance.view + data.view_prices(与付款申请同一对码:
--     edit 是提单的码;批的人必须看得见他批的那个数)。提单人永远不能批(forbid_self_approval,按人认)。
--   · 撤回:提单人本人(按人认),或任何持 module.finance.edit 的人(Q9)。撤回写在本行上(谁、何时、
--     为什么),【不】写 approval_log —— 撤回不是一次决定(付款、工资、收货定价申请同一条)。
--
-- 【冻结的是什么】提交时给的那一组参数,原样:凭证日 / 冲销日(doc_date)、理由、贷项的行(lines)。
--   批准时按它们过账,日期就是提单人填的那一天(Q9「on the frozen date」)—— 它决定 GST 与期间。
--   不冻指纹:发票本身除了 issued → void 什么都改不了(guard_invoice_mutation),而等待期间唯一会变的
--   是【收款】—— 收款从不被挡(Q10),批准时的过账本身会按引擎原话拒(CN_EXCEEDS_OPEN ·
--   INVOICE_HAS_SETTLEMENTS · CN_INVOICE_FULLY_SETTLED)。
--
-- 【金额】amount_base 本位币:贷项 = 那张贷项分录的借方合计(净额 + 退回的税,= 1100 解除的数);
--   作废 = 发票的 total_base。提交时由试跑算出,批准后改写成实际过账的那一个。
--
-- 【一张发票同时只挂一张在等的申请】(invoice_requests_one_open_per_invoice;函数里先按名拒
--   INVOICE_REQUEST_OPEN,唯一索引是第二道)。
--
-- 【没有自己的单据编号】label = 发票编号 · credit note #n / void #n,给留痕与屏幕读;不进 document_types
--   (与 payroll_requests、receipt_price_requests 同一条理由)。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE TABLE public.invoice_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id              uuid NOT NULL REFERENCES public.invoices (id) ON DELETE RESTRICT,
    kind                    text NOT NULL CHECK (kind IN ('credit_note', 'void')),
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label                   text NOT NULL,
    -- ── 冻结的那一组参数 ─────────────────────────────────────────────────────
    -- 贷项:凭证日(必填);作废:冲销日(不带税的 sale 型发票没有分录可冲,为 NULL)
    doc_date                date,
    reason                  text NOT NULL CHECK (btrim(reason) <> ''),
    -- 贷项的行,原样(create_credit_note 的 p_lines);作废为 NULL
    lines                   jsonb,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base             numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    -- 批准当场过账:生出来的贷项通知,与那一张分录(贷项分录 / 作废的冲销分录;
    -- 不带税的 sale 型发票作废没有分录)
    result_credit_note_id   uuid REFERENCES public.credit_notes (id) ON DELETE RESTRICT,
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    withdraw_reason         text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT invoice_requests_kind_shape CHECK (
        (kind = 'credit_note') = (lines IS NOT NULL)
        AND (kind <> 'credit_note' OR doc_date IS NOT NULL)),
    CONSTRAINT invoice_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT invoice_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT invoice_requests_approved_shape CHECK (
        (status = 'approved' AND kind = 'credit_note') = (result_credit_note_id IS NOT NULL)
        AND (result_journal_entry_id IS NULL OR status = 'approved')),
    CONSTRAINT invoice_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.invoice_requests IS
    'APR-5a:贷项通知与作废发票的申请(Tim 的矩阵:财务提,CFO 批每一张,不分档;批准当场过账)。submitted → approved(CFO,当场按冻结的日期过账)· rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。冻结提交时的参数(doc_date · reason · lines)。审批关着时生下来就是 approved 并当场过账(auto_approved)。一张发票同时只挂一张在等的申请。';

COMMENT ON COLUMN public.invoice_requests.amount_base IS
    'APR-5a:本位币。贷项 = 贷项分录的借方合计(净额 + 退回的税);作废 = 发票 total_base。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账的那一个(写进 approved 留痕)。';

CREATE UNIQUE INDEX invoice_requests_one_open_per_invoice
    ON public.invoice_requests (invoice_id)
    WHERE status = 'submitted';
CREATE INDEX invoice_requests_invoice_id_rel ON public.invoice_requests (invoice_id);
CREATE INDEX invoice_requests_result_credit_note_id_rel ON public.invoice_requests (result_credit_note_id);
CREATE INDEX invoice_requests_result_journal_entry_id_rel ON public.invoice_requests (result_journal_entry_id);

ALTER TABLE public.invoice_requests ENABLE ROW LEVEL SECURITY;

-- 读:发票的门(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。写:一条策略都不给 ——
-- 只经 submit_credit_note_request · submit_invoice_void_request · decide_invoice_request ·
-- withdraw_invoice_request(全是 SECURITY DEFINER)。
CREATE POLICY "invoice_requests select by permission" ON public.invoice_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.invoice_requests FROM anon;
