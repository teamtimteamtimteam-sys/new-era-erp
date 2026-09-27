-- db/functions/withdraw_medical_claim.sql
-- EMP-SELF-1(G3b,Tim 2026-09-27):员工撤回自己【还没被决定】的医疗申报。
-- 形状照 withdraw_expense_claim:本人,或者持本链的编辑码(医疗是 module.hr.edit,Tim 的 Q8);只撤 submitted。
-- 已批 / 已拒 / 已付的一律按名拒 —— 撤回不碰任何已经决定了的东西。
-- 【不写 decided_*】撤回不是一次决定;状态与 withdrawn_at 说清楚发生了什么(与报销单同一条表约束)。
-- 【生下来就是 COALESCE】没有员工档案的账号 current_user_employee() 是 NULL,裸的 NOT (… OR …) 会放它过去(EMP-SELF-1 Q2)。
--
-- NOTE: introduced by db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql.

CREATE OR REPLACE FUNCTION public.withdraw_medical_claim(p_claim_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_c record;
BEGIN
    SELECT * INTO v_c FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MEDICAL_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF NOT COALESCE(has_permission('module.hr.edit') OR v_c.employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'MEDICAL_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;

    UPDATE medical_claims
       SET status = 'withdrawn', withdrawn_at = now(), updated_by = auth.uid()
     WHERE id = p_claim_id;
    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'withdrawn');
END;
$function$;
