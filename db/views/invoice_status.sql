-- db/views/invoice_status.sql
-- 每张【在册】发票一行(作废的不列)。已结额从明细行背后的 sales_records 的核销行
-- 推导 —— 只计 status='posted' 的收款,与 ar_open_items 同口径。
-- 发票不参与核销:收付款依旧核销到 sales_records,发票只是把它们归拢成一份文件,
-- 所以这里是【派生视图】而不是另一套结算账。
-- SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut2a-invoices.sql.

CREATE OR REPLACE VIEW public.invoice_status
WITH (security_invoker = on) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    c.legal_name AS customer_name,
    i.issue_date,
    i.due_date,
    i.currency,
    i.total_usd,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
    round(i.total_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd,
    GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
        CASE
            WHEN round(i.total_usd - COALESCE(s.settled, 0::numeric), 2) <= 0::numeric THEN 'paid'::text
            WHEN COALESCE(s.settled, 0::numeric) > 0::numeric THEN 'partial'::text
            ELSE 'unpaid'::text
        END AS payment_state,
    CURRENT_DATE > i.due_date AND round(i.total_usd - COALESCE(s.settled, 0::numeric), 2) > 0::numeric AS overdue
   FROM invoices i
     JOIN customers c ON c.id = i.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM invoice_lines il
             JOIN payment_allocations pa ON pa.sales_record_id = il.sales_record_id
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE il.invoice_id = i.id) s ON true
  WHERE i.status <> 'void'::text;
