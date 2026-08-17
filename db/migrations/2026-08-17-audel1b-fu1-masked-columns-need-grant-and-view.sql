-- AUDEL-1b fu1:遮蔽表上新加的列,授权与遮蔽视图【必须同落】
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这一条 AGENTS.md 写得清清楚楚,我还是分了两支】
-- 「往遮蔽表加一列 = 三件事,而它们属于同一支迁移」:ADD COLUMN、列清单
-- GRANT SELECT、以及 <表>_masked 视图。AUDEL-1b 只做了第一件,于是 gate 的
-- colgrant 行当场报红:
--     column grant gap (live): inbound_batches: deleted_by, delete_reason
--                              [无 SELECT 且不在遮蔽视图]
-- 这是 WO-1a 逐字重演的一次 —— 那一刀也是"每一步看起来都完整",而
-- colgrant 的判据是 (NOT granted AND NOT in_view) OR (has_view AND NOT in_view):
-- **一张表一旦有了 _masked 伴生视图,它的每一列都必须在那张视图里**,授不授权都一样。
--
-- 【为什么这几列不敏感、可以直接授权】deleted_by / delete_reason / cancelled_by
-- 是【审计元数据】,不是钱。遮蔽视图挡的是 unit_price / *_cost_base 那一类;
-- 把"谁删的、为什么删"藏起来,恰好与本刀要做的事相反 —— 那是要给人看的。
--
-- 【AGENTS.md 里那条 QUEUED 的预检仍然没建】它说 preflight_migration.py 本可以
-- 在执行【之前】看出"这支迁移给一张有 _masked 伴生的表加了列,却没有同时动
-- 授权与视图"。我这一刀又一次撞上它,而我【没有】顺手去建那个检查 ——
-- 在一支刚被这个缺口绊倒的刀里赶写一个检查,正是那条 QUEUED 说不要做的事。
-- 记在这里,是让下一个人看到它已经绊倒过两个人。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── inbound_batches ──────────────────────────────────────────────────────────────
GRANT SELECT (deleted_by, delete_reason) ON public.inbound_batches TO authenticated;
CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status
,
    deleted_by,
    delete_reason
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);

-- ── processing_runs ──────────────────────────────────────────────────────────────
GRANT SELECT (deleted_by, delete_reason) ON public.processing_runs TO authenticated;
CREATE OR REPLACE VIEW public.processing_runs_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    process_date,
    total_input,
    total_output,
    loss_qty,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    allocation_basis,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN material_cost_base
            ELSE NULL::numeric
        END AS material_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN process_cost_base
            ELSE NULL::numeric
        END AS process_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN total_cost_base
            ELSE NULL::numeric
        END AS total_cost_base,
    allocation_snapshot,
    allocated_at,
    allocated_by,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN capitalized_cost_base
            ELSE NULL::numeric
        END AS capitalized_cost_base,
    capitalization_entry_id,
    allocation_basis_changed_at,
    work_order_id
,
    deleted_by,
    delete_reason
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);

-- ── purchase_orders ──────────────────────────────────────────────────────────────
GRANT SELECT (deleted_by, delete_reason, cancelled_by) ON public.purchase_orders TO authenticated;
CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by
,
    deleted_by,
    delete_reason,
    cancelled_by
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

COMMIT;
