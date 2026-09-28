-- db/functions/discard_overtime_batch.sql
-- OVERTIME-1(2026-09-28,本刀的构建决定,交回里点名):一张不要了的批(draft / rejected)→ discarded,
-- 它的行全部作废。
-- 【为什么需要它】Tim Q8:那个月还有 draft 或 submitted(以及被驳回、等着改的)批时,考勤不许完成。
--   没有这一步,一张没人要的草稿会【永远】挡住那个月的考勤完成,进而挡住工资过账。
-- 【不删行】批次与行都留着(已作废),日期随之腾出来;approval_log 里那一批以前的提交 / 驳回照样指得到它。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.discard_overtime_batch(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b  overtime_batches%ROWTYPE;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status NOT IN ('draft', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_EDITABLE|%|%', v_b.label, v_b.status;
    END IF;

    UPDATE overtime_lines SET voided_at = now() WHERE batch_id = p_batch_id AND voided_at IS NULL;
    UPDATE overtime_batches
       SET status = 'discarded', discarded_at = now(), discarded_by = auth.uid(),
           decided_at = NULL, decided_by = NULL
     WHERE id = p_batch_id;
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'discarded');
END;
$function$;

COMMENT ON FUNCTION public.discard_overtime_batch(uuid) IS
'OVERTIME-1:丢弃一张 draft / rejected 的加班批(action.overtime_enter),它的行全部作废。存在的理由:开着的批挡住那个月的考勤完成,一张没人要的草稿不能永远挡着。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE。';
