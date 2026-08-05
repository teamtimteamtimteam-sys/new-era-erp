-- FIN-14:ap_open_items 不再把币种写死成 'SGD'。
--
-- 【为什么要紧】进料这一支的未结项把 currency 直接投影成字面量 'SGD'。今天没错
-- (unit_price 就是本位币),但它已经【被人当条件用了】:FIN-12 给
-- /finance/payments 的可核销清单加了 `i.currency === 付款币种` 的过滤,
-- 服务端也按 ALLOC_CURRENCY_MISMATCH 校验。换一次本位币,这一支的所有 AP 单据
-- 会突然与所有付款都不匹配,而且是【静默】的:清单空了,不报错。
-- 这正是把币种当常量的那一类,只是长在 SQL 里 —— 也正因如此,
-- scripts/check-currency-literals.mjs 本轮才扩到扫 db/。

BEGIN;

CREATE OR REPLACE VIEW public.ap_open_items WITH (security_invoker = on) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_base,
    settled_base,
    open_base,
    currency,
    open_ccy,
    CURRENT_DATE - doc_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - doc_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - doc_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - doc_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_base,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_base,
            ( SELECT c.code FROM currencies c WHERE c.is_base) AS currency,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) * e.fx_rate, 2) AS settled_base,
            round((e.amount_ccy - COALESCE(s.settled, 0::numeric)) * e.fx_rate, 2) AS open_base,
            e.currency,
            round(e.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy
           FROM expenses e
             JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))) d
  WHERE open_ccy > 0::numeric;

COMMIT;
