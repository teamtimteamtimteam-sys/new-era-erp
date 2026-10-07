-- db/views/nea_category_on_hand_all.sql
-- MES-3a(2026-10-06,MES-0 Q32;MES-3a Step 0 Q7 · Q8,Tim):【每一类 NEA 废物此刻在厂里有多少吨】—— 基视图,不给人读。
--   存量 = 每一批(进料 + 产出)的流水之和(Σ qty_delta,三种库存状态都算 —— 暂扣与已承诺的货也还在厂里),
--   只算还有货的批(≠ 0;注销的批由它的注销腿归零),按物料【此刻】的 nea_waste_category_code 归类,换成吨(quantity_in_tonnes)。
--   unconvertible_batches = 这一类里单位换算不成吨的批数(件 / 别的);tonnes 只加得进换算得了的那些 —— 所以读的人必须先看这一格。
--   读它的:receipt_ceiling_check_internal(收货那一笔事务里,锁了执照行之后读 —— 这一批自己的入库流水已经在里面)·
--   storage_ceiling_status(读者视图)· operations_now 的 storage_ceiling_exceeded 臂。
--   【属主视图、从 authenticated 收回】与 weighing_calibration_all 同形:收货的人不一定持库存查看码,判法却不能因此少算一批。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.nea_category_on_hand_all WITH (security_invoker = off) AS
 SELECT m.nea_waste_category_code AS category_code,
    count(*) AS batches,
    sum(quantity_in_tonnes(b.qty, b.unit)) AS tonnes,
    count(*) FILTER (WHERE quantity_in_tonnes(b.qty, b.unit) IS NULL) AS unconvertible_batches
   FROM ( SELECT ib.material_id,
            ib.unit,
            sum(mv.qty_delta) AS qty
           FROM inventory_movements mv
             JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
          GROUP BY ib.id, ib.material_id, ib.unit
        UNION ALL
         SELECT ob.material_id,
            ob.unit,
            sum(mv.qty_delta) AS qty
           FROM inventory_movements mv
             JOIN output_batches ob ON ob.id = mv.output_batch_id
          GROUP BY ob.id, ob.material_id, ob.unit) b
     JOIN materials m ON m.id = b.material_id
  WHERE b.qty <> 0::numeric AND m.nea_waste_category_code IS NOT NULL
  GROUP BY m.nea_waste_category_code;

COMMENT ON VIEW public.nea_category_on_hand_all IS
    'MES-3a:每一类 NEA 废物此刻在厂里的吨数(进料 + 产出批的流水之和,三种库存状态都算,按物料此刻的类别归类)与换算不成吨的批数。基视图,不给人读:收货的判法与 storage_ceiling_status 以属主身份读它。';

REVOKE ALL ON public.nea_category_on_hand_all FROM anon, authenticated;
