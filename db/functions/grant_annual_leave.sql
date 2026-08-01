-- db/functions/grant_annual_leave.sql
-- 年度年假授予。年中入职按完整服务月数折算,【四舍五入到 0.5 天】(0.5 是消耗的最小单位)。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.grant_annual_leave(p_employee_id uuid, p_leave_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_months integer;
    v_days   numeric;
    v_type   text := 'annual';
    v_grant  record;
    v_start  date := make_date(p_leave_year, 1, 1);
    v_end    date := make_date(p_leave_year, 12, 31);
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT id, code, hire_date, annual_leave_days, employment_status
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    IF EXISTS (SELECT 1 FROM leave_grants g
               WHERE g.employee_id = p_employee_id AND g.leave_type_code = v_type
                 AND g.leave_year = p_leave_year AND g.grant_type IN ('entitlement','pro_rata')
                 AND g.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'GRANT_EXISTS|%', p_leave_year;
    END IF;

    IF v_emp.hire_date > v_end THEN
        RAISE EXCEPTION 'HIRED_AFTER_YEAR|%', p_leave_year;
    END IF;

    -- 年中入职:按【完整服务月数 ÷ 12】折算。入职当月计为完整的一个月。
    IF v_emp.hire_date > v_start THEN
        v_months := 12 - (EXTRACT(MONTH FROM v_emp.hire_date)::integer - 1);
        v_days := round((v_emp.annual_leave_days::numeric * v_months / 12.0) * 2) / 2;
    ELSE
        v_months := 12;
        v_days := v_emp.annual_leave_days::numeric;
    END IF;

    IF v_days <= 0 THEN RAISE EXCEPTION 'NO_ENTITLEMENT|%', p_leave_year; END IF;

    INSERT INTO leave_grants (employee_id, leave_type_code, leave_year, days, granted_on,
                              -- 【当年度授予到次年年底失效】= 结转 12 个月的规则
                              expires_on, grant_type, notes)
    VALUES (p_employee_id, v_type, p_leave_year, v_days, GREATEST(v_start, v_emp.hire_date),
            make_date(p_leave_year + 1, 12, 31),
            CASE WHEN v_months = 12 THEN 'entitlement' ELSE 'pro_rata' END,
            CASE WHEN v_months = 12 THEN NULL
                 ELSE format('Pro-rated: %s of 12 months from hire date %s', v_months, v_emp.hire_date) END)
    RETURNING * INTO v_grant;

    RETURN jsonb_build_object(
        'grant_id', v_grant.id, 'employee_code', v_emp.code, 'leave_year', p_leave_year,
        'months_of_service', v_months, 'entitlement_days', v_emp.annual_leave_days,
        'granted_days', v_days, 'expires_on', v_grant.expires_on,
        'grant_type', v_grant.grant_type);
END;
$function$;
