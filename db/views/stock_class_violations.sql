-- db/views/stock_class_violations.sql
-- RPT-1:当前【全库】的分类违规(物料 × 库位)。报表中心读它。
--
-- NOTE: recreated by db/migrations/2026-08-13-rpt1-fu1-predicate-as-base-view.sql.
--
-- 【判据不在这里】在 stock_class_violations_all —— 与 NTF-1 的发射器同一处。
-- 本层只加 has_permission 那道门。fixture 62 G 臂用一次注入证明两个消费者
-- 【同时】失守 —— 那才叫同一处。
--
-- 【两个时态】本视图答"此刻还有哪些";NTF-1 的通知答"改变的那一刻发生了什么"。

CREATE VIEW public.stock_class_violations WITH (security_invoker = off) AS
 SELECT material_id,
    material_code,
    class_code,
    location_id,
    location_code,
    qty
   FROM stock_class_violations_all v
  WHERE has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.stock_class_violations IS
    'RPT-1:当前【全库】的分类违规(物料 × 库位),报表中心读它。判据不在这里 —— 在 stock_class_violations_all,与 NTF-1 的发射器同一处;这一层只加 has_permission 那道门。属主权限:invoker 会让 RLS 丢行,而一张报表少报一行违规,等于说"没有违规"。【它只答"此刻还有哪些"】;"改变的那一刻"由 NTF-1 的通知回答,两者是同一判据的两个时态。';

GRANT SELECT ON public.stock_class_violations TO authenticated;
