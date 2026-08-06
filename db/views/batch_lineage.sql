-- db/views/batch_lineage.sql
-- 批次血缘(FIN-25,展示用):一个产出批的全部祖先 —— 经哪张加工单、耗了哪个批、
-- 多少量、第几层。立账公理是全链路可溯;再加工让链条真正变长(进料→产出→产出),
-- 这个视图是它的眼睛。边永远指向更早的提交(B 只能耗 A 已存在的产出)→ 无环,
-- 递归安全。security_invoker:底下各表的 RLS 照常生效。
--
-- NOTE: introduced by db/migrations/2026-08-06-fin25-reprocessing.sql.

CREATE VIEW public.batch_lineage WITH (security_invoker = on) AS
WITH RECURSIVE up AS (
    SELECT po.output_batch_id AS batch_id,
           pr.id AS via_run_id, pr.code AS via_run_code,
           pi.inbound_batch_id AS parent_inbound_id,
           pi.output_batch_id  AS parent_output_id,
           pi.quantity_consumed, 1 AS depth
    FROM public.processing_outputs po
    JOIN public.processing_runs pr ON pr.id = po.run_id AND pr.deleted_at IS NULL
    JOIN public.processing_inputs pi ON pi.run_id = pr.id
  UNION ALL
    SELECT up.batch_id, pr2.id, pr2.code,
           pi2.inbound_batch_id, pi2.output_batch_id,
           pi2.quantity_consumed, up.depth + 1
    FROM up
    JOIN public.processing_outputs po2 ON po2.output_batch_id = up.parent_output_id
    JOIN public.processing_runs pr2 ON pr2.id = po2.run_id AND pr2.deleted_at IS NULL
    JOIN public.processing_inputs pi2 ON pi2.run_id = pr2.id
    WHERE up.parent_output_id IS NOT NULL
)
SELECT up.batch_id AS output_batch_id,
       up.depth,
       up.via_run_id,
       up.via_run_code,
       CASE WHEN up.parent_inbound_id IS NOT NULL THEN 'inbound' ELSE 'output' END AS parent_kind,
       COALESCE(up.parent_inbound_id, up.parent_output_id) AS parent_batch_id,
       COALESCE(ib.code, ob.code) AS parent_code,
       up.quantity_consumed
FROM up
LEFT JOIN public.inbound_batches ib ON ib.id = up.parent_inbound_id
LEFT JOIN public.output_batches ob ON ob.id = up.parent_output_id;

GRANT SELECT ON public.batch_lineage TO authenticated;
