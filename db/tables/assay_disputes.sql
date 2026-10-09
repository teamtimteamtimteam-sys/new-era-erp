-- db/tables/assay_disputes.sql
-- MES-6a-1(2026-10-09,MES-0 功能 16 · Q62 · Q63;MES-6a Step 0 Q16–Q23,Tim):【一次化验争议】—— 我们的结果与对手方的结果对不上,
--   有人把它正式立起来,等一个仲裁(或撤回)。
--
--   【三态】open → resolved | withdrawn,只经函数(Q16):
--     open       open_assay_dispute(module.quality.edit)—— 同一批的一份 ours 与一份 counterparty,理由必填;一批同时最多一件开着的。
--     resolved   resolve_assay_dispute(action.apply_assay —— 今天应用化验的人;Q13)—— 点名【哪一份说了算】(同一批的任何一份:
--                我们的、对手方的、或仲裁的)并写一句说明。★ 它【什么都不应用】(Q19):说了算的那一份照常经 apply_assay_result
--                → CFO 批的定价申请(进料)或 apply_output_assay / 结算(产出)。没有自动的取平均、各让一半 —— 没有人给过那条规矩。
--     withdrawn  withdraw_assay_dispute(module.quality.edit),理由必填。
--   【开着的时候挡住什么】(Q18 · Q21)进料:apply_assay_result 与 preview_assay_price 按名拒 ASSAY_DISPUTE_OPEN,
--     receipt_price_post_internal 拒过账一张来源是化验的定价申请(一张在等的申请的指纹里没有争议这一项,所以批准那一刻再看一次);
--     手工定价与按已承诺条款改价照常(一个暂定价不是 Q62 说的"最终改价")。产出:sale_settlement_compute 按名拒。
--   【容差在案】limit_pct_at 在立案那一刻抄下:卖方 = 指了销售单时那张单的合同副本(splitting_limit_pct);买方 = 空 ——
--     买方合同今天不带结算口径(Q62:"limit not set")。fee_rule_at 同理抄 arbitration_fee_rule(V14,只卖方合同有)。
--   【逐元素的差】不存,由 assay_dispute_metals 现算(Q16)。
--   【仲裁】umpire_sample_id / umpire_assay_id 开着时经 record_dispute_umpire 记(可选)。
--   【仲裁费】是一张普通的未付费用单,付给那家实验室在供应商表里的那一户(laboratories.supplier_id,Q22 · Q23),
--     经 link_dispute_fee 挂在这里;对手方该担的那一份【只算出来给人看】(assay_dispute_rows),不收 —— 收它(应收或结算扣减)
--     等指数定价 §9 与第一件真争议。付那张费用单照常要那户供应商已批准(PAYMENT_REQUEST_SUPPLIER_BLOCKED)。
--   【没有单据编号】(MES-0 Q53 没给它前缀;Q41)—— 屏幕上按批号 + 立案时刻认。
--   写只经上面那几支 SECURITY DEFINER 函数 —— 表上一条写策略都没有。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.assay_disputes (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id      uuid REFERENCES public.inbound_batches (id),
    output_batch_id       uuid REFERENCES public.output_batches (id),
    our_assay_id          uuid NOT NULL REFERENCES public.assay_results (id),
    counterparty_assay_id uuid NOT NULL REFERENCES public.assay_results (id),
    -- 卖方可选:哪一张销售单的合同说了容差与仲裁费的分摊(只有产出批有销售单)
    sales_order_id        uuid REFERENCES public.sales_orders (id),
    status                text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'withdrawn')),
    opening_reason        text NOT NULL CHECK (btrim(opening_reason) <> ''),
    limit_pct_at          numeric CHECK (limit_pct_at IS NULL OR (limit_pct_at > 0 AND limit_pct_at <= 100)),
    fee_rule_at           text CHECK (fee_rule_at IS NULL OR fee_rule_at IN
                                      ('loser_pays', 'equal', 'further_from_umpire_pays', 'buyer', 'seller')),
    umpire_sample_id      uuid REFERENCES public.samples (id),
    umpire_assay_id       uuid REFERENCES public.assay_results (id),
    governing_assay_id    uuid REFERENCES public.assay_results (id),
    resolution_note       text,
    resolved_at           timestamptz,
    resolved_by           uuid,
    withdrawn_at          timestamptz,
    withdrawn_by          uuid,
    withdraw_reason       text,
    fee_expense_id        uuid REFERENCES public.expenses (id),
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid DEFAULT auth.uid(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            uuid,
    CONSTRAINT assay_disputes_one_parent CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT assay_disputes_sales_order_on_output CHECK (sales_order_id IS NULL OR output_batch_id IS NOT NULL),
    CONSTRAINT assay_disputes_two_assays CHECK (our_assay_id <> counterparty_assay_id),
    -- 【状态与它的证据必须同时成立】(配料计划、工单那几条 CHECK 的同一个理由:约束对任何写入者都成立)
    CONSTRAINT assay_disputes_resolved_consistent CHECK (
        (status = 'resolved') = (resolved_at IS NOT NULL)
        AND (resolved_at IS NULL) = (governing_assay_id IS NULL)
        AND (resolved_at IS NULL OR btrim(COALESCE(resolution_note, '')) <> '')),
    CONSTRAINT assay_disputes_withdrawn_consistent CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL OR btrim(COALESCE(withdraw_reason, '')) <> ''))
);

