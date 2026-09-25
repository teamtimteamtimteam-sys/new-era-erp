-- db/tables/warehouse_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-7(2026-09-25):注销批次、加工回滚、作废销毁证书 —— 仓库提,CFO 批每一张,批准当场生效
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md「删除批次 · 加工回滚 · 作废销毁证书 | 仓库提 | CFO」):不分档,
-- 批准之前什么都不发生。ROLE-1 Batch 3b 的过渡(仓库一步做完)到此结束。
--
-- 【一张表,四种】(APR-7 grilling Q2)—— 每一种一个主体列,由 kind_shape 钉住"恰好那一列非空":
--   write_off_inbound  inbound_batch_id —— 注销一张还有料、或挂着已签发证书的进料批(Q1)
--   write_off_output   output_batch_id  —— 注销一张还有料的产出批(Q1)
--   rollback           run_id           —— 回滚一张加工单
--   cod_void           cod_id           —— 作废一张已签发的销毁证书
--   空批(没有料、也没有已签发的证书)不经这里:仓库照旧一步删掉 —— 它既不动库存、也不动价值(Q1)。
--
-- 【生命周期】与 APR-5a / APR-6 同形
--   submitted ──批准(当场生效)──▶ approved
--       ├──驳回(要理由)─────────▶ rejected
--       └──撤回──────────────────▶ withdrawn
--   · 提:仓库,按种类各一个码 —— action.batch_write_off · action.processing_rollback · action.issue_cod。
--     提交时按批准那一刻会走的同一条路【试跑】一遍(warehouse_request_dry_run):还欠着供应商的钱、
--     挂着订单预留、产出已经动过、证书不是已签发 —— 全按原话拒,什么都不留下。
--     审批关着时【生下来就是 approved】并当场生效,留痕写 auto_approved。
--   · 批:CFO(二级,不分档)。门 module.finance.view + data.view_prices(Q8)。提单人永远不能批(按人认);
--     提单人之外没人批得动 → 提交就拒 WAREHOUSE_REQUEST_NO_OTHER_DECIDER。
--   · 撤回:提单人本人(按人认),或持该种类那个码的人。撤回不写 approval_log。
--
-- 【在等的时候冻结什么】(Q3)
--   · 注销的那一批、回滚那张单的每一张产出批:任何一条库存流水(加工投料、销售、预留、转移、暂扣、盘点)
--     按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH(guard_warehouse_request_freeze,挂在 inventory_movements 上);
--     进料批上也不许再开定价申请(同一支守卫,挂在 receipt_price_requests 上)。
--   · 一个批次、它的证书、消耗它的加工单,同一时刻只许挂【一张】在等的申请(warehouse_request_touches
--     一份判据;提交时按名拒 WAREHOUSE_REQUEST_OPEN,一步删空批的那扇门也问它)。
--
-- 【日期与金额】(Q4)批准那一天:流水与分录都落在批准日(注销触发器本来就取 deleted_at 与 CURRENT_DATE)。
--   amount_base 本位币 = 生效时过出来那几张分录的借方合计 —— 提交时由试跑算出,批准后改写成实际过账额。
--   没有计价的批次注销、证书作废:0(它们不动价值,这是一个真的零,不是"不知道")。
-- 【谁记在行上】(Q6)deleted_by / voided_by = 提单人(说"这批货没了"的那个人);CFO 的批准在本行
--   decided_by 与 approval_log 上。过出来的分录 created_by 是批准的 CFO(过账发生在批准那一刻)。
-- 【snapshot】提交时冻下来给 CFO 读的那一组(批号、物料、供应商、数量、加工日、是否落在已锁期间、
--   会被一并作废的证书号)—— CFO 不持 action.issue_cod,读不到证书表;金额不在里面。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE TABLE public.warehouse_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind               text NOT NULL
        CHECK (kind IN ('write_off_inbound', 'write_off_output', 'rollback', 'cod_void')),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    -- ── 主体:恰好一列 ─────────────────────────────────────────────────────
    inbound_batch_id   uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id    uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    run_id             uuid REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    cod_id             uuid REFERENCES public.certificates_of_destruction (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- 提单人的理由:原样成为 delete_reason / 回滚理由 / void_reason
    reason             text NOT NULL CHECK (btrim(reason) <> ''),
    snapshot           jsonb NOT NULL,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base        numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    -- 批准当场生效:生效的时刻,与过出来的分录(没有计价的注销、证书作废:空数组)
    executed_at        timestamptz,
    result_entry_ids   uuid[] NOT NULL DEFAULT '{}'::uuid[],
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT warehouse_requests_kind_shape CHECK (
        (kind = 'write_off_inbound') = (inbound_batch_id IS NOT NULL)
        AND (kind = 'write_off_output') = (output_batch_id IS NOT NULL)
        AND (kind = 'rollback') = (run_id IS NOT NULL)
        AND (kind = 'cod_void') = (cod_id IS NOT NULL)),
    -- 恰好一个主体 —— 与 kind_shape 同一件事的另一种写法,留着它是给关系图读的:document_relations 按
    -- num_nonnulls(...) = 1 认出"这四列同一行上只有一列",于是不会把本表读成批次 ↔ 加工单 ↔ 证书之间的桥
    -- (fixture 103 A 臂)。
    CONSTRAINT warehouse_requests_one_subject CHECK (num_nonnulls(inbound_batch_id, output_batch_id, run_id, cod_id) = 1),
    CONSTRAINT warehouse_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT warehouse_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT warehouse_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT warehouse_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.warehouse_requests IS
    'APR-7:注销批次(write_off_inbound / write_off_output)、加工回滚(rollback)、作废销毁证书(cod_void)的申请 —— 仓库提,CFO 批每一张,不分档,批准当场生效。submitted → approved(CFO)· rejected(要理由)· withdrawn(提单人本人或该种类的码)。审批关着时生下来就是 approved 并当场生效(auto_approved)。在等的时候:主体批次上的任何库存流水按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH;一个批次、它的证书、消耗它的加工单同一时刻只挂一张在等的申请(WAREHOUSE_REQUEST_OPEN)。空批(没有料也没有已签发证书)不经这里。';

COMMENT ON COLUMN public.warehouse_requests.amount_base IS
    'APR-7:本位币 = 生效时过出来那几张分录的借方合计。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账额(写进 approved 留痕)。没有计价的注销与证书作废是 0 —— 它们不动价值。';

COMMENT ON COLUMN public.warehouse_requests.snapshot IS
    'APR-7(grilling Q8):提交时冻下来给 CFO 读的那一组 —— 批号、物料、供应商、数量、加工日、是否落在已锁期间、会被一并作废的证书号。CFO 读不到证书表(它的读策略是 action.issue_cod),所以要在这里。【不含金额】—— 金额在 amount_base,经 warehouse_requests_visible() 对没有 data.view_prices 的读者给 NULL。';

CREATE UNIQUE INDEX warehouse_requests_one_open_inbound
    ON public.warehouse_requests (inbound_batch_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX warehouse_requests_one_open_output
    ON public.warehouse_requests (output_batch_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX warehouse_requests_one_open_run
    ON public.warehouse_requests (run_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX warehouse_requests_one_open_cod
    ON public.warehouse_requests (cod_id) WHERE status = 'submitted';
CREATE INDEX warehouse_requests_open ON public.warehouse_requests (kind) WHERE status = 'submitted';
CREATE INDEX warehouse_requests_inbound_batch_id_rel ON public.warehouse_requests (inbound_batch_id);
CREATE INDEX warehouse_requests_output_batch_id_rel ON public.warehouse_requests (output_batch_id);
CREATE INDEX warehouse_requests_run_id_rel ON public.warehouse_requests (run_id);
CREATE INDEX warehouse_requests_cod_id_rel ON public.warehouse_requests (cod_id);

ALTER TABLE public.warehouse_requests ENABLE ROW LEVEL SECURITY;

-- 读:凭证页那一个码(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。屏幕不直接读本表,
-- 读 warehouse_requests_visible()(仓库看得见自己的申请,金额按 data.view_prices 给)。写:一条策略都不给 ——
-- 只经 submit_* · decide_warehouse_request · withdraw_warehouse_request(全是 SECURITY DEFINER)。
CREATE POLICY "warehouse_requests select by permission" ON public.warehouse_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.warehouse_requests FROM anon;
