-- db/views/ar_open_items.sql
-- AR 开放余额(应收账龄):每张未结清 sales_record 一行。
-- 结清额只计 status='posted' 收款单的核销行 —— 冲销(reversed)收款的核销自动失效。
-- cut 2a 起增加 invoice_id / invoice_code:经 invoice_lines 反查该销售所挂的【在册】
-- 发票(作废的不算),未开票的销售这两列为 NULL。其余列全部保名保义。
-- SECURITY INVOKER(security_invoker = on),RLS 按查询者身份生效。
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql;
-- invoice 两列由 db/migrations/2026-07-31-phase4-cut2a-invoices.sql 追加(DROP+CREATE)。

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的,视图体其余部分逐字未变。它仍然是 SECURITY INVOKER:
-- 它读的遮蔽视图自带模块谓词,所以既拿得到数据,也绕不过任何模块边界。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.
CREATE VIEW public.ar_open_items WITH (security_invoker = on) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_base,
    round(sr.amount_base - COALESCE(s.settled, 0::numeric), 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.amount_base - COALESCE(s.settled, 0::numeric), 2) > 0::numeric;