CREATE INDEX assay_disputes_inbound_batch_id_rel ON public.assay_disputes (inbound_batch_id);
CREATE INDEX assay_disputes_output_batch_id_rel ON public.assay_disputes (output_batch_id);
CREATE INDEX assay_disputes_our_assay_id_rel ON public.assay_disputes (our_assay_id);
CREATE INDEX assay_disputes_counterparty_assay_id_rel ON public.assay_disputes (counterparty_assay_id);
CREATE INDEX assay_disputes_sales_order_id_rel ON public.assay_disputes (sales_order_id);
CREATE INDEX assay_disputes_umpire_sample_id_rel ON public.assay_disputes (umpire_sample_id);
CREATE INDEX assay_disputes_umpire_assay_id_rel ON public.assay_disputes (umpire_assay_id);
CREATE INDEX assay_disputes_governing_assay_id_rel ON public.assay_disputes (governing_assay_id);
CREATE INDEX assay_disputes_fee_expense_id_rel ON public.assay_disputes (fee_expense_id);
-- 一批同时最多一件开着的争议(函数里先按名拒 ASSAY_DISPUTE_ALREADY_OPEN,唯一索引是第二道)
CREATE UNIQUE INDEX uq_assay_disputes_one_open_inbound ON public.assay_disputes (inbound_batch_id)
    WHERE status = 'open' AND inbound_batch_id IS NOT NULL;
CREATE UNIQUE INDEX uq_assay_disputes_one_open_output ON public.assay_disputes (output_batch_id)
    WHERE status = 'open' AND output_batch_id IS NOT NULL;

COMMENT ON TABLE public.assay_disputes IS
    'MES-6a-1:一次化验争议 —— 同一批的一份我们的结果与一份对手方的结果。open → resolved(点名哪一份说了算,action.apply_assay;什么都不应用)| withdrawn(理由必填)。开着时进料那一侧的应用化验、试算与化验来源的定价申请过账按名拒 ASSAY_DISPUTE_OPEN,卖方结算同样;手工与按已承诺条款的改价照常。容差与仲裁费分摊在立案时从销售单的合同副本抄下(买方为空 = limit not set)。逐元素的差由 assay_dispute_metals 现算。仲裁费是一张普通的未付费用单,付给实验室在供应商表里那一户。';
COMMENT ON COLUMN public.assay_disputes.limit_pct_at IS
    '立案那一刻在案的分歧容差(百分点):卖方 = 指了销售单时那张单的合同副本里的 splitting_limit_pct;买方或没指销售单 = 空,屏幕上是 limit not set(MES-0 Q62)。合同以后改了不回头改它。';
COMMENT ON COLUMN public.assay_disputes.fee_rule_at IS
    '立案那一刻在案的仲裁费分摊规则(V14,contract_settlement_terms.arbitration_fee_rule 的副本):loser_pays · equal · further_from_umpire_pays · buyer · seller;空 = Not yet set。';
COMMENT ON COLUMN public.assay_disputes.governing_assay_id IS
    '结案时点名说了算的那一份(同一批的任何一份:我们的、对手方的或仲裁的)。点名【不应用】它 —— 它照常经应用化验与定价申请(进料)或结算(产出)。';
COMMENT ON COLUMN public.assay_disputes.fee_expense_id IS
    '仲裁费那一张费用单(普通、未付;付给实验室在供应商表里那一户 —— laboratories.supplier_id)。付它照常要那户供应商已批准。';

ALTER TABLE public.assay_disputes ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或那一批自己那一页的查看码(Q11 —— 批次与化验页上的争议横幅;卖方结算以 module.output.view 读它,
--   所以 sale_settlement_compute 的那一道拒绝对一个过得了它第二道闸的读者【不会】因为读不到而放过去)。写:一条策略都不给。
CREATE POLICY "assay_disputes select by permission" ON public.assay_disputes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text)
        OR (inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));
GRANT SELECT ON public.assay_disputes TO authenticated;
REVOKE ALL ON public.assay_disputes FROM anon;
