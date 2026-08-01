-- db/functions/carry_forward_annual_leave.sql
-- 年末结转。把上一年未用完的余额【搬】进下一年的新授予,source_grant_id 指回来源。幂等。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.carry_forward_annual_leave(p_leave_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp     record;
    v_balance numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_count   integer := 0;
    v_total   numeric := 0;
    v_src     uuid;
BEGIN
    PERFORM require_permission('module.hr.edit');

    FOR v_emp IN
        SELECT e.id, e.code FROM employees e
        WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'
        ORDER BY e.code
    LOOP
        -- 幂等:同一员工同一年只结转一次
        IF EXISTS (SELECT 1 FROM leave_grants g
                   WHERE g.employee_id = v_emp.id AND g.leave_type_code = 'annual'
                     AND g.grant_type = 'carry_forward' AND g.leave_year = p_leave_year + 1
                     AND g.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'CARRY_FORWARD_EXISTS|%|%', v_emp.code, p_leave_year;
        END IF;

        -- 该年度授予里没被消耗掉的部分
        SELECT COALESCE(SUM(g.days), 0)
               - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                           JOIN leave_grants src ON src.id = cf.source_grant_id
                           WHERE src.employee_id = v_emp.id AND src.leave_type_code = 'annual'
                             AND src.leave_year = p_leave_year AND cf.grant_type = 'carry_forward'
                             AND cf.deleted_at IS NULL), 0)
               - COALESCE((
                   SELECT SUM(CASE WHEN c.entry_type = 'draw' THEN c.days ELSE -c.days END)
                   FROM leave_consumption c
                   WHERE c.leave_grant_id IN (
                       SELECT g2.id FROM leave_grants g2
                       WHERE g2.employee_id = v_emp.id AND g2.leave_type_code = 'annual'
                         AND g2.leave_year = p_leave_year AND g2.deleted_at IS NULL)), 0)
        INTO v_balance
        FROM leave_grants g
        WHERE g.employee_id = v_emp.id AND g.leave_type_code = 'annual'
          AND g.leave_year = p_leave_year AND g.deleted_at IS NULL;

        IF v_balance IS NULL OR v_balance <= 0 THEN CONTINUE; END IF;

        SELECT id INTO v_src FROM leave_grants
        WHERE employee_id = v_emp.id AND leave_type_code = 'annual'
          AND leave_year = p_leave_year AND deleted_at IS NULL
        ORDER BY granted_on LIMIT 1;

        INSERT INTO leave_grants (employee_id, leave_type_code, leave_year, days, granted_on,
                                  -- 结转进 next year,并在【那一年的年底】失效 —— 即原年度之后 12 个月
                                  expires_on, grant_type, source_grant_id, notes)
        VALUES (v_emp.id, 'annual', p_leave_year + 1, v_balance,
                make_date(p_leave_year + 1, 1, 1),
                make_date(p_leave_year + 1, 12, 31),
                'carry_forward', v_src,
                format('Carried forward from %s', p_leave_year));

        v_count := v_count + 1;
        v_total := v_total + v_balance;
        v_rows := v_rows || jsonb_build_object('employee_code', v_emp.code, 'days', v_balance);
    END LOOP;

    RETURN jsonb_build_object('from_year', p_leave_year, 'into_year', p_leave_year + 1,
                              'employees', v_count, 'total_days', v_total, 'detail', v_rows);
END;
$function$;
