-- db/functions/withdraw_overtime_batch.sql
-- OVERTIME-1(Tim Q10):财务撤回一张还在等仓库批的批 —— 它回到 draft,可以改、再提。
-- 【不写 approval_log】撤回不是一次决定(与 salary_change / journal 申请的撤回同形)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.withdraw_overtime_batch(p_batch_id uuid)
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
    IF v_b.status <> 'submitted' THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_SUBMITTED|%|%', v_b.label, v_b.status;
    END IF;

    UPDATE overtime_batches
       SET status = 'draft', submitted_at = NULL, submitted_by = NULL
     WHERE id = p_batch_id;
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'draft');
END;
$function$;

COMMENT ON FUNCTION public.withdraw_overtime_batch(uuid) IS
'OVERTIME-1(Tim Q10):撤回一张 submitted 的加班批(action.overtime_enter),它回到 draft。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_SUBMITTED。不写 approval_log。';
