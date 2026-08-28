CREATE OR REPLACE FUNCTION public.sync_attendance_period(p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_added int; v_end date;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'open' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    v_end := (v_p.period_month + interval '1 month - 1 day')::date;

    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_p.id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= v_end
       AND (e.separation_date IS NULL OR e.separation_date >= v_p.period_month)
       AND NOT EXISTS (SELECT 1 FROM attendance_lines al
                        WHERE al.period_id = v_p.id AND al.employee_id = e.id);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code, 'lines_added', v_added);
END;
$function$

;
