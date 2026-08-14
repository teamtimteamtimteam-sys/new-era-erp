-- db/views/invoice_status.sql
-- 每张【在册】发票一行(作废的不列)。已结额从明细行背后的 sales_records 的核销行
-- 推导 —— 只计 status='posted' 的收款,与 ar_open_items 同口径。
-- 发票不参与核销:收付款依旧核销到 sales_records,发票只是把它们归拢成一份文件,
-- 所以这里是【派生视图】而不是另一套结算账。
-- 【SO-3a:订单流发票不同 —— 它自己就是核销对象】kind='order' 的发票在开票当刻
-- 过账,收款直接核销到 payment_allocations.invoice_id 上;所以已结额是【两条腿
-- 之和】:sale 头走行背后的销售(老路,原样),order 头走指向发票本身的核销行。
-- 两条腿按构造不相交:sale 行没有 invoice_id 核销,order 行没有 sales_record_id。
-- 【属主权限】(OPS-14 起)—— 见下方 note。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut2a-invoices.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的。【OPS-14 起本视图是属主权限,不再是 invoker】,但这一段的结论
-- 未变:遮蔽视图的把关是 has_permission() 谓词,而 has_permission() 按 auth.uid()
-- 解析【调用者】,与谁拥有外层视图无关 —— 所以模块与数据类边界一字未动。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ 整表挂 module.finance.view。
-- payment_state 与 open_base 都是从核销额推的,理由同 ap_open_items。
-- customer 标签跟着单据走。

CREATE VIEW public.invoice_status WITH (security_invoker = off) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    c.legal_name AS customer_name,
    i.issue_date,
    i.due_date,
    i.currency,
    i.total_base,
    round(COALESCE(s.settled, 0::numeric) + COALESCE(sd.settled, 0::numeric), 2) AS settled_base,
    round(i.total_base - COALESCE(s.settled, 0::numeric) - COALESCE(sd.settled, 0::numeric), 2) AS open_base,
    GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
        CASE
            WHEN round(i.total_base - COALESCE(s.settled, 0::numeric) - COALESCE(sd.settled, 0::numeric), 2) <= 0::numeric THEN 'paid'::text
            WHEN COALESCE(s.settled, 0::numeric) + COALESCE(sd.settled, 0::numeric) > 0::numeric THEN 'partial'::text
            ELSE 'unpaid'::text
        END AS payment_state,
    CURRENT_DATE > i.due_date AND round(i.total_base - COALESCE(s.settled, 0::numeric) - COALESCE(sd.settled, 0::numeric), 2) > 0::numeric AS overdue,
    i.kind
   FROM invoices_masked i
     JOIN customers c ON c.id = i.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM invoice_lines_masked il
             JOIN payment_allocations pa ON pa.sales_record_id = il.sales_record_id
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE il.invoice_id = i.id) s ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.invoice_id = i.id) sd ON true
  WHERE i.status <> 'void'::text AND has_permission('module.finance.view'::text);
