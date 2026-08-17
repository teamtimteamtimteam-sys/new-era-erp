-- db/views/batch_lineage.sql
-- 批次血缘(FIN-25,展示用):一个产出批的全部祖先 —— 经哪张加工单、耗了哪个批、
-- 多少量、第几层。立账公理是全链路可溯;再加工让链条真正变长(进料→产出→产出),
-- 这个视图是它的眼睛。边永远指向更早的提交(B 只能耗 A 已存在的产出)→ 无环,
-- 递归安全。security_invoker:底下各表的 RLS 照常生效。
--
-- NOTE: introduced by db/migrations/2026-08-06-fin25-reprocessing.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ module.processing.view。
-- 借 inbound_batches.code / output_batches.code —— 祖先批次的编号,也就是标签。
-- 血缘的起点是 processing_outputs,所以模块就是 processing;少了这两个 code,
-- 链条变成一串 NULL,而"可溯"正是立账公理。

-- AUD-1(2026-08-17):体改成读 batch_lineage_all —— 判据仍在这里,递归搬去了基视图。
-- 列名、类型、顺序一个没动;拆分的理由写在 batch_lineage_all 的抬头。

CREATE VIEW public.batch_lineage WITH (security_invoker = off) AS
 SELECT output_batch_id,
    depth,
    via_run_id,
    via_run_code,
    parent_kind,
    parent_batch_id,
    parent_code,
    quantity_consumed
   FROM batch_lineage_all l
  WHERE has_permission('module.processing.view'::text);

GRANT SELECT ON public.batch_lineage TO authenticated;
