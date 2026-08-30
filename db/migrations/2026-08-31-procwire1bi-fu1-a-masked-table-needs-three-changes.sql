-- PROC-WIRE-1B-i · fu1:遮蔽表加一列 = 三件事,而主刀只做了一件
--
-- 【实测撞出来的】主刀给 processing_runs 加了 operation_type_code,但
-- **processing_runs 是一张【遮蔽表】**(有列级授权 + _masked 伴生视图)。
-- AGENTS.md 的规矩写着:遮蔽表加一列要【三件事一支迁移】——
-- 列 + 列级授权 + _masked 视图,缺一 gate 红。主刀只做了第一件。
--
-- 线上实测(改之前):
--   has_column_privilege('authenticated','processing_runs','operation_type_code','SELECT') = false
--   而同一张表上 equipment_id = true
-- 也就是说:**这一列存在,但每一个登录用户都读不到它** —— 界面上那个工序
-- 会永远显示成空,而且不会有任何报错。这正是"遮蔽表加列"这条规矩存在的理由。
--
-- 【记下来,因为它是一条会重犯的】加列的时候要问的不是"这一列敏不敏感",
-- 而是"这张表【是不是】遮蔽表" —— 后者是一个可以查的事实(有没有 _masked 伴生),
-- 前者是一个判断,而判断会漏。
BEGIN;

-- ① 列级授权。不遮蔽,原样透出 —— 一道工序的名字不是钱,与 equipment_id 同一条。
GRANT SELECT (operation_type_code) ON public.processing_runs TO authenticated;

-- ② _masked 伴生视图:**每一列都必须在**(colgrant 的第二个分支),
--    授没授权都一样。
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
    work_order_id,
    deleted_by,
    delete_reason,
    equipment_id,
    operation_type_code
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);

COMMIT;
