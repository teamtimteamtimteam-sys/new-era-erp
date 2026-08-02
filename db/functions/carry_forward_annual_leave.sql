-- db/functions/carry_forward_annual_leave.sql
-- 年末结转。【读派生的当年累积】,不再读授予行(HR-2c D3)。
-- 只结转当年挣到、没用掉的部分;上一年结转来的、今年仍没用掉的就地作废 ——
-- 用进废退只适用于上一年的结转,不适用于当年挣到的天数(D4)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.carry_forward_annual_leave(p_leave_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp     record;
    v_year_end date := make_date(p_leave_year, 12, 31);
    v_accrued numeric;
    v_used    numeric;
    v_balance numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_count   integer := 0;
    v_total   numeric := 0;
BEGIN
    PERFORM require_permission('module.hr.edit');

    FOR v_emp IN
        SELECT e.id, e.code FROM employees e
        WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'
        ORDER BY e.code
    LOOP
        IF EXISTS (SELECT 1 FROM leave_grants g
                   WHERE g.employee_id = v_emp.id AND g.leave_type_code = 'annual'
                     AND g.grant_type = 'carry_forward' AND g.leave_year = p_leave_year + 1
                     AND g.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'CARRY_FORWARD_EXISTS|%|%', v_emp.code, p_leave_year;
        END IF;

        v_accrued := accrued_annual_leave(v_emp.id, v_year_end);
        v_used    := consumed_from_accrual(v_emp.id, p_leave_year);
        v_balance := v_accrued - v_used;

        IF v_balance IS NULL OR v_balance <= 0 THEN CONTINUE; END IF;

        INSERT INTO leave_grants (employee_id, leave_type_code, leave_year, days, granted_on,
                                  expires_on, grant_type, source_grant_id, notes)
        VALUES (v_emp.id, 'annual', p_leave_year + 1, v_balance,
                make_date(p_leave_year + 1, 1, 1),
                make_date(p_leave_year + 1, 12, 31),
                'carry_forward',
                -- 【没有来源授予行了】当年度是派生的,所以 source_grant_id 为空。
                -- leave_balance 的 carried_out 扣减因此对它无事可做,也就无从重复计数。
                NULL,
                format('Carried forward from %s monthly accrual (%s accrued, %s taken)',
                       p_leave_year, trim_scale(v_accrued), trim_scale(v_used)));

        v_count := v_count + 1;
        v_total := v_total + v_balance;
        v_rows := v_rows || jsonb_build_object('employee_code', v_emp.code, 'days', v_balance,
                                               'accrued', v_accrued, 'taken', v_used);
    END LOOP;

    RETURN jsonb_build_object('from_year', p_leave_year, 'into_year', p_leave_year + 1,
                              'employees', v_count, 'total_days', v_total,
                              'source', 'derived monthly accrual', 'detail', v_rows);
END;
$function$
;