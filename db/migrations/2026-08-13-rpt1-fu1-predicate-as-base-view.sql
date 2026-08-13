-- db/migrations/2026-08-13-rpt1-fu1-predicate-as-base-view.sql
-- RPT-1 续:判据从【函数】改成【基视图】—— 属主视图替得了表,替不了函数的 EXECUTE
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【冒烟查出来的,而且是一次真的 500】
--     ✗ /inventory/reports/violations → HTTP 500
--       permission denied for function stock_class_violations_rows
--
-- 原来的形状是:属主权限视图 stock_class_violations 里【调一个被收权的函数】。
-- 这行不通,而原因值得记下来,因为它不直观:
--   * security_invoker = off 让视图【对它引用的表/视图】用【视图属主】的权限;
--   * 但视图体里【调用函数】时,EXECUTE 仍然按【当前用户】判 ——
--     属主替换不覆盖函数执行权限。
-- 于是 authenticated 读那张视图,踩在被 REVOKE 掉的函数上,当场 42501。
--
-- 【改法:把判据放进一张【基视图】,而不是一个函数】视图引用视图【是】走属主
-- 替换的,所以两个消费者都读得到,而客户端读不到基视图:
--     stock_class_violations_all  ← 判据,REVOKE SELECT(客户端读不到)
--     stock_class_violations      ← 上面那张 + has_permission,GRANT 给 authenticated
--     notify_class_violations     ← 直接读基视图(以属主身份,不受调用者权限影响)
-- 【判据仍然只有一处】,这一点没有变 —— 变的只是它住在视图里而不是函数里。
--
-- 【为什么不干脆把函数授权给 authenticated】那等于把那道门拆了:任何登录用户
-- 都能绕过 has_permission 直接读全库违规。门必须留着,所以换的是判据的载体。
--
-- 镜像:db/views/{stock_class_violations_all,stock_class_violations}.sql、
--       db/functions/notify_class_violations.sql、db/views/zzz_function_grants.sql
--       (函数没了,那一行 REVOKE 一并删掉)。
-- 行为断言:fixture 62(目录断言改指基视图)、fixture 61 仍然一字不改。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- 先解开依赖:视图与发射器都还指着那个函数
DROP VIEW public.stock_class_violations;

CREATE VIEW public.stock_class_violations_all WITH (security_invoker = off) AS
    WITH avail AS (
        SELECT mv.location_id,
               COALESCE(ib.material_id, ob.material_id) AS material_id,
               sum(mv.qty_delta) AS qty
          FROM inventory_movements mv
               LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
               LEFT JOIN output_batches  ob ON ob.id = mv.output_batch_id
         WHERE mv.stock_status = 'available'
           AND mv.location_id IS NOT NULL
         GROUP BY 1, 2
        HAVING sum(mv.qty_delta) > 0
    )
    SELECT a.material_id,
           m.code AS material_code,
           m.waste_classification_code AS class_code,
           a.location_id,
           sl.code AS location_code,
           a.qty
      FROM avail a
           JOIN materials m          ON m.id  = a.material_id
           JOIN storage_locations sl ON sl.id = a.location_id
     WHERE m.deleted_at IS NULL
       -- 未分类 = 没人做过决定 → 不是违规
       AND m.waste_classification_code IS NOT NULL
       -- 零行 = 未配置 = 没人做过决定 → 不是违规
       AND EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                    WHERE c.location_id = a.location_id)
       -- 配了、且不含这一类 → 违规
       AND NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                        WHERE c.location_id = a.location_id
                          AND c.classification_code = m.waste_classification_code);

COMMENT ON VIEW public.stock_class_violations_all IS
    'RPT-1:分类违规的【唯一一处判据】(三态:未分类不算、未配置不算、配了且不含这一类才算)。两个消费者读同一处 —— notify_class_violations(NTF-1 的发射器,以属主身份直接读它)与 stock_class_violations(报表侧,在它之上加 has_permission 那道门)。【客户端读不到本视图】:REVOKE SELECT —— 它不带门,能读它就等于绕过那道门读全库违规。【为什么是视图而不是函数】属主权限视图对它引用的表/视图走属主替换,但视图体里调函数时 EXECUTE 仍按当前用户判 —— 前一版把判据放在被收权的函数里,authenticated 读报表当场 42501(冒烟查出来的)。';

