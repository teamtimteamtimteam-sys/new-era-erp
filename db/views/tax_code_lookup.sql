-- db/views/tax_code_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.tax_code_lookup WITH (security_invoker = off) AS
 SELECT code,
    side,
    name_en,
    name_zh,
    is_claimable,
    is_active,
    sort_order
   FROM tax_codes t
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.customers.view'::text) OR has_permission('module.suppliers.view'::text);

COMMENT ON VIEW public.tax_code_lookup IS
    'FIX-2a:税码的【查名】视图 —— 码 / 买卖侧 / 中英名 / 可抵扣 / 启用 / 排序。客户与供应商的编辑页要它填"默认税码"那个下拉;此前 sales 与 procurement 拿到一张空下拉,而税码是一张【参考字典】,不是一笔财务数据。行谓词 finance.view OR customers.view OR suppliers.view。没有 F5 申报格位(f5_supply_box / f5_purchase_box / f5_tax_box)—— 那是报税表的结构,不是选一个税码要的东西。';

GRANT SELECT ON public.tax_code_lookup TO authenticated;
