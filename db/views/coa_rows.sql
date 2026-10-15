-- db/views/coa_rows.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q10 · Q14 · Q30 · Q32,Tim):【分析证书的读面】—— 清单页、证书页、批次页的证书一块、销售单页的下载都读它。
--   每一张证书一行:号、状态、那一批的批号、点名的销售单号与客户名、说话的那一份化验的编号、签发时刻与签发人(快照里冻的那一份)、
--   作废的理由与时刻、替代它的那一张的号、字节档案在不在、碰到它的那一张在等的作废申请的 label。
--   【判据 = 证书表自己的读策略】module.output.view(Q30:看证书跟着那一批的查看码)。
--   【属主权限】客户名与销售单号是【这张证书的显示标签】(AGENTS.md 常设决定 3:标签跟着单据走)—— 看得见证书的人看得见它是给谁的,
--   不必另持 module.sales.view / module.customers.view;除了名字与单号,客户与销售单的任何别的属性都不经这里。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.

CREATE VIEW public.coa_rows WITH (security_invoker = off) AS
 SELECT c.id,
    c.code,
    c.status,
    c.output_batch_id,
    ob.code AS batch_code,
    c.sales_order_id,
    so.code AS sales_order_code,
    COALESCE(cu.short_name, cu.legal_name) AS customer_name,
    c.governing_assay_id,
    ga.code AS governing_assay_code,
    c.issued_at,
    c.snapshot -> 'issuer' ->> 'name' AS issued_by_name,
    c.snapshot -> 'issuer' ->> 'position' AS issued_by_position,
    c.void_reason,
    c.voided_at,
    c.replaced_by_coa_id,
    rc.code AS replaced_by_code,
    (EXISTS ( SELECT 1
           FROM coa_issues i
          WHERE i.coa_id = c.id)) AS has_bytes,
    ( SELECT r.label
           FROM warehouse_requests r
          WHERE r.coa_id = c.id AND r.status = 'submitted'::text
         LIMIT 1) AS open_request_label
   FROM certificates_of_analysis c
     JOIN output_batches ob ON ob.id = c.output_batch_id
     JOIN assay_results ga ON ga.id = c.governing_assay_id
     LEFT JOIN sales_orders so ON so.id = c.sales_order_id
     LEFT JOIN customers cu ON cu.id = so.customer_id
     LEFT JOIN certificates_of_analysis rc ON rc.id = c.replaced_by_coa_id
  WHERE has_permission('module.output.view'::text);

COMMENT ON VIEW public.coa_rows IS
    'MES-6b-2:分析证书的读面 —— 号、状态、批号、点名的销售单号与客户名(标签跟着单据走)、说话的化验编号、签发时刻与签发人(快照里的)、作废、替代它的号、字节在不在、在等的作废申请。属主权限,谓词 = 证书表的读策略(module.output.view)。';

GRANT SELECT ON public.coa_rows TO authenticated;
REVOKE ALL ON public.coa_rows FROM anon;
