-- db/functions/decide_medical_claim.sql
-- 审批报销。超出剩余额度则拒绝。【不自动记费用】。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.decide_medical_claim(p_claim_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_claim record; v_bal jsonb; v_remaining numeric;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
    IF v_claim.status <> 'submitted' THEN RAISE EXCEPTION 'CLAIM_NOT_SUBMITTED|%', v_claim.status; END IF;

    IF NOT p_approve THEN
        UPDATE medical_claims SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','rejected');
    END IF;

    v_bal := medical_claim_balance(v_claim.employee_id, v_claim.claim_year);
    v_remaining := (v_bal->>'remaining_sgd')::numeric;
    IF v_claim.amount_sgd > v_remaining THEN
        RAISE EXCEPTION 'CLAIM_EXCEEDS_LIMIT|%|%', v_remaining, v_claim.amount_sgd;
    END IF;

    UPDATE medical_claims SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','approved',
                              'amount_sgd', v_claim.amount_sgd,
                              'remaining_after', v_remaining - v_claim.amount_sgd,
                              -- 与补偿一样,把"没有入账"写进返回值,免得调用方以为记过账了
                              'expense_posted', false,
                              'note', 'No expense is posted. Reimbursement route (payroll vs separate payment) is an operational decision; link it via medical_claims.expense_id once chosen.');
END;
$function$;
