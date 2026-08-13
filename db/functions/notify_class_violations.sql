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
    FOR r IN
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
        SELECT a.location_id, a.material_id, a.qty,
               m.code AS material_code, m.waste_classification_code AS class_code,
               sl.code AS location_code
          FROM avail a
               JOIN materials m          ON m.id  = a.material_id
               JOIN storage_locations sl ON sl.id = a.location_id
         WHERE (p_material_ids IS NULL OR a.material_id = ANY (p_material_ids))
           AND (p_location_ids IS NULL OR a.location_id = ANY (p_location_ids))
           AND m.deleted_at IS NULL
           -- 未分类 = 没人做过决定 → 不是违规
           AND m.waste_classification_code IS NOT NULL
           -- 零行 = 未配置 = 没人做过决定 → 不是违规
           AND EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                        WHERE c.location_id = a.location_id)
           -- 配了、且不含这一类 → 违规
           AND NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                            WHERE c.location_id = a.location_id
                              AND c.classification_code = m.waste_classification_code)
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
