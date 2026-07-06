-- db/views/ap_open_items.sql
-- AP 开放余额(应付账龄):每个已计价、未结清的在册进料批次一行。
-- 应付额 = 当前 quantity × unit_price(改价即改欠款);无到货日回退 created_at::date。
-- 结清额只计 status='posted' 付款单的核销行。SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql.

CREATE OR REPLACE VIEW public.ap_open_items
WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS doc_code,
    ib.supplier_id,
    sup.legal_name AS supplier_name,
    COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
    round(ib.quantity * ib.unit_price, 2) AS amount_usd,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
    round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric), 2) AS open_usd,
    CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date) AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date)) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date)) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date)) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM inbound_batches ib
     JOIN suppliers sup ON sup.id = ib.supplier_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.inbound_batch_id = ib.id) s ON true
  WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL AND round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric), 2) > 0::numeric;
