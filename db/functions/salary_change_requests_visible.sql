-- db/functions/salary_change_requests_visible.sql
-- APR-9(2026-09-27):员工页上"调薪申请"那一块读的就是这里。
--   谁读得到:module.hr.view 且 data.view_pay(与表的读策略同一对码)。其余 → 零行 —— 主角在等待中读不到自己的
--   调薪申请(绩效评估"本人只在批准之后看得见"同一条);批准之后他从自己的档案与履历上看得见新月薪。
--   p_employee_id 给了就只给那个人的;只给在等的全部 + 最近决定 / 撤回的 p_recent 张。
--   current_matches = 活数与提交时的 fingerprint 一样(不一样,CFO 批准会被 SALARY_CHANGED_SINCE_REQUEST 拒,
--   屏幕先说出来)。decide_code = pay_decision_code 给出的那个码;decide_block = 读者此刻为什么批不了:
--   NULL(批得了)· 'NEEDS_CODE|<码>' · 'SELF|raiser' / 'SELF|subject'。屏幕不在 TypeScript 里重算这条规矩。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_requests_visible(p_employee_id uuid DEFAULT NULL::uuid, p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, status text, label text, employee_id uuid, employee_code text, employee_name text, old_monthly_salary numeric, new_monthly_salary numeric, effective_date date, reason text, current_matches boolean, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decided_via text, decision_notes text, withdrawn_at timestamptz, withdraw_reason text, decide_code text, decide_block text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM salary_change_requests q
         WHERE has_permission('module.hr.view') AND has_permission('data.view_pay')
           AND (p_employee_id IS NULL OR q.employee_id = p_employee_id)),
    d AS (
        SELECT r.*, pay_decision_code(r.created_by, r.employee_id) AS code,
               self_leg(r.created_by, r.employee_id, auth.uid()) AS leg
          FROM r)
    SELECT d.id, d.status, d.label, d.employee_id, e.code, e.legal_name,
           d.old_monthly_salary, d.new_monthly_salary, d.effective_date, d.reason,
           salary_change_fingerprint(d.employee_id) IS NOT DISTINCT FROM d.snapshot,
           d.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = d.created_by),
           d.leg = 'raiser',
           d.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = d.decided_by),
           d.decided_via, d.decision_notes, d.withdrawn_at, d.withdraw_reason,
           d.code,
           CASE WHEN NOT has_permission(d.code) THEN 'NEEDS_CODE|' || d.code
                WHEN d.leg <> 'none' THEN 'SELF|' || d.leg
           END
      FROM d
      JOIN employees e ON e.id = d.employee_id
     WHERE d.is_open OR d.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY d.is_open DESC, COALESCE(d.decided_at, d.withdrawn_at, d.created_at) DESC
$function$;
