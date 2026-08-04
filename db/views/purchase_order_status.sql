-- db/views/purchase_order_status.sql
-- 每张【在册且未取消】的采购订单一行。
-- prepaid_base 只计 status='posted' 收付款中指向该 PO 的核销行(预付);
-- prepaid_applied_base 计 prepayment_applications(预付已冲抵到具体到货批次的部分);
-- 二者之差就是还躺在 1300 预付款项里、尚未落到任何应付上的余额。
-- received_* 只数【未软删】的关联到货批次;ordered_qty 为 0 时 receipt_pct 为 NULL
-- (没有下单量就没有"收了几成"这回事,不能拿 0 当分母)。
-- SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的,视图体其余部分逐字未变。它仍然是 SECURITY INVOKER:
-- 它读的遮蔽视图自带模块谓词,所以既拿得到数据,也绕不过任何模块边界。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.
CREATE VIEW public.purchase_order_status WITH (security_invoker = on) AS
 SELECT po.id AS po_id,
    po.code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    po.expected_delivery_date,
    po.status,
    po.currency,
    po.estimated_total_usd,
    round(COALESCE(pre.prepaid, 0::numeric), 2) AS prepaid_base,
    round(COALESCE(app.applied, 0::numeric), 2) AS prepaid_applied_base,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app.applied, 0::numeric), 2) AS prepaid_remaining_base,
    COALESCE(rec.batches, 0::bigint) AS received_batches,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(COALESCE(ord.qty, 0::numeric), 4) AS ordered_qty,
        CASE
            WHEN COALESCE(ord.qty, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE round(COALESCE(rec.qty, 0::numeric) / ord.qty * 100::numeric, 2)
        END AS receipt_pct
   FROM purchase_orders_masked po
     JOIN suppliers sup ON sup.id = po.supplier_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS batches,
            sum(ib.quantity) AS qty
           FROM inbound_batches_masked ib
          WHERE ib.purchase_order_id = po.id AND ib.deleted_at IS NULL) rec ON true
     LEFT JOIN LATERAL ( SELECT sum(pol.quantity) AS qty
           FROM purchase_order_lines_masked pol
          WHERE pol.purchase_order_id = po.id) ord ON true
  WHERE po.deleted_at IS NULL AND po.status <> 'cancelled'::text;
