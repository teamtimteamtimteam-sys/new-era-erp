-- db/tables/terms_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-8(2026-09-26):合同条款与定价公式 —— cco 提,CFO 批每一张,批准之前什么都不生效
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md「合同条款 · 定价公式 | cco | CFO」):不分档,批准之前什么都不发生。
--
-- 【"生效"是什么】(APR-8 grilling Q1 · Q2,Tim 2026-09-26 全部接受)
--   · 公式:谁读【活的那一行】,谁就是"生效"—— calculate_metal_price(计价器、新建采购单的估价)、
--     price_output_sale(销售)、commit_pricing_terms(建采购单、应用化验时抄一份承诺)。已经抄下的承诺、
--     销售行上的 price_provenance 都是副本,本刀之后照旧不动。
--     新公式生下来 is_active = false、挂一张在等的申请;批准才 true。改一张在用的公式 = 一张带着【完整拟议条款】的
--     申请,批准时就地替换(pricing_formula_history 的触发器照旧记下新旧);等待期间旧条款照旧生效。
--     重新启用一张停用的公式也要批。停用、删除仍是 cco 一步(只会让能用的变少)。不加状态列。
--   · 合同:只有 active 有效力(link_document_to_contract 只认 active,挂上时抄一份 contract_document_terms)。
--     进入 active 的每一条路(draft → active、suspended → active)都要批;active 的合同表头与七张条款表冻结;
--     改条款 = 暂停、编辑、申请重新生效,CFO 看见与【上一次批准时】那一份的差别。暂停 / 终止 / 到期仍是一步。
--
-- 【一张表,四种】(Q4)—— 每一种一个主体列,由 kind_shape 钉住"恰好那一列非空":
--   formula_create      formula_id  —— 新公式(提交时建好、停用着)生效
--   formula_change      formula_id  —— 在用的公式换成 proposed 那一组条款
--   formula_reactivate  formula_id  —— 停用的公式按 proposed 那一组条款重新生效
--   contract_activate   contract_id —— 草稿或暂停的合同生效
--
-- 【生命周期】与 APR-5a / 6 / 7 同形
--   submitted ──批准(当场生效)──▶ approved
--       ├──驳回(要理由)─────────▶ rejected
--       └──撤回──────────────────▶ withdrawn
--   · 提:cco —— 公式 module.pricing.edit,合同 action.contract_terms。提交时按批准那一刻会走的同一条路【试跑】
--     一遍(terms_request_dry_run):条款违反任何一条 CHECK,都按原话拒,什么都不留下。
--     审批关着时【生下来就是 approved】并当场生效,留痕写 auto_approved。
--   · 批:CFO(二级,不分档)。门 module.pricing.view + data.view_prices + data.view_purchase_prices +
--     module.suppliers.view + module.customers.view(Q4,四种一个门;cfo 五个都持,APR-8 Step 0 量过)。
--     提单人永远不能批(按人认);提单人之外没人批得动 → 提交就拒 TERMS_REQUEST_NO_OTHER_DECIDER。
--   · 撤回:提单人本人(按人认),或持该种类那个码的人。撤回不写 approval_log。
--
-- 【在等的时候冻结什么】(Q5)
--   · 一个主体同一时刻只挂一张在等的申请(TERMS_REQUEST_OPEN;唯一索引是第二道)。
--   · 公式:本来就没有直连写(guard_pricing_formula_direct_write);停用、删除在等待中按名拒 TERMS_REQUEST_OPEN。
--   · 合同:表头任何直连改动按名拒 TERMS_REQUEST_FREEZES_CONTRACT,七张条款表 CONTRACT_TERMS_FROZEN。
--   · fingerprint:提交时主体那一刻的样子(md5),批准时再算一遍,不一样 → TERMS_CHANGED_SINCE_REQUEST
--     (收货定价、工资申请的同一形状)。
--
-- 【snapshot】提交时冻下来给 CFO 读的那一组:主体编号与名称;current(提交时主体的条款;新公式为 NULL);
--   proposed(公式三种:拟议条款);last_approved(这个主体上一次批准时的那一份,从未批过为 NULL);
--   usage(公式:已承诺的采购行 / 批次、还没承诺、应用化验时会抄【新】条款的批次;合同:已挂上的单据数)。
--   【没有金额】—— 批的是条款,不是一笔钱;amount 在引擎里记 NULL(work_order 同形),不读成零。
--
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE TABLE public.terms_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind               text NOT NULL
        CHECK (kind IN ('formula_create', 'formula_change', 'formula_reactivate', 'contract_activate')),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    -- ── 主体:恰好一列 ─────────────────────────────────────────────────────
    formula_id         uuid REFERENCES public.pricing_formulas (id) ON DELETE RESTRICT,
    contract_id        uuid REFERENCES public.contracts (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    reason             text NOT NULL CHECK (btrim(reason) <> ''),
    -- 公式三种:批准时就地写进公式的那一组条款(规范形,见 formula_terms_normalize);合同:NULL
    proposed           jsonb,
    snapshot           jsonb NOT NULL,
    -- 提交时主体的样子(md5);批准时再算一遍
    fingerprint        text NOT NULL,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    executed_at        timestamptz,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT terms_requests_kind_shape CHECK (
        (kind IN ('formula_create', 'formula_change', 'formula_reactivate')) = (formula_id IS NOT NULL)
        AND (kind = 'contract_activate') = (contract_id IS NOT NULL)
        AND (kind IN ('formula_create', 'formula_change', 'formula_reactivate')) = (proposed IS NOT NULL)),
    -- 恰好一个主体 —— 与 kind_shape 同一件事的另一种写法,留着它是给关系图读的(warehouse_requests 同一条理由)
    CONSTRAINT terms_requests_one_subject CHECK (num_nonnulls(formula_id, contract_id) = 1),
    CONSTRAINT terms_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT terms_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT terms_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT terms_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.terms_requests IS
    'APR-8:定价公式(formula_create / formula_change / formula_reactivate)与合同生效(contract_activate)的申请 —— cco 提,CFO 批每一张,不分档,批准当场生效。submitted → approved(CFO)· rejected(要理由)· withdrawn(提单人本人或该种类的码)。审批关着时生下来就是 approved 并当场生效(auto_approved)。在等的时候:一个主体只挂一张(TERMS_REQUEST_OPEN);合同表头与条款冻结;公式本来就没有直连写;批准时 fingerprint 再比一遍(TERMS_CHANGED_SINCE_REQUEST)。';

COMMENT ON COLUMN public.terms_requests.proposed IS
    'APR-8(grilling Q1):公式三种申请批准时就地写进公式的那一组完整条款(规范形:表头各列 + metals 按金属排序)。等待期间公式上仍是旧条款、旧条款照旧生效。合同申请为 NULL —— 合同的条款就在七张条款表里,提交时冻结。';

COMMENT ON COLUMN public.terms_requests.snapshot IS
    'APR-8(grilling Q8):提交时冻下来给 CFO 读的那一组 —— 主体编号与名称、current(提交时的条款)、proposed、last_approved(上一次批准时那一份)、usage(哪些单据会用它)。含价格条款 —— 屏幕经 terms_requests_visible() 读,按 pricing_formula_terms_visible 与合同那一侧的码遮蔽。';

CREATE UNIQUE INDEX terms_requests_one_open_formula
    ON public.terms_requests (formula_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX terms_requests_one_open_contract
    ON public.terms_requests (contract_id) WHERE status = 'submitted';
CREATE INDEX terms_requests_open ON public.terms_requests (kind) WHERE status = 'submitted';
CREATE INDEX terms_requests_formula_id_rel ON public.terms_requests (formula_id);
CREATE INDEX terms_requests_contract_id_rel ON public.terms_requests (contract_id);

ALTER TABLE public.terms_requests ENABLE ROW LEVEL SECURITY;

-- 读:公式申请要看得见公式与它的价格(module.pricing.view + 两个价格码);合同申请跟着合同那一侧走
-- (contracts 自己的读策略同一条)。屏幕不直接读本表,读 terms_requests_visible()。写:一条策略都不给 ——
-- 只经 submit_* · decide_terms_request · withdraw_terms_request(全是 SECURITY DEFINER)。
CREATE POLICY "terms_requests select by permission" ON public.terms_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((formula_id IS NOT NULL AND has_permission('module.pricing.view'::text)
                AND has_permission('data.view_prices'::text) AND has_permission('data.view_purchase_prices'::text))
        OR (contract_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM contracts c WHERE c.id = terms_requests.contract_id
                   AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                     OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text))))));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.terms_requests FROM anon;
