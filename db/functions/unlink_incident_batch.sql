-- db/functions/unlink_incident_batch.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q7,Tim):【这一批其实没碰过这件事故】—— 解一条链接,理由必填。module.safety.edit。
--   那一行链接只改这一次(unlinked_at / unlinked_by / unlink_reason);之后不改、不删(guard_incident_batch_write)。
--   按名拒:找不到(INCIDENT_LINK_NOT_FOUND|<id>)· 已经解过(INCIDENT_LINK_ALREADY_UNLINKED|<批号>)· 没有理由(INCIDENT_UNLINK_REASON_REQUIRED)。
--   不碰安全状态、不碰库存、不碰挂在那一批上的不合格报告(那张报告由决定它的人放行)。返回 {link_id}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.unlink_incident_batch(p_link_id bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link record;
BEGIN
    PERFORM require_permission('module.safety.edit');
    SELECT b.*, COALESCE(ib.code, ob.code) AS batch_code INTO v_link
      FROM incident_batches b
      LEFT JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
      LEFT JOIN output_batches ob ON ob.id = b.output_batch_id
     WHERE b.id = p_link_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INCIDENT_LINK_NOT_FOUND|%', COALESCE(p_link_id::text, '?');
    END IF;
    IF v_link.unlinked_at IS NOT NULL THEN
        RAISE EXCEPTION 'INCIDENT_LINK_ALREADY_UNLINKED|%', v_link.batch_code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INCIDENT_UNLINK_REASON_REQUIRED';
    END IF;
    UPDATE incident_batches
       SET unlinked_at = now(), unlinked_by = auth.uid(), unlink_reason = btrim(p_reason)
     WHERE id = p_link_id;
    RETURN jsonb_build_object('link_id', p_link_id);
END;
$function$;
