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
$function$

;
