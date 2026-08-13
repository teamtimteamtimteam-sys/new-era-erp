-- db/migrations/2026-08-13-rpt1-report-center-views.sql
-- RPT-1:报表中心的两张派生视图 —— 而【三态判据从此只有一处】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀最重要的动作不是加视图,是把一段谓词搬出来】
-- NTF-1 的 notify_class_violations 体内写着三态判据(未分类不算、未配置不算、
-- 配了且不含这一类才算)。报表中心要问的是【同一个问题的全库答案】。
-- 抄一份过去就是第二份会漂开的判据,而漂开的后果特别难看:
--     通知说"这是违规",报表说"没有违规" —— 或者反过来。
-- 所以判据搬进 stock_class_violations_rows(),两个消费者【读同一处】:
--     * 发射器(触发器里跑)读函数;
--     * 报表读视图 stock_class_violations = 函数 + has_permission 那道门。
--
-- 【为什么是"函数 + 视图"而不是一张带 has_permission 的视图】
-- 这是对既定写法的一次【有理由的偏离】,理由写在这里而不是留给下一个人猜:
-- has_permission 解析的是【调用者】(current_user_permissions)。发射器跑在
-- 触发器里,而触发它的人未必持有 module.inventory.view —— 一个只有
-- materials.edit 的角色改了物料分类,事件【照样必须留下】。若发射器读的是带门
-- 的视图,那种情况下它会读到零行,然后【安安静静地什么都不发】。
-- 实测:今天九个角色里,每一个持 module.materials.edit 的都恰好也持
-- module.inventory.view,所以这是一个【潜伏】的洞,不是正在漏的洞。但它不会
-- 报错、不会红,只会少一条事件 —— 正是本仓库反复付账的那种形状。
-- 于是:门留在视图上(给读报表的人),判据留在函数里(给两个消费者)。
--
-- 【为什么函数对客户端收权】它不带门。给了 authenticated,任何登录用户都能
-- 绕开视图直接读全库违规 —— 那正是视图那道门要拦的事。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【stock_snapshot:未指定库位是一个【状态】,不是缺失的数据】
-- 线上 85 行流水里有 79 行没有库位(IOD-1 之前写的)。快照按 物料 × 库位 × 状态
-- 汇总,如果把 location_id IS NULL 那一格丢掉或渲染成空白,这张报表会【悄悄
-- 漏掉绝大多数台账】。LOC-1/STK-1 早就把"未指定"定成一等状态:货是真的,
-- 只是还没有记录放在哪。所以它在视图里就是一行普通的行,在页面上是一个普通的
-- 分组,不是一个脚注。
--
-- 【派生,从不存储】这张视图每次现算。库存不是一个存下来的数字 —— 存下来的是
-- 流水,余额是它的和(STK-1)。任何"为了快"把它固化成表的想法,都要先回答
-- 那个表由谁维护、以及它与流水对不上的时候谁说了算。
--
-- 镜像:db/views/{stock_class_violations,stock_snapshot}.sql、
--       db/functions/{stock_class_violations_rows,notify_class_violations}.sql、
--       db/views/zzz_function_grants.sql。
-- 行为断言:fixture 62(本刀);fixture 61 【一个字不改】—— 它现在透过函数
--           间接走同一条判据,这正是"一处实现、两个消费者"要证明的事。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 三态判据:唯一的一处 ═══════════════════════════════════════════════
-- 【不带 has_permission】—— 门在视图那一层。见抬头:发射器的行为不该取决于
-- 触发它的人有没有库存模块的读权限。
CREATE OR REPLACE FUNCTION public.stock_class_violations_rows()
 RETURNS TABLE(material_id uuid, material_code text, class_code text,
               location_id uuid, location_code text, qty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
                          AND c.classification_code = m.waste_classification_code)
$function$;

COMMENT ON FUNCTION public.stock_class_violations_rows() IS
    'RPT-1:分类违规的【唯一一处判据】。三态:未分类不算(没人做过决定)、未配置不算(同上)、配了且不含这一类才算。两个消费者读同一处 —— notify_class_violations(NTF-1 的发射器)与视图 stock_class_violations(报表中心)。【不带 has_permission】:门在视图那一层,因为发射器跑在触发器里,而触发它的人未必持有 module.inventory.view;读带门的视图会让它在那种情况下静悄悄地不发事件。对 authenticated 收权 —— 它不带门,给了就等于绕开视图直接读全库违规。';

-- ═══ 2 · 报表侧:同一判据 + 那道门 ══════════════════════════════════════════
CREATE VIEW public.stock_class_violations WITH (security_invoker = off) AS
 SELECT v.material_id, v.material_code, v.class_code,
        v.location_id, v.location_code, v.qty
   FROM stock_class_violations_rows() v
  WHERE has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.stock_class_violations IS
    'RPT-1:当前【全库】的分类违规(物料 × 库位),报表中心读它。判据不在这里 —— 在 stock_class_violations_rows(),与 NTF-1 的发射器同一处;这一层只加 has_permission 那道门。属主权限:invoker 会让 RLS 丢行,而一张报表少报一行违规,等于说"没有违规"。【它只答"此刻还有哪些"】;"改变的那一刻"由 NTF-1 的通知回答,两者是同一判据的两个时态。';

GRANT SELECT ON public.stock_class_violations TO authenticated;

-- ═══ 3 · 库存快照:物料 × 库位 × 状态 ═══════════════════════════════════════
CREATE VIEW public.stock_snapshot WITH (security_invoker = off) AS
 SELECT m.id AS material_id,
    m.code AS material_code,
    m.name AS material_name,
    m.unit,
    mv.location_id,
    sl.code AS location_code,
    sl.name AS location_name,
    mv.stock_status,
    sum(mv.qty_delta) AS qty
   FROM inventory_movements mv
     LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = mv.output_batch_id
     JOIN materials m ON m.id = COALESCE(ib.material_id, ob.material_id)
     LEFT JOIN storage_locations sl ON sl.id = mv.location_id
  WHERE m.deleted_at IS NULL
    AND has_permission('module.inventory.view'::text)
  GROUP BY m.id, m.code, m.name, m.unit, mv.location_id, sl.code, sl.name, mv.stock_status
 HAVING sum(mv.qty_delta) <> 0::numeric;

COMMENT ON VIEW public.stock_snapshot IS
    'RPT-1:库存快照(物料 × 库位 × 状态),【派生,从不存储】—— 存下来的是流水,余额是它的和(STK-1)。【location_id IS NULL 是一等状态,不是缺失数据】:线上 85 行流水里 79 行没有库位(IOD-1 之前写的),把这一格丢掉或画成空白,这张报表会悄悄漏掉绝大多数台账。LOC-1/STK-1 早已定下"未指定"的语义:货是真的,只是还没记录放在哪 —— 所以它在这里是一行普通的行,在页面上是一个普通的分组。属主权限 + 体内 has_permission:invoker 让 RLS 丢行,而聚合里丢行等于报出一个错的余额。';

GRANT SELECT ON public.stock_snapshot TO authenticated;

-- ═══ 4 · 发射器改读那一处判据(其余函数体逐字节不动)══════════════════════
-- 取线上 pg_get_functiondef,只替换 FOR ... LOOP 的取数段;去重、指纹、
-- INSERT 那 1491 字节原样保留 —— 搬一段谓词不该顺手重写一个函数(SS-1 教训)。
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
          FROM stock_class_violations_rows() v
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
