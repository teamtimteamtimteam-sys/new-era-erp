-- db/views/batch_assay_status.sql
-- 每个在册进料批次一行:定价状态、公式、化验汇总(份数、最新一份及其执行状态、
-- 是否有未执行的化验)、关联采购单。驱动批次页化验面板与未来的"待化验"工作清单。
-- 最新一份按 assay_date DESC, created_at DESC, code DESC —— code 作平局裁决
-- (同一事务里 created_at 会相同,编号无缝单调,排序必须确定)。SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql.

CREATE OR REPLACE VIEW public.batch_assay_status
WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    sup.legal_name AS supplier_name,
    m.name AS material_name,
    ib.quantity,
    ib.unit,
    ib.unit_price,
    ib.pricing_status,
    ib.pricing_formula_id,
    pf.code AS formula_code,
    COALESCE(a.assay_count, 0::bigint) AS assay_count,
    a.latest_assay_id,
    a.latest_assay_code,
    a.latest_assay_date,
    COALESCE(a.latest_assay_applied, false) AS latest_assay_applied,
    COALESCE(a.has_unapplied_assay, false) AS has_unapplied_assay,
    ib.purchase_order_id,
    po.code AS po_code
   FROM inbound_batches ib
     JOIN suppliers sup ON sup.id = ib.supplier_id
     JOIN materials m ON m.id = ib.material_id
     LEFT JOIN pricing_formulas pf ON pf.id = ib.pricing_formula_id
     LEFT JOIN purchase_orders po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT count(*) AS assay_count,
            bool_or(ar.applied_at IS NULL) AS has_unapplied_assay,
            (array_agg(ar.id ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_id,
            (array_agg(ar.code ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_code,
            (array_agg(ar.assay_date ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_date,
            (array_agg(ar.applied_at IS NOT NULL ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_applied
           FROM assay_results ar
          WHERE ar.inbound_batch_id = ib.id AND ar.deleted_at IS NULL) a ON true
  WHERE ib.deleted_at IS NULL;
