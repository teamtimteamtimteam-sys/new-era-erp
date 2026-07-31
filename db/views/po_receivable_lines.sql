-- db/views/po_receivable_lines.sql
-- 收货表单的一把查:每张【可收货】(confirmed / receiving)采购单的每一行 ——
-- 下单量、已收量(Σ 挂在【该行】上的在册批次)、剩余量(超收是常态,剩余量地板 0)、
-- 计价公式与预计化验(收货后计价用得上)。
-- inbound/new 与现场收货页的"关联采购单"下拉都只从这里读。SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4c-po-receiving.sql.

CREATE OR REPLACE VIEW public.po_receivable_lines
WITH (security_invoker = on) AS
 SELECT po.id AS po_id,
    po.code AS po_code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id,
    m.name AS material_name,
    pol.quantity AS ordered_qty,
    pol.unit,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(GREATEST(pol.quantity - COALESCE(rec.qty, 0::numeric), 0::numeric), 4) AS remaining_qty,
    pol.pricing_formula_id,
    pol.estimated_unit_price,
    pol.expected_assay
   FROM purchase_orders po
     JOIN suppliers sup ON sup.id = po.supplier_id
     JOIN purchase_order_lines pol ON pol.purchase_order_id = po.id
     JOIN materials m ON m.id = pol.material_id
     LEFT JOIN LATERAL ( SELECT sum(ib.quantity) AS qty
           FROM inbound_batches ib
          WHERE ib.purchase_order_line_id = pol.id AND ib.deleted_at IS NULL) rec ON true
  WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]));
