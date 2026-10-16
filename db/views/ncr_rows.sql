-- db/views/ncr_rows.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7 · Q9 · Q22 · Q39,Tim):【一张不合格报告与它此刻的样子】—— 报告清单、报告页、批次页上的暂扣那一行读它。
--   报告自己的列,加上几样显示用的标签(批号、化验单号、销售单号、合同编号、钱的那一张单据的标签 —— 标签跟着单据走,常设决定 3),
--   一行判定的内容(系统开的那一张:参数、值、抄下的限、结果),以及 holding:这一张此刻扣不扣着它那一批(判据 ncr_holds,纯函数 ——
--   这里以属主的眼睛读批次的余量再问它,于是一个只持质量查看码的读者也读得到"拒收而货还在"那一种)。
--   【门】质量查看码,或那一批自己那一页的查看码(与 nonconformance_reports 的读策略同一句)。属主视图:读批次、化验、单据、判定不再过
--   各自的 RLS,所以条件写在末尾的 WHERE 里一次。没有金额,不遮(报告不带金额;钱的那一张单据只给出它的标签)。
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q8):末尾多两列 incident_id / incident_code —— 来源 incident 的那一张指着的事故(编号是标签,跟着单据走)。
--   加在末尾,CREATE OR REPLACE VIEW 不动既有的列。
-- ★ MES-7b-2(2026-10-16,MES-7b Step 0 Q15):末尾再多四列 inspection_finding_id / inspection_run_id / inspection_run_code / inspection_item_position ——
--   来源 inspection 的那一张引用的巡检发现(巡检编号与第几项是标签,跟着单据走)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.

CREATE VIEW public.ncr_rows WITH (security_invoker = off) AS
 SELECT n.id,
    n.code,
    n.status,
    n.source,
        CASE
            WHEN n.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    n.inbound_batch_id,
    n.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    n.description,
    n.assay_result_id,
    a.code AS assay_code,
    n.assay_dispute_id,
    n.sales_order_id,
    so.code AS sales_order_code,
    n.judgement_id,
    j.parameter AS judgement_parameter,
    j.value AS judgement_value,
    j.limit_min_at AS judgement_limit_min,
    j.limit_max_at AS judgement_limit_max,
    j.result AS judgement_result,
    c.code AS judgement_contract_code,
    n.opened_at,
    n.opened_by,
    n.opened_by IS NULL AS opened_by_system,
    n.disposition,
    n.decision_note,
    n.decided_at,
    n.decided_by,
    n.penalty_invoice_request_id,
    ir.label AS penalty_invoice_request_label,
    n.penalty_price_request_id,
    pr.label AS penalty_price_request_label,
    ncr_holds(n.status, n.disposition, COALESCE(ib.deleted_at, ob.deleted_at), COALESCE(ib.remaining_qty, ob.remaining_qty)) AS holding,
    n.incident_id,
    inc.code AS incident_code,
    n.inspection_finding_id,
    isf.run_id AS inspection_run_id,
    isr.code AS inspection_run_code,
    isres.position AS inspection_item_position
   FROM nonconformance_reports n
     LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
     LEFT JOIN assay_results a ON a.id = n.assay_result_id
     LEFT JOIN sales_orders so ON so.id = n.sales_order_id
     LEFT JOIN quality_limit_judgements j ON j.id = n.judgement_id
     LEFT JOIN contracts c ON c.id = j.contract_id
     LEFT JOIN invoice_requests ir ON ir.id = n.penalty_invoice_request_id
     LEFT JOIN receipt_price_requests pr ON pr.id = n.penalty_price_request_id
     LEFT JOIN incidents inc ON inc.id = n.incident_id
     LEFT JOIN inspection_findings isf ON isf.id = n.inspection_finding_id
     LEFT JOIN inspection_runs isr ON isr.id = isf.run_id
     LEFT JOIN inspection_results isres ON isres.id = isf.result_id
  WHERE has_permission('module.quality.view'::text)
     OR (n.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
     OR (n.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text));

COMMENT ON VIEW public.ncr_rows IS
    'MES-6b-1:一张不合格报告与它此刻的样子 —— 报告的列、显示用的标签(批号、化验、销售单、合同、钱的那一张单据,标签跟着单据走)、系统开的那一张的判定内容,以及 holding(这一张此刻扣不扣着它那一批 —— ncr_holds,属主读余量)。门与 nonconformance_reports 的读策略同一句(质量查看码,或那一批自己的查看码)。没有金额。';

GRANT SELECT ON public.ncr_rows TO authenticated;
REVOKE ALL ON public.ncr_rows FROM anon;
