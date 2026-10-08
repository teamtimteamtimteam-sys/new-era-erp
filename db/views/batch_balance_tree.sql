-- db/views/batch_balance_tree.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q4 · Q5,Tim):【一个批次往下走的质量树 —— 带门的外壳】。/inbound/[id]/edit 与 /output/[id]/edit 的
--   平衡面板读它(按 root_id 取一棵)。门:module.processing.view(整棵树是加工的事实),或这个根批次自己那一页的查看码 ——
--   进料批 module.inbound.view、产出批 module.output.view(Q4:"加上批次自己那一页的码")。树上的批次编号、物料名与单号是标签,
--   跟着这一行走(AGENTS.md 常设决定 3);一个数字的钱都没有。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.batch_balance_tree WITH (security_invoker = off) AS
 SELECT root_kind,
    root_id,
    root_code,
    node_key,
    parent_key,
    depth,
    node_type,
    line_key,
    x,
    share_num,
    share_den,
    qty,
    batch_kind,
    batch_id,
    batch_code,
    unit,
    material_name,
    form_code,
    run_id,
    run_code,
    operation_type_code,
    process_date,
    flow,
    remainder_state,
    era_mes4a,
    reversed_at,
    corrects_run_code,
    corrected_by_run_code,
    loss_category_code,
    loss_basis
   FROM batch_balance_tree_all
  WHERE has_permission('module.processing.view'::text) OR root_kind = 'inbound'::text AND has_permission('module.inbound.view'::text) OR root_kind = 'output'::text AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.batch_balance_tree IS
    'MES-5b-1:一个批次往下走的质量树,带门(module.processing.view,或根批次自己的查看码:进料 module.inbound.view / 产出 module.output.view)。算术全在 batch_balance_tree_all。';

GRANT SELECT ON public.batch_balance_tree TO authenticated;
REVOKE ALL ON public.batch_balance_tree FROM anon;
