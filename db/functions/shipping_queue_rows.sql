-- db/functions/shipping_queue_rows.sql
-- APR-5b(2026-09-25,APR-5 grilling Q7 · 5b grilling Q6):仓库的发货队列 —— 放行过的、还没发完的订单行,
-- 连同能发的预留。【一个价格都没有】。
--
-- 【列,逐列就是 Tim 的裁定】订单编号与日期 · 客户的法定名称(常设决定 3:展示标签随单据走)·
--   ★ 送货地址(Tim 2026-09-25,5b Q6:仓库要它才发得了货 —— 常设决定 3 之下的一条【点名的例外】,
--   除此之外【不带任何别的客户属性】)· 放行时刻 · 行号、物料、单位 · 放行数量、已发、剩余 ·
--   活预留:批次、库位、数量。
--   ★ 没有:单价、币种、汇率、金额、毛利、发票编号、余额、信用额度或冻结(冻结由 ship_order 在发货时
--   按名拒 SO_SHIP_CUSTOMER_ON_HOLD —— 那是一次拒绝,不是一个读得到的属性)。
--   fixture 224 逐字钉住本函数的返回列清单。
--
-- 【哪些行】订单 confirmed / partially_shipped、未删除;这一行坐在一条被 approved 放行点名的在册发票行上
--   (覆盖,与 ship_order 同一句);剩余 = sales_order_line_releasable_all.releasable_qty − 已发 > 0。
--   一行没有活预留时照样出现(预留那几列为 NULL):仓库看得见"放行了但还没备货"。
--
-- 【门】action.ship_goods(warehouse · admin)。仓库不持 module.sales.view(Q7):属主权限读订单、客户与
--   放行,在函数体里先按调用者的码把关 —— 零行永远是"没有要发的",不会是"你看不见"。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipping_queue_rows()
 RETURNS TABLE(sales_order_id uuid, order_code text, order_date date, customer_name text, delivery_address text, released_at timestamp with time zone, sales_order_line_id uuid, line_no integer, material_code text, material_name text, unit text, released_qty numeric, shipped_qty numeric, remaining_qty numeric, reservation_id uuid, output_batch_code text, location_code text, location_name text, reserved_qty numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    PERFORM require_permission('action.ship_goods');

    RETURN QUERY
    WITH lines AS (
        SELECT so.id AS so_id, so.code AS so_code, so.order_date AS so_date,
               c.legal_name AS cust_name, c.address AS cust_address,
               (SELECT max(r.decided_at) FROM shipping_release_lines rl
                  JOIN shipping_releases r ON r.id = rl.release_id
                 WHERE rl.sales_order_line_id = sol.id AND r.status = 'approved') AS rel_at,
               sol.id AS sol_id, sol.line_no AS sol_no, m.code AS m_code, m.name AS m_name, m.unit AS m_unit,
               (SELECT ra.releasable_qty FROM sales_order_line_releasable_all ra
                 WHERE ra.sales_order_line_id = sol.id LIMIT 1) AS rel_qty,
               COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl WHERE sl.sales_order_line_id = sol.id), 0) AS shp_qty
          FROM sales_order_lines sol
          JOIN sales_orders so ON so.id = sol.sales_order_id
          JOIN customers c ON c.id = so.customer_id
          JOIN materials m ON m.id = sol.material_id
         WHERE so.deleted_at IS NULL
           AND so.status IN ('confirmed', 'partially_shipped')
           AND EXISTS (SELECT 1 FROM shipping_release_lines rl
                         JOIN shipping_releases r ON r.id = rl.release_id
                         JOIN invoice_lines il ON il.id = rl.invoice_line_id
                         JOIN invoices i ON i.id = il.invoice_id
                        WHERE rl.sales_order_line_id = sol.id AND r.status = 'approved'
                          AND NOT il.invoice_voided AND i.kind = 'order' AND i.status = 'issued')
    )
    SELECT l.so_id, l.so_code, l.so_date, l.cust_name, l.cust_address, l.rel_at,
           l.sol_id, l.sol_no, l.m_code, l.m_name, l.m_unit,
           l.rel_qty, l.shp_qty, l.rel_qty - l.shp_qty,
           res.id, ob.code, loc.code, loc.name, res.qty
      FROM lines l
      LEFT JOIN sales_order_reservations res
             ON res.sales_order_line_id = l.sol_id AND res.released_at IS NULL AND res.consumed_at IS NULL
      LEFT JOIN output_batches ob ON ob.id = res.output_batch_id
      LEFT JOIN storage_locations loc ON loc.id = res.location_id
     WHERE l.rel_qty - l.shp_qty > 0
     ORDER BY l.rel_at, l.so_code, l.sol_no, ob.code;
END;
$function$
;
