-- db/views/po_prepayment_applicable.sql
-- "抵扣预付"的资格与建议额:每个【在册、已计价、挂在还有未抵扣预付的采购单上】的
-- 批次一行 —— 批次未结应付、该单未抵扣预付、可抵扣额 = min(两者)(地板 0,只留 >0)。
-- 【页面的资格判断与建议金额都只从这里读】—— 与 apply_prepayment 的校验同一口径,
-- 界面与函数不可能对"能抵多少"各说各话。【属主权限】—— 见 OPS-14 note。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4c-po-receiving.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的。【OPS-14 起本视图是属主权限,不再是 invoker】,但这一段的结论
-- 未变:遮蔽视图的把关是 has_permission() 谓词,而 has_permission() 按 auth.uid()
-- 解析【调用者】,与谁拥有外层视图无关 —— 所以模块与数据类边界一字未动。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ module.finance.view。
-- 本视图算"能抵多少",而 apply_prepayment 要 module.finance.edit —— 它本来就只服务
-- 财务这一个动作。原先 invoker 时,没有财务的读者把 settled 读成 0,applicable_base 偏大。
-- 【它是 OPS-14 判据的盲区,记在这里】它的模块集在目录里看起来只有一个:采购/进料
-- 那一侧是经 <表>_masked 进来的,不是 RLS 基表,于是 pg_policy 里看不见。
-- 病是一样的,判据看不见 —— 绿不等于到处干净。

CREATE VIEW public.po_prepayment_applicable WITH (security_invoker = off) AS
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
  WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
    AND GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) > 0::numeric
    AND has_permission('module.finance.view'::text);
