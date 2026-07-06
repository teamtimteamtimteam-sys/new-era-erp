-- db/views/ar_open_items.sql
-- AR 开放余额(应收账龄):每张未结清 sales_record 一行。
-- 结清额只计 status='posted' 收款单的核销行 —— 冲销(reversed)收款的核销自动失效。
-- SECURITY INVOKER(security_invoker = on),RLS 按查询者身份生效。
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql.

CREATE OR REPLACE VIEW public.ar_open_items
WITH (security_invoker = on) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_usd,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
    round(sr.amount_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM sales_records sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
  WHERE round(sr.amount_usd - COALESCE(s.settled, 0::numeric), 2) > 0::numeric;
