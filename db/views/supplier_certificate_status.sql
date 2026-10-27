-- db/views/supplier_certificate_status.sql
-- SYSTEM-MAP-2(Tim 2026-10-27 SYSTEM-MAP-1 Q3 → 64d-2):安全 › 供应商证书总览的那一行,带【状态】。
--   一张在册证书(没删、供应商没删)一行;status = certificate_expiry_status(有效期, 种类的 disposition, 种类的 warn_lead_days)——
--   与提醒页 qualification_expiring 那一支读的是同一支判据(db/functions/certificate_expiry_status.sql),不另写一份。
-- 【属主权限 + module.suppliers.view】与 supplier_compliance 自己的读策略同一个码;供应商名字是单据的标签(跟着行走)。
-- 【只读】Supabase 的默认权限让新视图对 authenticated 可写(MES7B1-VIEW-DEFAULT-WRITE-GRANTS),所以 REVOKE ALL 再 GRANT SELECT。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE VIEW public.supplier_certificate_status WITH (security_invoker = off) AS
 SELECT sc.id,
    sc.supplier_id,
    s.code AS supplier_code,
    s.legal_name AS supplier_name,
    sc.cert_type_code,
    sc.cert_no,
    sc.issuing_body,
    sc.valid_from,
    sc.valid_until,
    certificate_expiry_status(sc.valid_until, ct.disposition, ct.warn_lead_days) AS status
   FROM supplier_compliance sc
     JOIN suppliers s ON s.id = sc.supplier_id
     JOIN certificate_types ct ON ct.code = sc.cert_type_code
  WHERE sc.deleted_at IS NULL AND s.deleted_at IS NULL AND has_permission('module.suppliers.view'::text);

COMMENT ON VIEW public.supplier_certificate_status IS
    'SYSTEM-MAP-2:供应商证书总览,每张在册证书一行,带 status(certificate_expiry_status —— 与提醒页同一支判据)。属主权限 + module.suppliers.view;只读。';

REVOKE ALL ON public.supplier_certificate_status FROM authenticated, anon;
GRANT SELECT ON public.supplier_certificate_status TO authenticated;
