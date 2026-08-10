-- 收货会被 CMP-1 拦截的供应商(CMP-2)—— 页面问数据库"这家收货会不会被拒",
-- 谓词与 guard_inbound_po_receivable 的证书段【同一份】(供应商未删、block 类型、
-- valid_until < CURRENT_DATE)。fixture 37F 钉"视图有行 ⇔ 收货被拒",改一边要改两边。
-- 属主权限 + 体内 module.inbound.view 谓词(xmodule 补法 a);借来的只有供应商 code
-- 与证书名 —— 标签随行,实体属性不随(三条常设决定之三)。
-- 日期比较在库内(CURRENT_DATE,新加坡时区,FIN-20)—— 不在 JS 里算"今天"。
CREATE VIEW public.supplier_receiving_blocked WITH (security_invoker = off) AS
 SELECT sc.supplier_id,
    s.code AS supplier_code,
    ct.code AS cert_type_code,
    ct.name_en,
    ct.name_zh,
    sc.valid_until
   FROM supplier_compliance sc
     JOIN certificate_types ct ON ct.code = sc.cert_type_code
     JOIN suppliers s ON s.id = sc.supplier_id
  WHERE has_permission('module.inbound.view'::text) AND sc.deleted_at IS NULL AND ct.disposition = 'block'::text AND sc.valid_until IS NOT NULL AND sc.valid_until < CURRENT_DATE;

COMMENT ON VIEW public.supplier_receiving_blocked IS
    '收货会被 CMP-1 拦截的供应商(CMP-2)。谓词与 guard_inbound_po_receivable 的证书段【同一份】—— fixture 37F 钉两者一致,改一边要改两边。表单用它把"为什么点不动"写在按钮旁,而不是让操作员对着灰钮猜。';

GRANT SELECT ON public.supplier_receiving_blocked TO authenticated;
