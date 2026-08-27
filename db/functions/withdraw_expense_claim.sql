CREATE OR REPLACE FUNCTION public.withdraw_expense_claim(p_claim_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_c expense_claims%ROWTYPE;
BEGIN
    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF NOT (has_permission('module.finance.edit') OR v_c.employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;

    UPDATE expense_claims
       SET status = 'withdrawn', withdrawn_at = now()
     WHERE id = p_claim_id;
    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'withdrawn');
END;
$function$

;
