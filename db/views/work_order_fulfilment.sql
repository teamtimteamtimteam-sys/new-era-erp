-- db/views/work_order_fulfilment.sql
-- WO-1b:计划 vs 实绩 —— 一张工单 × 一侧(input/output)× 一种物料一行。
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1b-the-seam.sql.
-- First-run script. Re-running requires DROP VIEW first.
--
-- 【单模块,所以按数据自己的 RLS 给权限】(OPS-15)—— 计划、行、加工单、投入腿、
-- 产出腿全部在 module.processing.* 后面,没有跨模块,所以 xmodule 那一类问题
-- 在这里不存在。【属主权限】理由与 processing_metal_recovery 相同:invoker 视图
-- 会被基表的列权限与行策略挡住,而把模块谓词原样写回视图体是等价且可读的做法。

CREATE VIEW public.work_order_fulfilment WITH (security_invoker = off) AS
WITH linked_runs AS (
    -- 只数【没有被冲销、没有被软删】的加工
    SELECT r.id, r.work_order_id
      FROM processing_runs r
     WHERE r.work_order_id IS NOT NULL
       AND r.deleted_at IS NULL
       AND r.status = 'committed'
),
consumed AS (
    -- 投入腿指向批次,批次才有物料 —— 两侧都要 join 过去
    -- (进料批与再加工的产出批各一条腿,FIN-25 的 XOR)
    SELECT lr.work_order_id,
           COALESCE(ib.material_id, ob.material_id) AS material_id,
           sum(pi.quantity_consumed) AS consumed_qty
      FROM linked_runs lr
      JOIN processing_inputs pi ON pi.run_id = lr.id
      LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = pi.output_batch_id
     GROUP BY 1, 2
),
produced AS (
    SELECT lr.work_order_id, ob.material_id, sum(po.quantity_produced) AS produced_qty
      FROM linked_runs lr
      JOIN processing_outputs po ON po.run_id = lr.id
      JOIN output_batches ob ON ob.id = po.output_batch_id
     GROUP BY 1, 2
),
-- 投入侧:计划行与实际消耗【全外连接】—— 计划了却没吃(欠),
-- 以及吃了却没计划(计划外的物料,同样是一种差异)。
input_side AS (
    SELECT COALESCE(wl.work_order_id, c.work_order_id) AS work_order_id,
           COALESCE(wl.material_id,   c.material_id)   AS material_id,
           wl.planned_qty,
           COALESCE(c.consumed_qty, 0) AS consumed_qty
      FROM work_order_lines wl
      FULL JOIN consumed c
        ON c.work_order_id = wl.work_order_id AND c.material_id = wl.material_id
),
output_side AS (
    SELECT COALESCE(we.work_order_id, p.work_order_id) AS work_order_id,
           COALESCE(we.material_id,   p.material_id)   AS material_id,
           we.expected_qty,
           COALESCE(p.produced_qty, 0) AS produced_qty
      FROM work_order_expected_outputs we
      FULL JOIN produced p
        ON p.work_order_id = we.work_order_id AND p.material_id = we.material_id
)
SELECT w.id   AS work_order_id,
       w.code AS work_order_code,
       w.status,
       w.scheduled_date,
       'input'::text AS side,
       s.material_id,
       m.code AS material_code,
       m.name AS material_name,
       s.planned_qty     AS planned_or_expected_qty,
       s.consumed_qty    AS actual_qty,
       -- 【没有计划行 = 计划外的物料,差异说不出来】它吃了没人计划过的料,
       -- 这本身就是要看见的事,但"差多少"没有被减数 —— 所以是 NULL,不是负数。
       CASE WHEN s.planned_qty IS NULL THEN NULL
            ELSE s.consumed_qty - s.planned_qty END AS variance_qty,
       (s.planned_qty IS NOT NULL) AS has_plan
  FROM work_orders w
  JOIN input_side s ON s.work_order_id = w.id
  LEFT JOIN materials m ON m.id = s.material_id
 WHERE has_permission('module.processing.view'::text)
UNION ALL
SELECT w.id, w.code, w.status, w.scheduled_date,
       'output'::text,
       s.material_id, m.code, m.name,
       s.expected_qty,
       s.produced_qty,
       -- 【没有预期就没有差异】—— 不是 produced - 0。见视图头第 ② 条。
       CASE WHEN s.expected_qty IS NULL THEN NULL
            ELSE s.produced_qty - s.expected_qty END,
       (s.expected_qty IS NOT NULL)
  FROM work_orders w
  JOIN output_side s ON s.work_order_id = w.id
  LEFT JOIN materials m ON m.id = s.material_id
 WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.work_order_fulfilment IS
    'WO-1b:计划 vs 实绩,一张工单 × 一侧(input/output)× 一种物料一行。
【has_plan = false 的意思是"没人计划过这一项",而 variance_qty 因此是 NULL,不是负数】—— 同理输出侧的 has_plan(承载 expected 是否存在)。没估过 ≠ 估了零;一个 COALESCE(...,0) 会让任何产出都成为超额完成。
【被冲销的加工不算数】链接是历史(work_order_id 留在被冲销的那一行上),它断言过的消耗不是 —— 与 amend_work_order 的地板、cancel_work_order 的 WO_HAS_RUNS 同一口径。
【计划外的加工(work_order_id 为空)按定义不在这张视图里】它们是一个具名的类别,由报表单列,而不是在这里造一行"计划为零";没有人计划过零。
【不重算回收率】投入金属 ÷ 产出金属属于 processing_metal_recovery。这张视图只把计划与实绩相比。';
