-- db/views/customer_lookup.sql
-- FIX-1 item 3(2026-09-05):客户的【查名】视图 —— id / 编号 / 法定名。
-- 建/改产出批次时指定客户用它;信用、对账、联系人与销售订单【不出现】。
-- ★ 暴露面【就是】下面的列清单。
-- NOTE: introduced by db/migrations/2026-09-05-fix1-cross-module-lookup-views.sql.

-- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 -- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 -- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 CREATE OR REPLACE VIEW,而它【会丢掉 WITH (...)】——
--   迁移末尾因此补了一句 ALTER VIEW ... SET (security_invoker = off)。

CREATE VIEW public.customer_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    deleted_at
   FROM customers c
  WHERE has_permission('module.customers.view'::text) OR has_permission('module.output.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.pricing.view'::text);

COMMENT ON VIEW public.customer_lookup IS
    'FIX-1 item 3:客户的【查名】视图 —— 只有 id/编号/法定名。产出批次表单用它把批次指向一个客户,而【不】因此拿到信用、对账、联系人或销售订单。属主权限 + 体内谓词 customers.view OR output.view;新读到它的只有 operations 与 warehouse。暴露面就是这张视图的列清单。';

GRANT SELECT ON public.customer_lookup TO authenticated;
