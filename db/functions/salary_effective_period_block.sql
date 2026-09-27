-- db/functions/salary_effective_period_block.sql
-- APR-9(2026-09-27,grilling Q5):一个调薪生效日【落不落得下】—— 一份判据,调薪申请的提交与批准各问一次。
--   落在一个已过账的工资期里        → 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|<期>'(与 approve_review / set_initial_salary
--                                      同一句话:总账已经认了那个月的工资)
--   落在一个挂着在途工资申请的期里  → 'SALARY_EFFECTIVE_IN_REQUESTED_PERIOD|<期>|<申请>'(那一期正等 CFO 批过账或撤销,
--                                      它批的那一组数字不该在等待中被一次调薪说成过时的)
--   都不是                          → NULL
-- 工资期没有起止两列:周期就是 period_month 那个整月(approve_review 抬头 (4))。"在途" = submitted 或 approved
-- (approved 是已批未执行,PAYROLL-APR-1 的生命周期)。
-- 【为什么 approve_review 与 set_initial_salary 没有改成问它】Tim 的 Q5 说的是调薪申请;那两支的日期判据
-- ROLE-1 定下之后原样不动(第一份月薪"照 ROLE-1 Batch 1 留下的样子")。它们多问一句在途申请,是另一刀的决定。
-- 返回一句拒绝文本,不 RAISE:调用方(提交、批准)各自 RAISE,屏幕不调用它。EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_effective_period_block(p_effective_date date)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|' || p.code
           FROM payroll_periods p
          WHERE p.deleted_at IS NULL AND p.status = 'posted'
            AND p_effective_date >= p.period_month
            AND p_effective_date < (p.period_month + interval '1 month')::date
          ORDER BY p.period_month
          LIMIT 1),
        (SELECT 'SALARY_EFFECTIVE_IN_REQUESTED_PERIOD|' || p.code || '|' || q.label
           FROM payroll_periods p
           JOIN payroll_requests q ON q.payroll_period_id = p.id AND q.status IN ('submitted', 'approved')
          WHERE p.deleted_at IS NULL
            AND p_effective_date >= p.period_month
            AND p_effective_date < (p.period_month + interval '1 month')::date
          ORDER BY p.period_month, q.created_at
          LIMIT 1));
$function$;
