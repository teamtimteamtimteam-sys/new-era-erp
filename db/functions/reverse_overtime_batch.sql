-- db/functions/reverse_overtime_batch.sql
-- OVERTIME-1(Tim Q10):一张批过的批错了 → 财务整批冲销(要理由),那一批的行全部作废、日期腾出来,
-- 然后录一张改对的批,重新走一遍审批。没有逐行改。
-- 【只在那个月考勤还开着时】完成之后按名拒 OVERTIME_MONTH_COMPLETE —— 那些小时已经冻进底稿了。
-- 【不写 approval_log】冲销不是一次审批决定;它记在批次行上(reversed_at / reversed_by / reverse_reason)。
--   批准那一行留痕原样留着 —— 它说的是当时真实发生过的事。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.reverse_overtime_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b  overtime_batches%ROWTYPE;
    v_n  integer;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status <> 'approved' THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_APPROVED|%|%', v_b.label, v_b.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'OVERTIME_REVERSE_REASON_REQUIRED|%', v_b.label;
    END IF;
    PERFORM overtime_assert_month_open(v_b.period_month);

    UPDATE overtime_lines SET voided_at = now() WHERE batch_id = p_batch_id AND voided_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    UPDATE overtime_batches
       SET status = 'reversed', reversed_at = now(), reversed_by = auth.uid(), reverse_reason = btrim(p_reason)
     WHERE id = p_batch_id;
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'reversed', 'lines_voided', v_n);
END;
$function$;

COMMENT ON FUNCTION public.reverse_overtime_batch(uuid, text) IS
'OVERTIME-1(Tim Q10):整批冲销一张 approved 的加班批(action.overtime_enter,要理由),它的行全部作废、日期腾出来。只在那个月考勤还开着时。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_APPROVED · OVERTIME_REVERSE_REASON_REQUIRED · OVERTIME_MONTH_COMPLETE。不写 approval_log。';
