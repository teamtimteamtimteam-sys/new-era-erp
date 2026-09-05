-- db/views/payroll_period_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.payroll_period_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    period_month,
    payment_date,
    currency,
    status,
    cpf_paid_at,
    deductions_paid_at,
    deleted_at,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN gross_total
            ELSE NULL::numeric
        END AS gross_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN net_pay_total
            ELSE NULL::numeric
        END AS net_pay_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employer_cpf_total
            ELSE NULL::numeric
        END AS employer_cpf_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employee_cpf_total
            ELSE NULL::numeric
        END AS employee_cpf_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN other_deductions_total
            ELSE NULL::numeric
        END AS other_deductions_total
   FROM payroll_periods p
  WHERE has_permission('module.hr.view'::text) OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.payroll_period_lookup IS
    'FIX-2a:薪资期间的【查名】视图 —— 编号 / 期间 / 付款日 / 状态 / 已缴时点。五个合计在列上但【仍按 data.view_pay 遮】,与 employees_masked 同一条列谓词。★ finance 与 cfo 本来就持有 data.view_pay,挡住他们的只是 module.hr.view 这道【行】门 —— 所以本视图一分钱都没有多给,它只是不再对一个要去付薪的人说"这个月没有薪资期间"。行谓词 hr.view OR finance.view。没有 source_note / notes / journal_entry_id。';

GRANT SELECT ON public.payroll_period_lookup TO authenticated;
