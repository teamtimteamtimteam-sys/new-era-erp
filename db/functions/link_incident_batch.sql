-- db/functions/link_incident_batch.sql
-- MES-7b-1(2026-10-16,MES-0 Q73;MES-7b Step 0 Q7,Tim):【确认一批货碰过这件事故】—— module.safety.edit。一个人按下一次,建一行链接。
--   basis = location / machine_run:确认一条建议 —— 这一批此刻必须仍在 suggest_incident_batches 的那一种建议里
--     (INCIDENT_LINK_NOT_SUGGESTED|<种类>|<批号>:建议是从记录算出来的,不由页面送来的字说了算);
--   basis = picked:按批号挑任何一批(存在、没删)。
--   按名拒:恰好一批(INCIDENT_LINK_ONE_BATCH)· 依据不认得(INCIDENT_LINK_BASIS_INVALID|<值>)· 找不到事故 / 批次 ·
--   这一批已经有一条有效链接挂在这件事故上(INCIDENT_BATCH_ALREADY_LINKED|<批号>)。
--   【一条链接从不设任何安全状态,也不动库存】(MES-0 Q73,Tim)—— 本函数只写 incident_batches 这一行。要扣住那一批,是事故页上开一张
--   来源 incident 的不合格报告(Q8)。返回 {link_id}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.link_incident_batch(p_incident_id uuid, p_basis text, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch uuid := COALESCE(p_inbound_batch_id, p_output_batch_id);
    v_kind  text := CASE WHEN p_inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END;
    v_code  text;
    v_id    bigint;
BEGIN
    PERFORM require_permission('module.safety.edit');
    IF p_incident_id IS NULL OR NOT EXISTS (SELECT 1 FROM incidents WHERE id = p_incident_id) THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', COALESCE(p_incident_id::text, '?');
    END IF;
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'INCIDENT_LINK_ONE_BATCH';
    END IF;
    IF p_basis IS NULL OR p_basis NOT IN ('location', 'machine_run', 'picked') THEN
        RAISE EXCEPTION 'INCIDENT_LINK_BASIS_INVALID|%', COALESCE(p_basis, '?');
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT code INTO v_code FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
        END IF;
    ELSE
        SELECT code INTO v_code FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
        END IF;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('incident_link_' || p_incident_id::text)::bigint);
    IF p_basis <> 'picked' AND NOT EXISTS (
        SELECT 1 FROM suggest_incident_batches(p_incident_id) s
         WHERE s.basis = p_basis AND s.batch_kind = v_kind AND s.batch_id = v_batch) THEN
        RAISE EXCEPTION 'INCIDENT_LINK_NOT_SUGGESTED|%|%', p_basis, v_code;
    END IF;
    IF EXISTS (SELECT 1 FROM incident_batches x
                WHERE x.incident_id = p_incident_id AND x.unlinked_at IS NULL
                  AND COALESCE(x.inbound_batch_id, x.output_batch_id) = v_batch) THEN
        RAISE EXCEPTION 'INCIDENT_BATCH_ALREADY_LINKED|%', v_code;
    END IF;
    INSERT INTO incident_batches (incident_id, inbound_batch_id, output_batch_id, basis, linked_by)
    VALUES (p_incident_id, p_inbound_batch_id, p_output_batch_id, p_basis, auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('link_id', v_id, 'batch_code', v_code);
END;
$function$;
