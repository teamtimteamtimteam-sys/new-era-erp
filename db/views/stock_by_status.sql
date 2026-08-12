-- db/views/stock_by_status.sql
-- STK-1:按 批次 × 库位 × 状态 的库存分布 —— 全部由流水聚合,没有任何一处存下来。
--
-- NOTE: introduced by db/migrations/2026-08-12-stk1-stock-status.sql.
--
-- 【属主权限】借了批次与库位的【显示标签】(code/name/unit)与派生数量,
-- 没有借任何金额 —— OPS-14 的 remedy (a):跨模块借的是派生事实与标签时,
-- 用属主权限 + 把读者自己的模块谓词写在体内。谓词就是下面的 has_permission。
--
-- 【location_id 为 NULL 不是缺陷,今天它是全部】线上 68 行流水一行都没有库位
-- (库位这个轴 LOC-1 才落地),所以每一个批次都会落在"未指定库位"上。
-- 视图照直把 NULL 传出去,由界面渲染成【未指定库位】—— 不隐藏、也不折叠进
-- 任何一个真库位。屏幕在"全部都是未指定"这个状态下必须读起来自然,
-- 而不是看着像出了错。
--
-- 【HAVING <> 0】只是不列出已经走空的桶(暂扣后又全部释放的那种),
-- 它不改变任何总量;真要看历史,流水本身在那里。
CREATE OR REPLACE VIEW public.stock_by_status WITH (security_invoker = off) AS
 SELECT m.inbound_batch_id,
    m.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    COALESCE(ib.unit, ob.unit) AS unit,
    m.location_id,
    l.code AS location_code,
    l.name AS location_name,
    m.stock_status,
    sum(m.qty_delta) AS qty
   FROM inventory_movements m
     LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
     LEFT JOIN storage_locations l ON l.id = m.location_id
  WHERE has_permission('module.inventory.view'::text)
  GROUP BY m.inbound_batch_id, m.output_batch_id, (COALESCE(ib.code, ob.code)), (COALESCE(ib.unit, ob.unit)), m.location_id, l.code, l.name, m.stock_status
 HAVING sum(m.qty_delta) <> 0::numeric;

COMMENT ON VIEW public.stock_by_status IS
    'STK-1:按 批次 × 库位 × 状态 的库存分布,全部由流水聚合得出(没有任何一处存下来)。location_id 为 NULL = 未指定库位 —— 线上今天【全部】流水都是这样(LOC-1 之前没有库位这个轴),界面必须把它渲染成一个可读的"未指定库位",既不隐藏也不折叠进真库位。HAVING <> 0 只是不列出已经走空的桶;它不改变任何总量。';

GRANT SELECT ON public.stock_by_status TO authenticated;
