-- db/views/po_receivable_lines_lookup.sql
-- FIX-1 item 3(2026-09-05):收货表单的【可收货采购单行】—— 十列,【一列价都没有】。
-- 对照 po_receivable_lines:那一张带 estimated_unit_price / pricing_formula_id /
-- expected_assay,而且读三张 _masked 伴生视图(它们体内各自挂 purchasing.view,
-- 所以只改最外层是一次空操作)。本视图读基表,自己挂谓词。
-- ★ 它做了 GRN-1a 抬头明说留给以后的那个决定(让 inbound.view 看得见订量),
--   但只开收货表单要的那十列;grn_discrepancies 【没有】跟着放宽 —— 那是单独一刀。
-- ★ 两份「可收货」的定义从此有两个实现:fixture 100 的 D 条把两者的行集钉在一起。
-- NOTE: introduced by db/migrations/2026-09-05-fix1-cross-module-lookup-views.sql.

CREATE VIEW public.po_receivable_lines_lookup WITH (security_invoker = off) AS
 SELECT po.id AS po_id,
    po.code AS po_code,
    po.supplier_id,
    po.order_date,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id,
    m.name AS material_name,
    pol.unit,
    round(GREATEST(pol.quantity - COALESCE(rec.qty, 0::numeric), 0::numeric), 4) AS remaining_qty
   FROM purchase_orders po
     JOIN purchase_order_lines pol ON pol.purchase_order_id = po.id
     JOIN materials m ON m.id = pol.material_id
     LEFT JOIN LATERAL ( SELECT sum(ib.quantity) AS qty
           FROM inbound_batches ib
          WHERE ib.purchase_order_line_id = pol.id AND ib.deleted_at IS NULL) rec ON true
  WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text])) AND (has_permission('module.purchasing.view'::text) OR has_permission('module.inbound.view'::text));

COMMENT ON VIEW public.po_receivable_lines_lookup IS
    'FIX-1 item 3:收货表单的【可收货采购单行】查名视图 —— 十列,【一列价都没有】(对照 po_receivable_lines 带 estimated_unit_price / pricing_formula_id / expected_assay)。它做了 GRN-1a 抬头明说留给以后的那个决定:让 inbound.view 也看得见订量,但只开收货表单要的那十列。属主权限 + 体内谓词 purchasing.view OR inbound.view;新读到它的只有 operations 与 warehouse。grn_discrepancies 【没有】跟着放宽 —— 那是单独一刀。';

GRANT SELECT ON public.po_receivable_lines_lookup TO authenticated;
