-- db/views/po_prepayment_applicable.sql
-- "抵扣预付"的资格与建议额:每个【在册、已计价、挂在还有未抵扣预付的采购单上】的
-- 批次一行 —— 批次未结应付、该单未抵扣预付、可抵扣额 = min(两者)(地板 0,只留 >0)。
-- 【页面的资格判断与建议金额都只从这里读】—— 与 apply_prepayment 的校验同一口径,
-- 界面与函数不可能对"能抵多少"各说各话。SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4c-po-receiving.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的,视图体其余部分逐字未变。它仍然是 SECURITY INVOKER:
-- 它读的遮蔽视图自带模块谓词,所以既拿得到数据,也绕不过任何模块边界。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.
CREATE VIEW public.po_prepayment_applicable WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    po.id AS purchase_order_id,
    po.code AS po_code,
    po.supplier_id,
    round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2) AS batch_ap_open_base,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2) AS po_unapplied_prepayment_base,
    GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) AS applicable_base
   FROM inbound_batches_masked ib
     JOIN purchase_orders_masked po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.inbound_batch_id = ib.id) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.inbound_batch_id = ib.id) app_b ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app_po ON true
  WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL AND GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) > 0::numeric;
