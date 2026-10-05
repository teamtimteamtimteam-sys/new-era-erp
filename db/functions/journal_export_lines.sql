-- db/functions/journal_export_lines.sql
-- U1-A(Tim 的 UNBLOCK-1 Q1 · Q2,2026-10-05):总账导出(/finance/journal/export)的取数 —— journal_activity_lines 的同一组行,
--   工资分录那几行的三个金额对不持 data.view_pay 的人是 NULL,并带 amounts_restricted = true(CSV 印 "Restricted",不印 0)。
-- 【为什么不再直接调 journal_activity_lines】它是 invoker(为了可内联,三张报表在属主身份里读它);被一个登录用户直接调时,
--   journal_lines 上那条 restrictive 策略会让工资分录的行【悄悄缺席】—— 一份少了几行、而抬头的行数照样对得上的导出。
--   这里以属主身份读同一段推导(一行算术都不重写),只在出口处遮金额:行在、科目在、行摘要在,金额受限。
-- 【判据】与 journal_lines_masked 的 CASE、与 change_log_mask_rules 的 pay_journal 规则逐字同一个:
--   持 data.view_pay,或这一行所在分录的 source_type 不是 'payroll'。
-- 【门】module.finance.view,按名拒(与 journal_lines 的 permissive 读策略同一个码)。
CREATE OR REPLACE FUNCTION public.journal_export_lines(p_from date, p_to date, p_include_year_close boolean)
 RETURNS TABLE(entry_id uuid, entry_code text, entry_date date, entry_memo text, source_type text, source_id uuid, entry_status text, line_id uuid, line_memo text, account_id uuid, account_code text, account_name_en text, account_name_zh text, account_type text, debit numeric, credit numeric, signed_base numeric, amounts_restricted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pay boolean;
BEGIN
    PERFORM require_permission('module.finance.view');
    v_pay := has_permission('data.view_pay');
    RETURN QUERY
    SELECT a.entry_id, a.entry_code, a.entry_date, a.entry_memo, a.source_type, a.source_id, a.entry_status,
           a.line_id, a.line_memo, a.account_id, a.account_code, a.account_name_en, a.account_name_zh, a.account_type,
           CASE WHEN v_pay OR a.source_type IS DISTINCT FROM 'payroll' THEN a.debit END,
           CASE WHEN v_pay OR a.source_type IS DISTINCT FROM 'payroll' THEN a.credit END,
           CASE WHEN v_pay OR a.source_type IS DISTINCT FROM 'payroll' THEN a.signed_base END,
           NOT (v_pay OR a.source_type IS DISTINCT FROM 'payroll')
      FROM journal_activity_lines(p_from, p_to, p_include_year_close) a;
END;
$function$
