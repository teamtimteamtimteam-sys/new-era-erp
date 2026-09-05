-- db/views/customer_billing_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.customer_billing_lookup WITH (security_invoker = off) AS
 SELECT id,
    payment_terms_days,
    default_tax_code
   FROM customers c
  WHERE has_permission('module.customers.view'::text) OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.customer_billing_lookup IS
    'FIX-2a:客户的【开单条款】视图 —— 只有 id / 付款账期 / 默认税码。开发票的页面要它。★ 刻意【不】把这两列加进 customer_lookup:那张是"叫出客户名字"的广口视图(customers / output / finance / pricing 四个码都读得到),而账期与税码是商务条款。两张视图,两个受众。行谓词 customers.view OR finance.view。没有 credit_limit_base / credit_hold / credit_rating / incoterm —— 授信是另一件事,customer_credit_status 管它。';

GRANT SELECT ON public.customer_billing_lookup TO authenticated;
