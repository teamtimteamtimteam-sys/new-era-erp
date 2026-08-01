-- db/views/ap_open_items.sql
-- AP 开放余额(应付账龄):补充 2a 起是两类单据的 UNION,每张未结清单据一行。
--   * doc_kind 'inbound':已计价、在册的进料批次(规则不变);应付额 = 当前
--     quantity × unit_price(改价即改欠款);无到货日回退 created_at::date。
--   * doc_kind 'expense':挂账(unpaid)、posted 的开支单;应付额 = amount_usd;
--     排除镜像行(被别的开支单指为 reversed_by_expense —— 它只是冲销的记录凭证,
--     不是新的应付单据),已冲销(reversed)的开支自然被 status 条件排除。
-- inbound_batch_id 列保留(expense 行为 NULL)—— 兼容按批次取行的旧调用方。
-- 结清额只计 status='posted' 付款单的核销行。SECURITY INVOKER。
--
-- cut 4a:进料侧的 settled_usd 【还要加上 prepayment_applications】—— 定金冲抵的
-- 那部分钱同样在还这张批次的应付,不计进来的话,一张被定金付清的批次会永远显示未付。
-- 开支侧不受影响(预付只对采购订单成立)。列集未变,故本次是 CREATE OR REPLACE。
--
-- NOTE: prepayment applications folded in by
-- db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql; reworked by
-- db/migrations/2026-07-30-phase3-s2a-expenses.sql
-- (introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql).
-- 列集变了 → 重建时先 DROP VIEW 再 CREATE(CREATE OR REPLACE 改不了列)。

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的,视图体其余部分逐字未变。它仍然是 SECURITY INVOKER:
-- 它读的遮蔽视图自带模块谓词,所以既拿得到数据,也绕不过任何模块边界。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.
CREATE VIEW public.ap_open_items WITH (security_invoker = on) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_usd,
    settled_usd,
    open_usd,
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
            round(ib.quantity * ib.unit_price, 2) AS doc_value_usd,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_usd,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_usd
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
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
            e.amount_usd AS doc_value_usd,
            round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
            round(e.amount_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd
           FROM expenses e
             JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))) d
  WHERE open_usd > 0::numeric;
