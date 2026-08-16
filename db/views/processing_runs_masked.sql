-- db/views/processing_runs_masked.sql
-- 遮蔽伴生视图:processing_runs 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:capitalized_cost_base → data.view_prices, material_cost_base → data.view_prices, process_cost_base → data.view_prices, total_cost_base → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.processing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE VIEW public.processing_runs_masked WITH (security_invoker = off) AS
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
    -- FIN-36:基准变更时点 —— 不敏感(一个时间戳),所以列级授权与遮蔽视图两边都给。
    -- 遗漏任一边都会被 colgrant 顶出来(AGENTS.md §"给遮蔽表加列")。
    allocation_basis_changed_at,
    -- WO-1a:这一次加工照哪张工单做的。不敏感(单据链接,与 capitalization_entry_id
    -- 同一类),原样透出。【授权与视图是两件事,而 colgrant 两件都查】——
    -- WO-1a 只加了列,fu1 补了授权,fu2 才补了这里;三支拆开的每一步单独看都
    -- "做完了"。给遮蔽表加列的授权与视图,应当写在【同一支迁移】里。
    work_order_id
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);
