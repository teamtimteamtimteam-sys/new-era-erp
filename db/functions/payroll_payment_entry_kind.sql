-- db/functions/payroll_payment_entry_kind.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q7):一张分录是不是一次工资【付款】,是哪一种 —— 读【已付的戳】:
--   'salary'     —— 有工资行的 paid_journal_entry_id 指着它(pay_payroll_lines 一次调用 = 一张分录,一人一条银行行);
--   'cpf'        —— 某一期的 cpf_journal_entry_id 指着它(pay_payroll_cpf);
--   'deductions' —— 某一期的 deductions_journal_entry_id 指着它(pay_payroll_deductions);
--   NULL         —— 都不是(工资期的过账分录、已经被冲掉而戳已清掉的付款、别的什么分录)。
-- 一支判据,三个读它的人:工资付款冲销的引擎(认种类、决定清哪一组戳)、journal_entry_reversal_route(通用口按名拒)、
-- payroll_payment_entries(付薪页上每一次付款画一行)。
-- 【INVOKER,不问码】只在 DEFINER 函数里被调;authenticated 收回了 EXECUTE。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.payroll_payment_entry_kind(p_entry_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
               WHEN p_entry_id IS NULL THEN NULL
               WHEN EXISTS (SELECT 1 FROM payroll_lines pl WHERE pl.paid_journal_entry_id = p_entry_id) THEN 'salary'
               WHEN EXISTS (SELECT 1 FROM payroll_periods pp WHERE pp.cpf_journal_entry_id = p_entry_id) THEN 'cpf'
               WHEN EXISTS (SELECT 1 FROM payroll_periods pp WHERE pp.deductions_journal_entry_id = p_entry_id) THEN 'deductions'
           END
$function$;
