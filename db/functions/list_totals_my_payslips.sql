-- db/functions/list_totals_my_payslips.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/me 工资单那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/me/page.tsx:146-149 同一套:payroll_lines_masked,employee_id = 本人(没有状态 / 删除筛选 —— 页面也没有;
--   币种取自那一期,与页面经 my_period_labels() 配币种同一个来源,那支也不看 deleted_at)。
-- 【合计】gross(gross_pay)、employer_cpf、employee_cpf、deductions(other_deductions)、net(net_pay),每个期间币种一行。
-- 【净额】工资单行没有冲销镜像行(UNIQUE 期间 + 员工,payroll_lines.sql:33)—— 照加。
-- 【为什么是 DEFINER】币种住在 payroll_periods 上,它的读策略只有 module.hr.view(与 my_period_labels.sql 抬头同一个理由)。
--   DEFINER 只用来越过那张表的读策略:主语就是调用者 —— 没有参数,current_user_employee() 为 NULL(anon、没有员工档案)
--   → 按名拒;只读 employee_id = 调用者 的行。金额仍从 payroll_lines_masked 读(其 CASE 按调用者的会话求值),不读基表。
-- 【门】没有模块码:/me 不挂模块守卫;调用者检查就是上面那条员工判据。
-- 【受限】本人的行从不遮,但照实算:bool_or(<列> IS NULL) —— 五列基表都 NOT NULL(payroll_lines.sql:26-30),NULL 只可能是遮。
CREATE OR REPLACE FUNCTION public.list_totals_my_payslips()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid;
BEGIN
    v_emp := current_user_employee();
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'LIST_TOTALS_NO_EMPLOYEE'
          USING HINT = '这份合计只算调用者自己的行,而这个登录账号没有对应的员工档案。';
    END IF;
    RETURN QUERY
    WITH s AS (
        SELECT pp.currency::text AS ccy,
               sum(l.gross_pay) AS gross, bool_or(l.gross_pay IS NULL) AS gross_h,
               sum(l.employer_cpf) AS er, bool_or(l.employer_cpf IS NULL) AS er_h,
               sum(l.employee_cpf) AS ee, bool_or(l.employee_cpf IS NULL) AS ee_h,
               sum(l.other_deductions) AS ded, bool_or(l.other_deductions IS NULL) AS ded_h,
               sum(l.net_pay) AS net, bool_or(l.net_pay IS NULL) AS net_h
          FROM payroll_lines_masked l
          JOIN payroll_periods pp ON pp.id = l.payroll_period_id
         WHERE l.employee_id = v_emp
         GROUP BY pp.currency
    )
    SELECT ''::text, s.ccy, m.k, CASE WHEN m.h THEN NULL::numeric ELSE round(m.v, 2) END, m.h
      FROM s CROSS JOIN LATERAL (VALUES
               ('gross'::text, s.gross, s.gross_h),
               ('employer_cpf'::text, s.er, s.er_h),
               ('employee_cpf'::text, s.ee, s.ee_h),
               ('deductions'::text, s.ded, s.ded_h),
               ('net'::text, s.net, s.net_h)) m(k, v, h)
     ORDER BY 2;
END;
$function$;