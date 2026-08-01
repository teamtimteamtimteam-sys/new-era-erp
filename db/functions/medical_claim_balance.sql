-- db/functions/medical_claim_balance.sql
-- 医疗报销额度:按当年完整服务月数折算,取整到元。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.medical_claim_balance(p_employee_id uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_set    record;
    v_months integer := 12;
    v_limit  numeric;
    v_used   numeric;
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, hire_date INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    SELECT * INTO v_set FROM hr_settings WHERE id;

    IF v_set.medical_pro_rate_for_joiners AND EXTRACT(YEAR FROM v_emp.hire_date)::integer = p_year THEN
        v_months := 12 - (EXTRACT(MONTH FROM v_emp.hire_date)::integer - 1);
    END IF;
    v_limit := round(v_set.medical_annual_limit_sgd * v_months / 12.0, 0);

    SELECT COALESCE(SUM(amount_sgd), 0) INTO v_used
    FROM medical_claims
    WHERE employee_id = p_employee_id AND claim_year = p_year
      AND deleted_at IS NULL AND status IN ('approved','paid');

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'year', p_year,
        'annual_limit_sgd', v_set.medical_annual_limit_sgd,
        'months_of_service', v_months,
        'pro_rated_limit_sgd', v_limit,
        'claimed_sgd', v_used,
        'remaining_sgd', v_limit - v_used);
END;
$function$;
