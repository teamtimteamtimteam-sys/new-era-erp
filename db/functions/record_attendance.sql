CREATE OR REPLACE FUNCTION public.record_attendance(p_line_id uuid, p_normal numeric DEFAULT 0, p_rest_day numeric DEFAULT 0, p_holiday numeric DEFAULT 0, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_l attendance_lines%ROWTYPE; v_p attendance_periods%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_l FROM attendance_lines WHERE id = p_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    SELECT * INTO v_p FROM attendance_periods WHERE id = v_l.period_id;
    IF v_p.status <> 'open' THEN
        -- 完成之后不许再改:那份底稿【就是】我们报出去的东西
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    IF COALESCE(p_normal,0) < 0 OR COALESCE(p_rest_day,0) < 0 OR COALESCE(p_holiday,0) < 0 THEN
        RAISE EXCEPTION 'ATTENDANCE_HOURS_INVALID|%|%|%',
            COALESCE(p_normal,0)::text, COALESCE(p_rest_day,0)::text, COALESCE(p_holiday,0)::text;
    END IF;

    UPDATE attendance_lines
       SET ot_normal_hours = COALESCE(p_normal, 0),
           ot_rest_day_hours = COALESCE(p_rest_day, 0),
           ot_public_holiday_hours = COALESCE(p_holiday, 0),
           note = NULLIF(btrim(COALESCE(p_note, '')), ''),
           recorded_at = now(), recorded_by = auth.uid()
     WHERE id = p_line_id;

    RETURN jsonb_build_object('line_id', p_line_id, 'recorded', true);
END;
$function$

;
