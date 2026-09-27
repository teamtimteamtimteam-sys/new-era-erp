-- db/tables/asset_disposal_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-9(2026-09-27):固定资产处置申请 —— 财务提,CFO 批每一张,批准当场处置
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md §4「处置 | 财务 | CFO」):不分档,批准之前什么都不发生。
-- APR-4 把处置从审批扩展里拿掉,理由是它【没有等人的那一格】(dispose_fixed_asset 一步过账并置 disposed);
-- 这张表就是那一格。dispose_fixed_asset 从此只会按名拒(ASSET_DISPOSAL_NEEDS_REQUEST)。
--
-- 【生命周期】APR-7 的形状(Q10)
--   submitted ──批准(当场处置)──▶ approved
--       ├──驳回(要理由)─────────▶ rejected
--       └──撤回──────────────────▶ withdrawn
--   · 提:财务(module.finance.edit —— 处置原来的门)。提交时按批准那一刻会走的同一条路试跑一遍
--     (asset_disposal_dry_run):零成本的卡、收款却没给银行科目 —— 全按原话拒。
--     审批关着时【生下来就是 approved】并当场处置,留痕写 auto_approved。
--   · 批:CFO(二级,不分档)。门 module.finance.view + data.view_prices(与 APR-7 同一对码)。
--     提单人永远不能批(按人认);提单人之外没人批得动 → 提交就拒 ASSET_DISPOSAL_NO_OTHER_DECIDER。
--     一台资产是公司的,主角那条腿对谁都不成立(工单的形状)。
--   · 撤回:提单人本人(按人认),或持 module.finance.edit 的人。撤回不写 approval_log。
--
-- 【日期与金额】(Q7)批准那一天:处置日 = 批准日,累计折旧、损益按批准那一刻的活数算 —— 所以期间锁
--   永远咬不到一张在等的处置。收款与银行科目提交时冻结(提单人说的那一组)。
--   estimate = 提交时试跑的那一组(处置日、解除的成本、解除的累计折旧、收款、损益),
--   result   = 批准时真的过出来的那一组;屏幕把两组并排给 CFO 看。
--   【不自动补提】处置月的折旧 —— dispose_fixed_asset 从 FIN-22 起的规矩不变(Q7)。
--   amount_base 本位币 = 处置分录的借方合计(APR-7 同口径):提交时是试跑额,批准后是实际过账额。
-- 【在等的时候冻结什么】(Q8)资产卡上改成本、改残值 / 年限 / 折旧科目、投用、改状态 —— 按名拒
--   ASSET_DISPOSAL_REQUESTED(guard_asset_disposal_freeze,挂在 fixed_assets 上;记支出追加成本、冲销成本明细、
--   set_asset_in_service 都要改这张卡,所以一支守卫全部拦住)。折旧、保养、计划投用日、验收日照常。
--   snapshot = asset_disposal_fingerprint:批准时再比(ASSET_CHANGED_SINCE_REQUEST —— 只有属主路径改得动)。
--
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE TABLE public.asset_disposal_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    asset_id           uuid NOT NULL REFERENCES public.fixed_assets (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- 收款(本位币;报废为 0)与收进哪个银行科目(收款 > 0 时必填 1000 / 1010)
    proceeds_base      numeric NOT NULL CHECK (proceeds_base >= 0),
    bank_account       text,
    -- 提单人的理由:原样成为处置分录的摘要尾巴
    reason             text NOT NULL CHECK (btrim(reason) <> ''),
    -- fingerprint(asset_disposal_fingerprint):成本、残值、年限、投用日、折旧科目、状态、折旧锚点
    snapshot           jsonb NOT NULL,
    -- 提交时试跑出来的那一组(处置日 = 提交日;成本、累计折旧、收款、损益)
    estimate           jsonb NOT NULL,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base        numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    -- 批准当场处置:生效的时刻、处置日(= 批准日)、处置分录、真的过出来的那一组
    executed_at        timestamptz,
    disposal_date      date,
    result_entry_id    uuid REFERENCES public.journal_entries (id),
    result             jsonb,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT asset_disposal_requests_bank_shape CHECK (
        (proceeds_base > 0) = (bank_account IS NOT NULL)
        AND (bank_account IS NULL OR bank_account IN ('1000', '1010'))),
    CONSTRAINT asset_disposal_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT asset_disposal_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT asset_disposal_requests_approved_shape CHECK (
        (status = 'approved') = (executed_at IS NOT NULL)
        AND (executed_at IS NULL) = (disposal_date IS NULL)
        AND (executed_at IS NULL) = (result_entry_id IS NULL)
        AND (executed_at IS NULL) = (result IS NULL)),
    CONSTRAINT asset_disposal_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.asset_disposal_requests IS
    'APR-9:固定资产处置申请 —— 财务提(module.finance.edit),CFO 批每一张,不分档,批准当场处置:处置日 = 批准日,按批准那一刻的累计折旧与损益过账;收款与银行科目提交时冻结。submitted → approved · rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。审批关着时生下来就是 approved 并当场处置(auto_approved)。在等的时候资产卡上改成本 / 投用 / 状态按名拒 ASSET_DISPOSAL_REQUESTED;折旧照常。一台资产同一时刻只挂一张在等的申请。dispose_fixed_asset 只会按名拒 ASSET_DISPOSAL_NEEDS_REQUEST。';

COMMENT ON COLUMN public.asset_disposal_requests.estimate IS
    'APR-9(grilling Q7):提交时按同一条路试跑出来的那一组 —— disposal_date(= 提交日)、cost_relieved、accum_relieved、proceeds、gain_loss。CFO 在屏幕上看见它与批准时真的过出来的 result 并排。';

COMMENT ON COLUMN public.asset_disposal_requests.amount_base IS
    'APR-9:本位币 = 处置分录的借方合计(APR-7 同口径)。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账额(写进 approved 留痕)。';

CREATE UNIQUE INDEX asset_disposal_requests_one_open
    ON public.asset_disposal_requests (asset_id) WHERE status = 'submitted';
CREATE INDEX asset_disposal_requests_asset_id_rel ON public.asset_disposal_requests (asset_id);
CREATE INDEX asset_disposal_requests_result_entry_id_rel ON public.asset_disposal_requests (result_entry_id);

ALTER TABLE public.asset_disposal_requests ENABLE ROW LEVEL SECURITY;

-- 读:资产页那一个码(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。写:一条策略都不给 ——
-- 只经 submit / decide / withdraw(全是 SECURITY DEFINER)。屏幕读 asset_disposal_requests_visible()。
CREATE POLICY "asset_disposal_requests select by permission" ON public.asset_disposal_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.asset_disposal_requests FROM anon;
