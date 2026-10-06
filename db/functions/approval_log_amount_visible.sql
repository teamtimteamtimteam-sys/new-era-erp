-- db/functions/approval_log_amount_visible.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):approval_log 一行上的【金额】(amount_ccy · amount_base)对当前读者看不看得见。
--   record_approval_decision 把单据的金额抄进留痕:工资申请那一行是这一期的合计(一期一个人时就是一个人的工资,Q9 · Q10),
--   医疗报销那一行是报销的金额(Q8)。单据那一侧这两样已经被遮(payroll_requests_masked · medical_claims_masked),
--   留痕这一侧不跟着遮,同一个数就从另一扇门出去了。
-- 【判据,一支对一个单据种类,与那张单据自己的遮蔽逐字同一个】
--   payroll_request → data.view_pay(payroll_requests_masked 的 gross_total / amount_base)
--   medical_claim   → data.view_health,或那一张报销单就是读者本人的(medical_claims_masked 的 amount_sgd)
--   journal_request → journal_request_amount_visible(U1-B:工资分录的冲销申请要 data.view_pay;journal_requests_masked 的 amount_base)
--   其余种类         → true(本刀不动它们;仓库申请那一支由 approval_log_readable 只给财务,AT1B-WAREHOUSE-APPROVALS-FINANCE-ONLY)
-- 【两个读者,一份判据】approval_log_masked 的 CASE 与 change_log_rule_visible 的 apr_amount 规则都调这一支。
-- 【不是 SECURITY DEFINER】"本人的报销单"那一问读 medical_claims.employee_id(列授权里有),
--   在属主视图与 DEFINER 读法里以各自的身份跑;RLS 求不到那一行的读者本来就读不到那一行留痕。
CREATE OR REPLACE FUNCTION public.approval_log_amount_visible(p_subject_type text, p_subject_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_subject_type
        WHEN 'payroll_request' THEN has_permission('data.view_pay'::text)
        WHEN 'medical_claim'   THEN has_permission('data.view_health'::text)
                                    OR EXISTS (SELECT 1 FROM medical_claims mc
                                                WHERE mc.id = p_subject_id AND mc.employee_id = current_user_employee())
        -- U1-B:一张工资分录的冲销申请,金额就是那张分录的合计 —— 与申请自己的遮蔽同一支判据。
        WHEN 'journal_request' THEN journal_request_amount_visible(p_subject_id)
        ELSE true
    END;
$function$
