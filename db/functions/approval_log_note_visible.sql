-- db/functions/approval_log_note_visible.sql
-- U1-B(2026-10-05,U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE 的裁定,Tim):approval_log 一行上的【说明】(note)对当前读者看不看得见。
--   Tim 的规矩:医疗报销生成的那张费用单,金额给财务(付它是正当的需要);任何【健康的字】—— 事由、诊断、理由 —— 跟 data.view_health 走。
--   一张医疗报销的批准 / 驳回说明是 HR 写下的那一段理由(为什么报、为什么不报),它与 medical_claims.decision_notes 是同一段字的两份;
--   那一份已经收到 data.view_health(或本人),这一份不跟着收,同一段字就从审批留痕那扇门出去了。
-- 【判据,一支对一个单据种类】medical_claim → data.view_health,或那一张报销单就是读者本人的(与 medical_claims_masked 逐字同一个);
--   其余种类 → true(本刀不动它们;请假单的说明是同一个形状,登记为 U1B-LEAVE-DECISION-NOTE-HEALTH-TEXT)。
-- 【三个读者,一份判据】approval_log_masked 的 CASE · change_log_rule_visible 的 apr_note · self_approved_decisions。
-- 【不是 SECURITY DEFINER】与 approval_log_amount_visible 同一条理由。
CREATE OR REPLACE FUNCTION public.approval_log_note_visible(p_subject_type text, p_subject_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_subject_type
        WHEN 'medical_claim' THEN has_permission('data.view_health'::text)
                                  OR EXISTS (SELECT 1 FROM medical_claims mc
                                              WHERE mc.id = p_subject_id AND mc.employee_id = current_user_employee())
        ELSE true
    END;
$function$
