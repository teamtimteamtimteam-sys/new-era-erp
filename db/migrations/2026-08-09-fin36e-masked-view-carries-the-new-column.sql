-- FIN-36e:遮蔽伴生视图补上 allocation_basis_changed_at
--
-- AGENTS.md §"给遮蔽表加列":列级 SELECT 授权【不会】自动延伸到后加的列,而
-- <表>_masked 也必须同步 —— 两件事要在同一支迁移里做完。FIN-36 只做了授权那一半,
-- colgrant 立刻在 live 与 rebuild 两侧同时点名。这一支补上另一半。
-- 这一列不敏感(一个时间戳),所以两边都给,而不是只留在遮蔽视图里。
-- NOTE: apply with ./db/apply_migration.sh
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
    -- FIN-36:基准变更时点 —— 不敏感(一个时间戳),所以列级授权与遮蔽视图两边都给。
    -- 遗漏任一边都会被 colgrant 顶出来(AGENTS.md §"给遮蔽表加列")。
    allocation_basis_changed_at
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);

-- FIN-36d 换了机制(evoltrya.alloc_ctx 取代看 allocated_at 变没变),线上的列注释
-- 还停在旧说法上 —— 注释描述的机制不对,与一段描述已不存在的危险的注释是同一种缺陷。
COMMENT ON COLUMN public.processing_runs.allocation_basis_changed_at IS
    '分摊基准最后一次被改动的时点(FIN-36),由 trg_processing_runs_basis_changed 维护。processing_run_allocation_status.is_stale 与 batch_margin.is_stale 把它当【第四个过期源】—— 前三个是成本条目、输入批的 price_history、上游单重分摊。少了它,一次 UPDATE ... SET allocation_basis 会让存着的单位成本与单据自称的方法对不上而毫无信号。allocate_processing_costs 挂 evoltrya.alloc_ctx,所以重分摊自己不会被标成过期。';

COMMIT;
