-- db/views/processing_run_allocation_status.sql
-- 一张加工单的分摊是否还作数:分摊之后成本条目又动过没有,以及【能不能安全重跑】。
-- security_invoker = on:没有敏感列,让基表的 RLS 照常逐行生效(与遮蔽视图相反)。
-- safe_to_reallocate 的含义见迁移头注:已过账的 COGS 不会被重述,而资本化按全量
-- 重挂,所以已售批次上的重跑会把已售部分的成本增量留在存货里。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin8-cost-entry-history-and-stale-allocation.sql.

CREATE VIEW public.processing_run_allocation_status WITH (security_invoker = on) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    COALESCE(g.cogs_posted, 0::bigint) = 0 AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN LATERAL ( SELECT max(GREATEST(e.created_at, e.updated_at)) AS last_cost_change
           FROM processing_cost_entries e
          WHERE e.run_id = r.id) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL;

GRANT SELECT ON public.processing_run_allocation_status TO authenticated;
