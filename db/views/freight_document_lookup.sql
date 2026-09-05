-- db/views/freight_document_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.freight_document_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    doc_date,
    currency,
    status,
    payment_status,
    direction,
    supplier_id,
    container_id,
    deleted_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy
   FROM freight_documents d
  WHERE has_permission('module.inbound.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.freight_document_lookup IS
    'FIX-2a:运费单据的【查名】视图 —— 编号 / 单据日 / 币种 / 状态 / 付款状态 / 方向。金额按 data.view_prices 遮。行谓词在既有的 inbound.view OR finance.view 之外加 logistics.view —— 读这两页的守卫就是 logistics.view,此前 sales 通过守卫之后读到零张单据。';

GRANT SELECT ON public.freight_document_lookup TO authenticated;
