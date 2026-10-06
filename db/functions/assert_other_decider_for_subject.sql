-- db/functions/assert_other_decider_for_subject.sql
-- U1-B(2026-10-05,ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的报销单那一半):assert_other_decider 带上【主角】的那一版。
--
-- 【为什么要有主角】报销单的四眼不只看提单人,也看【这张单报的是谁】(decide_expense_claim 的
--   forbid_self_approval(created_by, employee_id, …))—— 一张替 tim@ 报的单,tim@ 批不了,哪怕提单的是别人。
--   assert_other_decider 一直传 NULL 当主角(它的十五个调用方都是没有主角的申请),所以问不出这一句。
-- 【一份判据】assert_other_decider 从此只是本函数的 p_subject_employee = NULL 的那一种 —— 两份判据必然漂开。
-- 【判据】审批开着时,approval_deciders(本链、本级、提单人 = auth.uid()、主角 = p_subject_employee)一个人都没有 →
--   RAISE p_refusal。审批关着时不拒。self_approval_exception 的那一条(主角本人持二级、可以批自己的报销)照样算进去,
--   因为 approval_deciders 自己就问它。
-- 【EXECUTE 从 authenticated 收回】与 assert_other_decider 同一条(见 db/views/zzz_function_grants.sql)。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.assert_other_decider_for_subject(p_subject_type text, p_action_function text, p_level smallint, p_subject_employee uuid, p_refusal text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l1 text;
    v_l2 text;
BEGIN
    IF NOT approvals_enabled() THEN
        RETURN;
    END IF;
    SELECT approval_level1_role_code, approval_level2_role_code
      INTO v_l1, v_l2 FROM finance_settings LIMIT 1;
    IF NOT EXISTS (SELECT 1 FROM approval_deciders(p_subject_type, p_action_function, p_level,
                                                   auth.uid(), p_subject_employee, v_l1, v_l2)) THEN
        RAISE EXCEPTION '%', p_refusal;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_other_decider_for_subject(text, text, smallint, uuid, text) IS
'U1-B:assert_other_decider 带主角的那一版 —— 审批开着、approval_deciders(本链、本级、提单人 = auth.uid()、主角 = p_subject_employee)一个人都没有时 RAISE 调用方给的那一句(报销单 EXPENSE_CLAIM_NO_OTHER_DECIDER|单号)。assert_other_decider 是它主角为 NULL 的那一种。EXECUTE 已从 authenticated 收回。';
