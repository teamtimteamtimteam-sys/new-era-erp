-- db/functions/shipment_document.sql
-- APR-5b(2026-09-25,5b grilling Q7):一张发货单要印的东西 —— 表头(发货单号、日期、订单编号、客户编号与
-- 法定名称)与行(数量、批次、单位、物料、废物分类、发货时的库位)。发货单页与发货单 PDF 都读它。
--
-- 【为什么是一支属主权限的读者】发货单此前经内嵌读 sales_orders 与 customers(RLS:module.sales.view /
-- module.customers.view)与 materials(module.materials.view);仓库三个都不持(Q7:不给仓库 sales.view),
-- 于是它发得了货、印不出它刚发的那张单。这里读全量,先按调用者的码把关。
-- 【没有价格】发货单本来就不带价(发货单行没有价格列);客户只给编号与法定名称(常设决定 3 的展示标签)。
-- 【门】module.sales.view 或 action.ship_goods —— 与三张发货表的读策略同一对码。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipment_document(p_shipment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s record;
BEGIN
    IF NOT has_any_permission(ARRAY['module.sales.view', 'action.ship_goods']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.ship_goods';
    END IF;

    SELECT s.id, s.code, s.ship_date, s.created_at, so.id AS order_id, so.code AS order_code,
           c.code AS customer_code, c.legal_name AS customer_name
      INTO v_s
      FROM shipments s
      JOIN sales_orders so ON so.id = s.sales_order_id
      LEFT JOIN customers c ON c.id = so.customer_id
     WHERE s.id = p_shipment_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
        'id', v_s.id,
        'code', v_s.code,
        'ship_date', v_s.ship_date,
        'created_at', v_s.created_at,
        'order_id', v_s.order_id,
        'order_code', v_s.order_code,
        'customer_code', v_s.customer_code,
        'customer_name', v_s.customer_name,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', sl.id,
                       'qty', sl.qty,
                       'line_no', sol.line_no,
                       'batch_code', ob.code,
                       'unit', ob.unit,
                       'material_code', m.code,
                       'material_name', m.name,
                       'waste_classification_code', m.waste_classification_code,
                       'location_code', loc.code,
                       'location_name', loc.name) ORDER BY sl.created_at, sol.line_no)
              FROM shipment_lines sl
              JOIN sales_order_lines sol ON sol.id = sl.sales_order_line_id
              JOIN output_batches ob ON ob.id = sl.output_batch_id
              LEFT JOIN materials m ON m.id = ob.material_id
              LEFT JOIN storage_locations loc ON loc.id = sl.location_id
             WHERE sl.shipment_id = v_s.id), '[]'::jsonb));
END;
$function$
;
