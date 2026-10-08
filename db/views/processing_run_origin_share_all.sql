-- db/views/processing_run_origin_share_all.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q4 · Q14,Tim):【一炉的投入里,有多少来自哪一个"源头批次"】—— 基视图,不给人读。
--   源头 = 每一个进料批次,以及每一个【不是由加工产出】的产出批次(手工建的产出批 —— 它往上没有加工单可追)。
--   份额就是 batch_balance_tree_all 往下走时算出来的那一份(按投入质量成比例,逐层乘下去):一炉经由某个源头的每一条路径
--   分到的投入之和 ÷ 这一炉的投入。只有消耗那几炉(flow = consumption)。同一炉在全部源头上的份额加起来 = 1
--   (这里是一次除法,得率的分组用它 —— 屏幕上是百分数;批次那棵树本身不做这次除法,它保持精确)。
--   供应商与化学体系两种分组经它走到源头批次(Q14):进料批的供应商与物料的化学体系;手工产出批没有供应商。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_origin_share_all WITH (security_invoker = off) AS
 SELECT t.run_id,
    t.root_kind,
    t.root_id,
    sum(t.qty) / f.input_qty AS share
   FROM batch_balance_tree_all t
     JOIN processing_run_flow_all f ON f.run_id = t.run_id
  WHERE t.node_type = 'run'::text AND t.line_key = 'consumption'::text AND f.input_qty > 0::numeric
    AND (t.root_kind = 'inbound'::text OR NOT (EXISTS ( SELECT 1
           FROM processing_outputs po
          WHERE po.output_batch_id = t.root_id)))
  GROUP BY t.run_id, t.root_kind, t.root_id, f.input_qty;

COMMENT ON VIEW public.processing_run_origin_share_all IS
    'MES-5b-1:一炉(消耗)的投入里来自每一个源头批次(进料批,或不由加工产出的产出批)的份额,按投入质量成比例逐层乘下去;同一炉的份额之和 = 1。供应商与化学体系的得率分组经它走到源头。基视图,不给人读。';

REVOKE ALL ON public.processing_run_origin_share_all FROM authenticated, anon;
