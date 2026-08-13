-- db/views/stock_class_violations_all.sql
-- RPT-1:分类违规的【唯一一处判据】(基视图)。
--
-- NOTE: introduced by db/migrations/2026-08-13-rpt1-fu1-predicate-as-base-view.sql.
--
-- 【为什么是视图而不是函数 —— 冒烟查出来的】前一版把判据放进一个被收权的
-- SQL 函数,再由属主权限视图去调它。那行不通:security_invoker = off 让视图
-- 对它引用的【表/视图】走属主替换,但视图体里【调函数】时 EXECUTE 仍按当前
-- 用户判。于是 authenticated 打开报表当场 42501 permission denied for function。
-- 视图引用视图【走】属主替换,所以判据改成一张基视图,两个消费者都读得到:
--     notify_class_violations(NTF-1 发射器,属主身份直接读)
--     stock_class_violations(报表侧,在它之上加 has_permission 那道门)
--
-- 【客户端读不到本视图】REVOKE SELECT —— 它不带门,读得到它就等于绕过那道门。

CREATE VIEW public.stock_class_violations_all WITH (security_invoker = off) AS
 WITH avail AS (
         SELECT mv.location_id,
            COALESCE(ib.material_id, ob.material_id) AS material_id,
            sum(mv.qty_delta) AS qty
           FROM inventory_movements mv
             LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = mv.output_batch_id
          WHERE mv.stock_status = 'available'::text AND mv.location_id IS NOT NULL
          GROUP BY mv.location_id, (COALESCE(ib.material_id, ob.material_id))
         HAVING sum(mv.qty_delta) > 0::numeric
        )
 SELECT a.material_id,
    m.code AS material_code,
    m.waste_classification_code AS class_code,
    a.location_id,
    sl.code AS location_code,
    a.qty
   FROM avail a
     JOIN materials m ON m.id = a.material_id
     JOIN storage_locations sl ON sl.id = a.location_id
  WHERE m.deleted_at IS NULL AND m.waste_classification_code IS NOT NULL AND (EXISTS ( SELECT 1
           FROM storage_location_allowed_classes c
          WHERE c.location_id = a.location_id)) AND NOT (EXISTS ( SELECT 1
           FROM storage_location_allowed_classes c
          WHERE c.location_id = a.location_id AND c.classification_code = m.waste_classification_code));

COMMENT ON VIEW public.stock_class_violations_all IS
    'RPT-1:分类违规的【唯一一处判据】(三态:未分类不算、未配置不算、配了且不含这一类才算)。两个消费者读同一处 —— notify_class_violations(NTF-1 的发射器,以属主身份直接读它)与 stock_class_violations(报表侧,在它之上加 has_permission 那道门)。【客户端读不到本视图】:REVOKE SELECT —— 它不带门,能读它就等于绕过那道门读全库违规。【为什么是视图而不是函数】属主权限视图对它引用的表/视图走属主替换,但视图体里调函数时 EXECUTE 仍按当前用户判 —— 前一版把判据放在被收权的函数里,authenticated 读报表当场 42501(冒烟查出来的)。';

REVOKE SELECT ON public.stock_class_violations_all FROM authenticated, anon;
