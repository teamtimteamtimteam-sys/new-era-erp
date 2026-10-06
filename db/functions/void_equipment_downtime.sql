-- db/functions/void_equipment_downtime.sql
-- U1-B(2026-10-05,UNBLOCK-1 Q15):作废一段【从来没有发生过】的停机,带理由。不硬删(guard_downtime_write)。
--
-- 【谁】module.processing.edit —— 与记停机、更正停机同一个码(车间记它,车间收回它)。
-- 【什么时候不行】已经作废的(DOWNTIME_ALREADY_VOIDED);没有理由(DOWNTIME_VOID_REASON_REQUIRED —— 一段消失的停机,
--   "为什么"是读它的人唯一的线索)。开着的与关了的都可以作废:一段记错了的开口也正是最需要收回的那一种。
-- 【作废之后】这一行冻住;它不再挡重叠、不再算"开着的那一段"、交接单不能再引用它;资产页照旧列出它,标着"已作废"与理由。
--   引用过它的交接单不动(那是交接时说过的话)。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.void_equipment_downtime(p_downtime_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d equipment_downtime%ROWTYPE;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_d FROM equipment_downtime WHERE id = p_downtime_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_NOT_FOUND|%', COALESCE(p_downtime_id::text, '?');
    END IF;
    IF v_d.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_ALREADY_VOIDED|%', to_char(v_d.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_VOID_REASON_REQUIRED';
    END IF;
    UPDATE equipment_downtime
       SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason),
           updated_by = auth.uid()
     WHERE id = p_downtime_id;
    RETURN jsonb_build_object('downtime_id', p_downtime_id, 'equipment_id', v_d.equipment_id, 'voided', true);
END;
$function$;

COMMENT ON FUNCTION public.void_equipment_downtime(uuid, text) IS
'U1-B(UNBLOCK-1 Q15):作废一段没有发生过的停机,带理由;module.processing.edit。作废之后那一行冻住、不挡重叠、不算开着、交接单不能再引用;永远不硬删(guard_downtime_write)。';