REVOKE SELECT ON public.stock_class_violations_all FROM authenticated, anon;

CREATE VIEW public.stock_class_violations WITH (security_invoker = off) AS
 SELECT v.material_id, v.material_code, v.class_code,
        v.location_id, v.location_code, v.qty
   FROM stock_class_violations_all v
  WHERE has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.stock_class_violations IS
    'RPT-1:当前【全库】的分类违规(物料 × 库位),报表中心读它。判据不在这里 —— 在 stock_class_violations_all,与 NTF-1 的发射器同一处;这一层只加 has_permission 那道门。属主权限:invoker 会让 RLS 丢行,而一张报表少报一行违规,等于说"没有违规"。【它只答"此刻还有哪些"】;"改变的那一刻"由 NTF-1 的通知回答,两者是同一判据的两个时态。';

GRANT SELECT ON public.stock_class_violations TO authenticated;

DROP FUNCTION public.stock_class_violations_rows();


-- 发射器改读基视图(其余函数体逐字节不动)
CREATE OR REPLACE FUNCTION public.notify_class_violations(p_cause text, p_material_ids uuid[], p_location_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r       record;
    v_fp    text;
    v_actor uuid := auth.uid();
BEGIN
    -- RPT-1:判据【搬出去了】—— 三态谓词现在只住在 stock_class_violations_rows()
    -- 里,本函数与报表中心的那张视图【读的是同一处】。此前它写在这里,而报表
    -- 要的是同一个问题的全库答案:抄一份过去,就是第二份会漂开的三态判据,
    -- 而漂开的后果是"通知说违规、报表说没有"(或反过来)。
    -- 【为什么读函数而不是那张视图】视图体里带 has_permission —— 那是给【读报表
    -- 的人】用的门。发射器跑在触发器里,行为不该取决于【当时那个人】有没有库存
    -- 模块的读权限:一个只有 materials.edit 的角色改了分类,事件照样必须留下。
    -- 今天每个持 materials.edit 的角色恰好都有 inventory.view,所以这是一个
    -- 【潜伏】的洞而不是已经在漏的洞 —— 但它不会报错,只会静悄悄地不发事件。
    FOR r IN
        SELECT v.location_id, v.material_id, v.qty,
               v.material_code, v.class_code, v.location_code
          FROM stock_class_violations_all v
         WHERE (p_material_ids IS NULL OR v.material_id = ANY (p_material_ids))
           AND (p_location_ids IS NULL OR v.location_id = ANY (p_location_ids))
    LOOP
        v_fp := r.material_id::text || '|' || r.location_id::text || '|' || r.class_code;

        -- 去重:同指纹且【未读】的已经在 → 不再写
        IF EXISTS (
            SELECT 1 FROM notifications n
             WHERE n.payload ->> 'fingerprint' = v_fp
               AND NOT EXISTS (SELECT 1 FROM notification_reads nr
                                WHERE nr.notification_id = n.id))
        THEN
            CONTINUE;
        END IF;

        INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload, actor_user_id)
        VALUES (
            CASE p_cause WHEN 'material_reclassified' THEN 'class_violation_after_reclassify'
                         ELSE 'class_violation_after_config' END,
            CASE p_cause WHEN 'material_reclassified' THEN 'material' ELSE 'storage_location' END,
            CASE p_cause WHEN 'material_reclassified' THEN r.material_id ELSE r.location_id END,
            CASE p_cause WHEN 'material_reclassified' THEN r.material_code ELSE r.location_code END,
            jsonb_build_object('fingerprint', v_fp,
                               'class', r.class_code,
                               'qty', trim_scale(r.qty),
                               'material_id', r.material_id, 'material_code', r.material_code,
                               'location_id', r.location_id, 'location_code', r.location_code),
            v_actor);
    END LOOP;
END;
$function$;

COMMIT;
