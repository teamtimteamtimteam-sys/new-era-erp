-- db/views/quarantine_exposure.sql
-- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q20,Tim):【该在隔离区、却还放在别处的货】。
--   一行 = 一批 × 一个【不是隔离库位】的库位桶(未指定也算不是),那一桶里还有货,而这一批身上开着一条
--   requires_quarantine = true 的状态(引导:鼓包或漏液)。来路:一个状态记在了已经放好的货上(记下永远不拒,Q20)、
--   一次回滚把料还回原库位、盘点盘盈落在未指定 —— 这几条路不能拒,所以在这里被标出来。
--   读它的:批次页的横幅 · /inventory/storage-safety · operations_now 的 quarantine_required 臂。下一次移动只能进隔离(Q19)。
--   【属主视图 + 逐行谓词】进料行 module.inbound.view,产出行 module.output.view。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.quarantine_exposure WITH (security_invoker = off) AS
 SELECT q.batch_kind,
    q.batch_id,
    q.batch_code,
    q.safety_state_code,
    d.name_en,
    d.name_zh,
    q.recorded_on,
    q.location_id,
    l.code AS location_code,
    q.qty
   FROM ( SELECT 'inbound'::text AS batch_kind,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            (s.created_at AT TIME ZONE 'Asia/Singapore'::text)::date AS recorded_on,
            mv.location_id,
            sum(mv.qty_delta) AS qty
           FROM inbound_batch_safety_states s
             JOIN inbound_safety_states sd ON sd.code = s.safety_state_code AND sd.requires_quarantine IS TRUE
             JOIN inbound_batches b ON b.id = s.inbound_batch_id
             JOIN inventory_movements mv ON mv.inbound_batch_id = b.id
             LEFT JOIN storage_locations ml ON ml.id = mv.location_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND NOT COALESCE(ml.is_quarantine, false)
            AND has_permission('module.inbound.view'::text)
          GROUP BY b.id, b.code, s.safety_state_code, s.created_at, mv.location_id
         HAVING sum(mv.qty_delta) <> 0::numeric
        UNION ALL
         SELECT 'output'::text AS batch_kind,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            (s.created_at AT TIME ZONE 'Asia/Singapore'::text)::date AS recorded_on,
            mv.location_id,
            sum(mv.qty_delta) AS qty
           FROM output_batch_safety_states s
             JOIN inbound_safety_states sd ON sd.code = s.safety_state_code AND sd.requires_quarantine IS TRUE
             JOIN output_batches b ON b.id = s.output_batch_id
             JOIN inventory_movements mv ON mv.output_batch_id = b.id
             LEFT JOIN storage_locations ml ON ml.id = mv.location_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND NOT COALESCE(ml.is_quarantine, false)
            AND has_permission('module.output.view'::text)
          GROUP BY b.id, b.code, s.safety_state_code, s.created_at, mv.location_id
         HAVING sum(mv.qty_delta) <> 0::numeric) q
     JOIN inbound_safety_states d ON d.code = q.safety_state_code
     LEFT JOIN storage_locations l ON l.id = q.location_id;

COMMENT ON VIEW public.quarantine_exposure IS
    'MES-3a:身上开着一条要隔离的状态(requires_quarantine,引导:鼓包或漏液)、却还有货放在非隔离库位(含未指定)的批 × 库位桶。只标出来,不拒(记下状态永远不拒,Q20);下一次移动只能进隔离。逐行谓词:进料 module.inbound.view,产出 module.output.view。';

GRANT SELECT ON public.quarantine_exposure TO authenticated;
REVOKE ALL ON public.quarantine_exposure FROM anon;
