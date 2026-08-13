-- db/views/stock_snapshot.sql
-- RPT-1:库存快照(物料 × 库位 × 状态)。
--
-- NOTE: introduced by db/migrations/2026-08-13-rpt1-report-center-views.sql.
--
-- 【派生,从不存储】存下来的是流水,余额是它的和(STK-1)。想把它固化成表之前,
-- 先回答:那张表由谁维护?它与流水对不上的时候谁说了算?
--
-- 【location_id IS NULL 是一等状态,不是缺失数据】线上 85 行流水里 79 行没有
-- 库位(IOD-1 之前写的)。把这一格丢掉或画成空白,这张报表会【悄悄漏掉绝大多数
-- 台账】。LOC-1/STK-1 早已定下它的语义:货是真的,只是还没记录放在哪。
-- 所以它在这里是一行普通的行,在页面上是一个普通的分组。fixture 62 E 臂钉住它。
--
-- 【属主权限 + 体内 has_permission】invoker 让 RLS 丢行,而聚合里丢一行
-- 等于报出一个错的余额 —— 一个错的余额比没有报表更坏。

CREATE VIEW public.stock_snapshot WITH (security_invoker = off) AS
 SELECT m.id AS material_id,
    m.code AS material_code,
    m.name AS material_name,
    m.unit,
    mv.location_id,
    sl.code AS location_code,
    sl.name AS location_name,
    mv.stock_status,
    sum(mv.qty_delta) AS qty
   FROM inventory_movements mv
     LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = mv.output_batch_id
     JOIN materials m ON m.id = COALESCE(ib.material_id, ob.material_id)
     LEFT JOIN storage_locations sl ON sl.id = mv.location_id
  WHERE m.deleted_at IS NULL AND has_permission('module.inventory.view'::text)
  GROUP BY m.id, m.code, m.name, m.unit, mv.location_id, sl.code, sl.name, mv.stock_status
 HAVING sum(mv.qty_delta) <> 0::numeric;

COMMENT ON VIEW public.stock_snapshot IS
    'RPT-1:库存快照(物料 × 库位 × 状态),【派生,从不存储】—— 存下来的是流水,余额是它的和(STK-1)。【location_id IS NULL 是一等状态,不是缺失数据】:线上 85 行流水里 79 行没有库位(IOD-1 之前写的),把这一格丢掉或画成空白,这张报表会悄悄漏掉绝大多数台账。LOC-1/STK-1 早已定下"未指定"的语义:货是真的,只是还没记录放在哪 —— 所以它在这里是一行普通的行,在页面上是一个普通的分组。属主权限 + 体内 has_permission:invoker 让 RLS 丢行,而聚合里丢行等于报出一个错的余额。';

GRANT SELECT ON public.stock_snapshot TO authenticated;
