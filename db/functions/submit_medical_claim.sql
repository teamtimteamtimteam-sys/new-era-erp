-- db/functions/submit_medical_claim.sql
-- 提交报销。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.submit_medical_claim(p_employee_id uuid, p_claim_date date, p_amount_sgd numeric, p_description text DEFAULT NULL::text, p_receipt_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_emp record; v_code text; v_claim record; v_year integer;
BEGIN
    IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    SELECT id, code INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF p_amount_sgd IS NULL OR p_amount_sgd <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;

    v_year := EXTRACT(YEAR FROM p_claim_date)::integer;
    v_code := next_medical_claim_code(p_claim_date);
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd,
                                description, receipt_ref)
    VALUES (v_code, p_employee_id, p_claim_date, v_year, p_amount_sgd, p_description, p_receipt_ref)
    RETURNING * INTO v_claim;

    RETURN jsonb_build_object('claim_id', v_claim.id, 'code', v_claim.code,
                              'employee_code', v_emp.code, 'amount_sgd', p_amount_sgd,
                              'claim_year', v_year, 'status', v_claim.status);
END;
$function$;
