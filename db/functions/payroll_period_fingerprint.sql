-- db/functions/payroll_period_fingerprint.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q4):一个工资期【此刻】的那一组数 —— 审批人批的就是它。
--
-- 五个合计、行数、逐行摘要(每人一行:员工 · gross · 雇主 CPF · 员工 CPF · 其它扣款 · 净额)、
-- 发薪日、币种、汇率。submit_payroll_request 把它存进 payroll_requests.snapshot;
-- decide_payroll_request 与两支执行函数各再算一次,不相等就按名拒
-- (PAYROLL_CHANGED_SINCE_REQUEST)。
--
-- 【为什么要逐行摘要,不只比合计】两个人的数对调,合计一个都不变 —— 而批的是【谁拿多少】。
-- 【为什么数字按原样变成文本】5000 与 5000.00 是同一个钱、不同的字;重存一次换了写法也会
-- 读成"变了"。那是安全的方向:它只会多拒,不会漏放(而申请开着时保存本来就被拒)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回(db/views/zzz_function_grants.sql)。
-- 期间不存在 → NULL;调用方先查过期间,所以这个 NULL 不会被读成"没变"。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.payroll_period_fingerprint(p_period_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'payment_date', p.payment_date,
               'currency', p.currency,
               'fx_rate', p.fx_rate::text,
               'gross_total', p.gross_total::text,
               'employer_cpf_total', p.employer_cpf_total::text,
               'employee_cpf_total', p.employee_cpf_total::text,
               'other_deductions_total', p.other_deductions_total::text,
               'net_pay_total', p.net_pay_total::text,
               'line_count', (SELECT count(*) FROM payroll_lines l WHERE l.payroll_period_id = p.id),
               'lines_digest', (SELECT md5(COALESCE(string_agg(
                                    l.employee_id::text || ':' || l.gross_pay::text || ':' || l.employer_cpf::text
                                    || ':' || l.employee_cpf::text || ':' || l.other_deductions::text
                                    || ':' || l.net_pay::text, ',' ORDER BY l.employee_id), ''))
                                  FROM payroll_lines l WHERE l.payroll_period_id = p.id))
      FROM payroll_periods p
     WHERE p.id = p_period_id
$function$
;
