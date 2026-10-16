-- db/views/spare_part_stock.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q13 · Q15,Tim):【备件库存 —— 机器页的"出备件"表单从这里挑批】。一行 = 一张 spare_part 物料的进料批
--   (没注销)。它回答表单在按之前必须先知道的三件事,用的是 issue_spare_parts 自己的判据(复述同一列、同一个比较,不是代指):
--     available_qty   可用桶里有多少(stock_status = 'available' 的流水之和 —— 出库只从这个桶取,PART_ISSUE_EXCEEDS_AVAILABLE 比的就是它)
--     priced          这一批有没有采购价(unit_price IS NOT NULL —— SPARE_PART_UNPRICED 判的就是这一列;暂定价也是价)
--     hold_ncr_code   它在不在质量暂扣里(ncr_holds 是暂扣唯一的判据,与 batch_quality_hold 同一句;给的是报告编号,一个标签)
--   ★ 【不带钱】priced 是一个布尔(派生出来的事实),不是价格:一个持 module.inventory.edit 而看不见价格的仓管,要知道的只是"这一批出不出得了",
--     不是"它值多少"(AGENTS.md xmodule 的处置 (a):派生的事实走属主权限,门写回视图体里)。pricing_status 照原样带着(它在列清单授权里)。
--   ★ 为什么不直接读 inbound_batches:那张表的价格列对这些读者是收回的,而 pricing_status 的默认值是 provisional —— 一批从没定过价的货
--     也读作 provisional,用它当"有没有价"会让表单与函数说两句不同的话(GST-3「屏幕上的判据若是数据库判据的代名词」)。
--   门:module.inventory.view(出库的码 module.inventory.edit 蕴含它)。属主权限:读批次、流水与不合格报告都不过 RLS,所以门写在体里。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE VIEW public.spare_part_stock WITH (security_invoker = off) AS
 SELECT b.id AS inbound_batch_id,
    b.code AS batch_code,
    m.id AS material_id,
    m.code AS material_code,
    m.name AS material_name,
    b.unit,
    COALESCE(( SELECT sum(mv.qty_delta) AS sum
           FROM inventory_movements mv
          WHERE mv.inbound_batch_id = b.id AND mv.stock_status = 'available'::text), 0::numeric) AS available_qty,
    b.remaining_qty,
    b.unit_price IS NOT NULL AS priced,
    b.pricing_status,
    ( SELECT n.code
           FROM nonconformance_reports n
          WHERE n.inbound_batch_id = b.id AND ncr_holds(n.status, n.disposition, b.deleted_at, b.remaining_qty)
          ORDER BY n.opened_at, n.code
         LIMIT 1) AS hold_ncr_code,
    b.arrival_date
   FROM inbound_batches b
     JOIN materials m ON m.id = b.material_id
  WHERE b.deleted_at IS NULL AND m.kind_code = 'spare_part'::text AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.spare_part_stock IS
    'MES-7a-2:备件(spare_part)的进料批与它们出不出得了 —— 可用数量、有没有采购价(布尔,不是价格)、在不在质量暂扣里(报告编号)。判据与 issue_spare_parts 逐字同源。门 module.inventory.view,属主权限。不带钱。';

GRANT SELECT ON public.spare_part_stock TO authenticated;
REVOKE ALL ON public.spare_part_stock FROM anon;
