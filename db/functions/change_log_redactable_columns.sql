-- db/functions/change_log_redactable_columns.sql
-- HISTORY-1:匿名化时 change_log 里【允许被涂成 null】的列 —— 按源表。
-- 名单与 anonymise_employee 清掉的列【逐字同一份】(外加 greeting_name,Tim 的 Q9);
-- 两边任何一边加列,另一边要在同一个提交里跟上 —— fixture 234 的涂抹那一臂钉着这份对应。
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
        ELSE ARRAY[]::text[]
    END;
$function$;
