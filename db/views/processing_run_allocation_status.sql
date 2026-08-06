-- db/views/processing_run_allocation_status.sql
-- 一张加工单的分摊是否还作数,以及能不能安全重跑。
-- security_invoker = on:没有敏感列,让基表的 RLS 照常逐行生效(与遮蔽视图相反)。
--
-- FIN-24:last_cost_change 同时看【成本条目】与【输入批的 price_history】——
-- 重定价进料后,耗了它的加工单一样过期(F2 之前无旗,叠加错因此隐形)。
-- safe_to_reallocate 重定义:差额法重述已售份额进 5000,已过账 COGS 不再是
-- "不能重跑"的理由;唯一不能重跑的是资本化分录被人工冲销(差额基准与总账分道,
-- allocate 抛 ALLOCATION_LEDGER_DIVERGED)。
--
-- NOTE: introduced by db/migrations/2026-07-XX; reshaped by
-- db/migrations/2026-08-06-fin24-allocation-delta-split.sql.

CREATE VIEW public.processing_run_allocation_status WITH (security_invoker = on) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    -- FIN-24:差额法重述已售份额进 5000,已过账 COGS 不再是"不能重跑"的理由。
    -- 唯一不能重跑的:资本化分录被人工冲销(差额基准与总账分道)——
    -- allocate 会 ALLOCATION_LEDGER_DIVERGED 点名拒,这里把它亮出来。
    (r.capitalization_entry_id IS NULL OR je.status = 'posted') AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN journal_entries je ON je.id = r.capitalization_entry_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                    FROM processing_cost_entries e
                   WHERE e.run_id = r.id
                  UNION ALL
                  -- FIN-24/F2:输入批被重定价 = 本单材料成本过期。price_history 是
                  -- 定价的唯一写入路径,它的 created_at 就是"输入价何时变了"。
                  SELECT ph.created_at
                    FROM price_history ph
                    JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                   WHERE pi.run_id = r.id) x) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL;

GRANT SELECT ON public.processing_run_allocation_status TO authenticated;
