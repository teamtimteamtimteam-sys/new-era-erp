-- db/views/supplier_lookup.sql
-- FIX-1 item 3(2026-09-05):供应商的【查名】视图。收货的人必须叫得出他要指向的那家
-- 供应商,而【不】因此拿到付款条件、贸易术语、信用评级、税号或地址 ——
-- 那六列就是 role_permissions 对 warehouse 写的「不接触任何商务数据」。
-- 属主权限 + 体内谓词(xmodule 补法 a,与 supplier_receiving_blocked 同形)。
-- supplies_goods 与 counterparty_type 在列上,是因为两处调用点各拿它们过滤 ——
-- 搬到客户端做不到,那会要求先把不该看的行发下去。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权,请连着 fixture 100 一起想。
-- NOTE: introduced by db/migrations/2026-09-05-fix1-cross-module-lookup-views.sql.

CREATE VIEW public.supplier_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    supplies_goods,
    counterparty_type,
    deleted_at
   FROM suppliers s
  WHERE has_permission('module.suppliers.view'::text) OR has_permission('module.inbound.view'::text);

COMMENT ON VIEW public.supplier_lookup IS
    'FIX-1 item 3:供应商的【查名】视图 —— 只有 id/编号/法定名 + 下拉自己要用的两个判据列(supplies_goods、counterparty_type)。收货与进料编辑用它把单据指向一家供应商,而【不】因此拿到付款条件、贸易术语、信用评级、税号或地址。属主权限 + 体内谓词 suppliers.view OR inbound.view;新读到它的只有 operations 与 warehouse。暴露面就是这张视图的列清单 —— 加列等于扩权,请连着 fixture 100 一起想。';

GRANT SELECT ON public.supplier_lookup TO authenticated;
