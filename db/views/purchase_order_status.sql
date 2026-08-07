-- db/views/purchase_order_status.sql
-- 每张【在册且未取消】的采购订单一行。
-- prepaid_base 只计 status='posted' 收付款中指向该 PO 的核销行(预付);
-- prepaid_applied_base 计 prepayment_applications(预付已冲抵到具体到货批次的部分);
-- 二者之差就是还躺在 1300 预付款项里、尚未落到任何应付上的余额。
-- received_* 只数【未软删】的关联到货批次;ordered_qty 为 0 时 receipt_pct 为 NULL
-- (没有下单量就没有"收了几成"这回事,不能拿 0 当分母)。
-- 【属主权限】(OPS-14 起)—— 见下方 note。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的。【OPS-14 起本视图是属主权限,不再是 invoker】,但这一段的结论
-- 未变:遮蔽视图的把关是 has_permission() 谓词,而 has_permission() 按 auth.uid()
-- 解析【调用者】,与谁拥有外层视图无关 —— 所以模块与数据类边界一字未动。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ module.purchasing.view;三列预付【遮蔽】。
-- 行的存在判据是采购的(在册、未取消),只有三列预付是财务的金额。原先 invoker 时
-- procurement 读 PO-2026-0001 的预付为 0.00,真值 35,000.00 —— 付过的定金,对最该
-- 知道的那个角色显示成没付。
-- 【为什么置 NULL 而不是拆成第二张视图】仓库对"你不该看见的金额"已有成熟表达:
-- cut 2b 的遮蔽列 + lib/permissions.ts 把 null 解释成「受限」。NULL 是"缺席",
-- 0.00 是"错"。列即是"支";拆视图效果相同却把一行 PO 劈成两处读,收益为零。
-- supplier 标签跟着单据走。

CREATE VIEW public.purchase_order_status WITH (security_invoker = off) AS
 SELECT po.id AS po_id,
    po.code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    po.expected_delivery_date,
    po.status,
    po.currency,
    po.estimated_total_ccy,
        CASE WHEN has_permission('module.finance.view'::text)
             THEN round(COALESCE(pre.prepaid, 0::numeric), 2)
             ELSE NULL::numeric END AS prepaid_base,
        CASE WHEN has_permission('module.finance.view'::text)
             THEN round(COALESCE(app.applied, 0::numeric), 2)
             ELSE NULL::numeric END AS prepaid_applied_base,
        CASE WHEN has_permission('module.finance.view'::text)
             THEN round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app.applied, 0::numeric), 2)
             ELSE NULL::numeric END AS prepaid_remaining_base,
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
  WHERE po.deleted_at IS NULL AND po.status <> 'cancelled'::text
    AND has_permission('module.purchasing.view'::text);
