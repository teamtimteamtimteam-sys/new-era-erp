-- PO-GST-1-fu3(2026-09-03)· 清单视图也透出税额与含税额
-- 三列加在【末尾】—— CREATE OR REPLACE VIEW 只允许末尾追加(第一版插在中段,
--   PostgreSQL 报 cannot change name of view column "prepaid_base")。
-- 本视图 FROM purchase_orders_masked,所以遮蔽在上一层已经做过,不必再做一次。
BEGIN;
CREATE OR REPLACE VIEW public.purchase_order_status WITH (security_invoker = off) AS
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
        END AS receipt_pct,
    -- ── PO-GST-1(2026-09-03):清单也要说得出净额 / 税 / 含税额 ──────────────
    -- ★【三列必须加在【末尾】,这不是风格问题】★ CREATE OR REPLACE VIEW 只允许
    --   在末尾追加列。本刀第一版把它们插在 estimated_total_ccy 后面,PostgreSQL
    --   报的是 `cannot change name of view column "prepaid_base" to "tax_total_ccy"`
    --   —— 与 purchase_orders_masked 里 contract_id 那条注释记的是同一件事。
    -- 【这三列不必再遮蔽一次】本视图 FROM 的是 purchase_orders_masked,
    --   税额与含税额在那一层已经按 data.view_prices 置空,遮蔽自然传导。
    -- 【gross 与 purchase_orders_masked 里那一次是同一个表达式,两处都不落库】
    --   导出量不存;fixture 断言两处对同一张单逐分相等。
    po.tax_total_ccy,
    po.estimated_total_ccy + COALESCE(po.tax_total_ccy, 0) AS gross_total_ccy,
    (po.tax_total_ccy IS NOT NULL) AS carries_tax
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
COMMIT;
