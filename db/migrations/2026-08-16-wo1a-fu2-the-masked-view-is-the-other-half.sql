-- WO-1a-fu2:遮蔽表加列是【两件事】,fu1 只做了一件
--
-- fu1 把 work_order_id 补进了列清单授权,而 gate 仍然红:
--     column grant gap (live): processing_runs: work_order_id [不在遮蔽视图]
-- 判据是 `(NOT granted AND NOT in_view) OR (has_view AND NOT in_view)` ——
-- 也就是说,【只要这张表有 _masked 伴生视图,它的每一列都必须在视图里】,
-- 授权与否都不豁免。AGENTS.md 那一节写的本来就是两条,fu1 只读到了第一条。
--
-- 【为什么这条判据是对的,而不是过严】遮蔽视图的契约是"基表的每一列都在,
-- 敏感列置空"。少一列的话,改读遮蔽视图的页面会【静默地取不到那一列】——
-- 不是 42501,是这个字段根本不存在于它 select 的那张视图上。而页面此前读基表时
-- 是有这一列的,于是同一段代码换个来源就少了一个字段,没有任何东西会喊。
--
-- work_order_id 不敏感(单据链接,与同表的 capitalization_entry_id 同一类),
-- 所以【原样透出】,不置空。
--
-- 【这一刀真正的产物是那句话:给遮蔽表加一列,授权与视图要在【同一支迁移】里】——
-- 本刀把它拆成了三支,而拆开的每一步单独看都"做完了"。
BEGIN;

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
    -- WO-1a:这一次加工照哪张工单做的。不敏感,原样透出。
    work_order_id
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);

COMMIT;
