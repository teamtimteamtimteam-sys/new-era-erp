-- db/functions/delete_overtime_line.sql
-- OVERTIME-1(2026-09-28):从一张还能改的批(draft / rejected)上删一行。改一行 = 删掉再加。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.delete_overtime_line(p_line_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l  overtime_lines%ROWTYPE;
    v_b  overtime_batches%ROWTYPE;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_l FROM overtime_lines WHERE id = p_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    SELECT * INTO v_b FROM overtime_batches WHERE id = v_l.batch_id FOR UPDATE;
    IF v_b.status NOT IN ('draft', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_EDITABLE|%|%', v_b.label, v_b.status;
    END IF;
    PERFORM overtime_assert_month_open(v_b.period_month);

    DELETE FROM overtime_lines WHERE id = p_line_id;
    RETURN jsonb_build_object('line_id', p_line_id, 'batch_id', v_b.id);
END;
$function$;

COMMENT ON FUNCTION public.delete_overtime_line(uuid) IS
'OVERTIME-1:从 draft / rejected 的加班批上删一行(action.overtime_enter)。拒:OVERTIME_LINE_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE · OVERTIME_MONTH_COMPLETE。';
