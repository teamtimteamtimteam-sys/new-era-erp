-- db/tables/shipping_releases.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-5b(2026-09-25):发货前放行 —— cco 提,CFO 批,【批准就是放行】,仓库照放行发货
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md §10「发货 | 仓库执行,在 CFO 放行之后 | CFO」,[LC] APR-5b):
-- APR-5 grilling Q2–Q8 · Q13,APR-5b grilling Q1–Q12(Tim 2026-09-25 全部接受)。
--
-- 【生命周期】
--   submitted ──批准(= 放行,没有执行那一步)──▶ approved
--       ├──驳回(要理由)──────────────────────▶ rejected
--       └──撤回───────────────────────────────▶ withdrawn
--   · 提:cco(action.request_shipping_release)。放行点名的是这张订单【已开票】的行
--     (shipping_release_lines —— 一行一条发票行),所以只能在开票之后提;默认点名每一条已开票、
--     还没被放行覆盖的行(5b Q2)。审批关着时【生下来就是 approved】,留痕 auto_approved。
--   · 批:CFO(二级,不分档)。门 module.sales.view + data.view_prices —— 订单页的门,加上看得见
--     金额的那个码;【不是】action.request_shipping_release:那是提单的码。提单人永远不能批
--     (forbid_self_approval,按人认)。提单人之外没人批得动 → 提交就拒 SHIPPING_RELEASE_NO_OTHER_DECIDER。
--   · 撤回:提单人本人(按人认),或任何持 action.request_shipping_release 的人(5b Q4)。
--     撤回写在本行上,【不】写 approval_log —— 撤回不是一次决定。
--
-- 【覆盖】一条订单行可以发货 ⟺ 它坐在一条【在册】的订单流发票行上,而那条发票行被一张 approved
--   放行点了名(ship_order 按名拒 SO_SHIP_NOT_RESERVED 之后的 SO_SHIP_NOT_RELEASED)。
--   覆盖是【现算】的:发票作废,那条发票行 invoice_voided = true,覆盖自己就没了(Q3)——
--   没有任何东西要被作废、被重新放行。重开的发票是新的发票行,要新的放行。
--   唯一让放行失效的是作废(5b Q4):客户被冻结由发货时按名拒(Q6),订单取消了本来就发不了。
--
-- 【一张订单同时只挂一张 submitted】(shipping_releases_one_open_per_order;函数里先按名拒
--   SHIPPING_RELEASE_OPEN)。approved 的可以有好几张 —— 放行之后加的行要它自己的放行(Q3 · 5b Q3);
--   一条已被覆盖的发票行不许再被点名(SHIPPING_RELEASE_LINE_ALREADY_RELEASED)。
--
-- 【金额】amount_base = 点名的发票行 amount_base 之和(本位币),给留痕与 CFO 读;它不驱动任何过账 ——
--   放行不动钱,钱在发货那一刻(2500 → 4000)由 ship_order 过。
--
-- 【没有自己的单据编号】label = 订单编号 · release #n;不进 document_types(与 invoice_requests 同一条理由)。
--
-- 【谁读】module.sales.view(订单页的门)。仓库不持它(5b Q6/Q7):仓库经 shipping_queue_rows() 读
--   发货队列,那里没有价格、币种、汇率、金额、毛利、发票编号与余额。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE TABLE public.shipping_releases (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id  uuid NOT NULL REFERENCES public.sales_orders (id) ON DELETE RESTRICT,
    status          text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label           text NOT NULL,
    -- 本位币:点名的发票行 amount_base 之和(提交时算,冻结)
    amount_base     numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at      timestamptz,
    decided_by      uuid,
    decision_notes  text,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at    timestamptz,
    withdrawn_by    uuid,
    withdraw_reason text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid NOT NULL,
    CONSTRAINT shipping_releases_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT shipping_releases_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT shipping_releases_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.shipping_releases IS
    'APR-5b:发货前放行(Tim 的矩阵:发货 = 仓库执行,在 CFO 放行之后)。cco 提(action.request_shipping_release),CFO 批 —— 批准就是放行,没有执行那一步。submitted → approved · rejected(要理由)· withdrawn(提单人本人或 action.request_shipping_release)。点名的是已开票的发票行(shipping_release_lines);覆盖现算 = approved 且发票行未作废。审批关着时生下来就是 approved(auto_approved)。一张订单同时只挂一张 submitted。';

COMMENT ON COLUMN public.shipping_releases.amount_base IS
    'APR-5b:本位币,点名的发票行 amount_base 之和,提交时算、冻结。只给留痕与 CFO 读;放行不过账。';

CREATE UNIQUE INDEX shipping_releases_one_open_per_order
    ON public.shipping_releases (sales_order_id)
    WHERE status = 'submitted';
CREATE INDEX shipping_releases_sales_order_id_rel ON public.shipping_releases (sales_order_id);

ALTER TABLE public.shipping_releases ENABLE ROW LEVEL SECURITY;

-- 读:订单页的门(module.sales.view)。写:一条策略都不给 —— 只经 submit_shipping_release ·
-- decide_shipping_release · withdraw_shipping_release(全是 SECURITY DEFINER)。
CREATE POLICY "shipping_releases select by permission" ON public.shipping_releases
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.shipping_releases FROM anon;
