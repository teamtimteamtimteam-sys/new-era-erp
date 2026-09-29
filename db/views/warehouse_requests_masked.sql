-- db/views/warehouse_requests_masked.sql
-- 遮蔽伴生视图:warehouse_requests 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:amount_base → data.view_prices
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 Q12):仓库申请的读规则与 /inventory 那一块【已经给人看的】对齐 ——
--   持 module.inventory.view(仓库、CFO)或 module.finance.view 的人读得到申请;金额是一个价格(注销的价值),
--   没有 data.view_prices 的读者看到 NULL(屏幕上是 Restricted)。与 warehouse_requests_visible() 同一个判法。
--   于是批次 / 加工单页底的审计记录里,仓库的人看得见"谁提了注销、谁批的",看不见金额 —— 而不是整行 Restricted。
-- 【属主权限,不是 SECURITY INVOKER】理由同 processing_runs_masked:基表的 amount_base 已经收回了列权限,
--   invoker 视图会对调用者报 42501。模块谓词原样写回视图体,与基表的读策略逐行等价 —— 视图不放宽任何行访问。
-- 【一旦一张表有了 _masked 伴生,它的每一列都必须在这张视图里】(colgrant 的第二个分支)。

CREATE VIEW public.warehouse_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    kind,
    status,
    label,
    inbound_batch_id,
    output_batch_id,
    run_id,
    cod_id,
    reason,
    snapshot,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    decided_at,
    decided_by,
    decision_notes,
    executed_at,
    result_entry_ids,
    withdrawn_at,
    withdrawn_by,
    withdraw_reason,
    created_at,
    created_by
   FROM warehouse_requests
  WHERE has_permission('module.inventory.view'::text) OR has_permission('module.finance.view'::text);

-- anon 什么都不给:anon 的面只许缩小(db/anon-grants-baseline.tsv · db/check_grants.py)
REVOKE ALL ON public.warehouse_requests_masked FROM anon;
