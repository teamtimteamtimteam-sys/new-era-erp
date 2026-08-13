-- db/views/material_stock_available.sql
-- SS-1:按物料的【可用】库存 —— 安全库存告警唯一的取数处
--
-- 【一处求和,不是第二份 drain 逻辑】判据只有一句 stock_status = 'available'。
-- 这与 derived_stock_qty 是【同一条规则】,只是粒度不同(它按 批次×库位×状态,
-- 这里按物料)。流水【怎么产生】的逻辑写在别处,这里只把已经产生的加起来。
--
-- 【为什么不逐批次去调 derived_stock_qty】一个物料要调 N 次;而且它自带
-- require_permission —— 权限该由本视图的谓词表达一次,不该被一个算子在每行上抛。
--
-- 【暂扣不算,这是判据的一部分】阈值问的是"还有多少【能用】的货"。把 on_hold
-- 算进可用,一次暂扣就能把缺货掩盖掉 —— 那恰好是告警最该说话的时刻。
-- fixture 60 E 臂钉住它,G 臂用故障注入证明那条断言真的有牙。
--
-- 【属主权限 + 体内谓词】(AGENTS.md 修法 (a))本视图跨 materials 与
-- inventory_movements。invoker 会让 RLS 把读者无权的行静默丢掉,而【聚合里丢行
-- 等于可用量偏小,偏小会凭空造出告警】。所以属主权限读全量,谓词按调用者裁决:
-- 无权的读者一行都没有,而不是一个错的数。
--
-- NOTE: introduced by db/migrations/2026-08-13-ss1-safety-stock-alerts.sql.

CREATE VIEW public.material_stock_available WITH (security_invoker = off) AS
 SELECT m.id AS material_id,
    m.code,
    m.name,
    m.unit,
    m.safety_stock_qty,
    COALESCE(s.available_qty, 0::numeric) AS available_qty,
    s.last_movement_date
   FROM materials m
     LEFT JOIN ( SELECT COALESCE(ib.material_id, ob.material_id) AS material_id,
            sum(mv.qty_delta) AS available_qty,
            max(mv.business_date) AS last_movement_date
           FROM inventory_movements mv
             LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = mv.output_batch_id
          WHERE mv.stock_status = 'available'::text
          GROUP BY (COALESCE(ib.material_id, ob.material_id))) s ON s.material_id = m.id
  WHERE m.deleted_at IS NULL AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.material_stock_available IS
    'SS-1:按物料的【可用】库存(stock_status = ''available'' 的流水求和,两种批次都算)。与 derived_stock_qty 同一条规则、不同粒度 —— 那个按 批次×库位×状态,这个按物料;没有复制任何 drain/状态流转逻辑。【暂扣不算】:阈值问的是"还有多少能用的货",而一次暂扣若能掩盖缺货,这个告警恰好在最该说话的时刻哑掉。属主权限 + 体内 has_permission —— invoker 会让 RLS 丢行,而聚合里丢行等于可用量偏小,偏小会【凭空造出告警】。';

GRANT SELECT ON public.material_stock_available TO authenticated;
