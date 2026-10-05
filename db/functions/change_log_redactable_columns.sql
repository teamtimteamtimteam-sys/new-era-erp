-- db/functions/change_log_redactable_columns.sql
-- HISTORY-1:匿名化时 change_log 里【允许被涂成 null】的列 —— 按源表。
-- 名单与 anonymise_employee 清掉的列【逐字同一份】(外加 greeting_name,Tim 的 Q9);
-- 两边任何一边加列,另一边要在同一个提交里跟上 —— fixture 234 的涂抹那一臂钉着这份对应。
-- ★ U1-A(Tim 的 UNBLOCK-1 Q11,2026-10-05):加四张表 —— 调薪申请、工资行、请假单、医疗报销上【人写的字】。
--   金额不在名单里(擦文字,留金额:金额是有法定保存期的账,而人一匿名化,它们就只属于"一位前员工")。
--   anonymise_employee 在基表上擦的正是这几列(不许为空的那几列写成 'ANONYMISED',记录里一律涂成 null);fixture 247 的 AN 臂钉着这份对应。
CREATE OR REPLACE FUNCTION public.change_log_redactable_columns(p_table text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_table
        WHEN 'employees' THEN ARRAY[
            'legal_name', 'preferred_name', 'first_name', 'last_name', 'greeting_name',
            'identity_no', 'work_email', 'work_phone', 'work_pass_no', 'work_pass_type',
            'work_pass_issue_date', 'work_pass_expiry_date', 'residency_status',
            'monthly_salary', 'notes', 'separation_notes', 'position_id', 'user_id']
        WHEN 'employment_history' THEN ARRAY['old_monthly_salary', 'new_monthly_salary', 'notes']
        -- U1-A(UNBLOCK-1 Q11):四张表上【人写的字】—— 理由、说明、备注、单号;金额一个都不在名单里(Q11:擦文字,留金额)
        WHEN 'salary_change_requests' THEN ARRAY['reason', 'decision_notes', 'withdraw_reason']
        WHEN 'payroll_lines' THEN ARRAY['notes']
        WHEN 'leave_requests' THEN ARRAY['reason', 'certificate_ref', 'decision_notes', 'exception_reason']
        WHEN 'medical_claims' THEN ARRAY['description', 'receipt_ref', 'decision_notes']
        ELSE ARRAY[]::text[]
    END;
$function$;
