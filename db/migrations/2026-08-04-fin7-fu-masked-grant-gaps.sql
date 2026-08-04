-- FIN-7 follow-up:补上被遮蔽表的列权限缺口,并把缺口本身变成会失败的门。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【机制:为什么会漏,而且一定还会再漏】
-- ════════════════════════════════════════════════════════════════════════════
-- perm2b 给被遮蔽的表改成了【列清单】授权:
--     REVOKE SELECT ON t FROM authenticated;
--     GRANT  SELECT (a, b, c) ON t TO authenticated;
--
-- 关键的不对称,PostgreSQL 的规则:
--   * 表级 INSERT/UPDATE 授权【自动延伸】到日后 ALTER TABLE 加的新列;
--   * 列清单 SELECT 授权【不会】—— 清单是当时那几列,冻在那里。
--
-- 于是 FIN-6 给 processing_cost_entries 加了四列结算列之后,authenticated 对这四列
-- 有 INSERT/UPDATE 却【没有 SELECT】。任何 SELECT 到它们、或按它们过滤的查询一律
-- 42501。PostgREST 把错误回给页面,页面 `?? []` 把错误变成空数组 ——
-- /finance/processing-costs 与 /finance/month-end 的成本步骤从上线那天起就是空的,
-- 每道门全绿。(这正是 AGENTS.md 里 hr_alerts 引用被收回的 monthly_salary 那条,
-- 换了个地方重演。)
--
-- 【规矩,从此适用于每一次改动】
--   给一张【被遮蔽的表】加列,必须在同一个迁移里做两件事:
--     1. 把新列加进列清单 SELECT 授权(不敏感)——或刻意不加(敏感,只走遮蔽视图);
--     2. 把新列加进 <表名>_masked 视图。
--   忘了不再是"某天有人点开才发现":db/gate.py 的【列权限缺口】判据会当场失败,
--   逐列点名。见该脚本 check_grant_gaps()。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. processing_cost_entries:补 FIN-6 的四列 ──────────────────────────────
-- 四列都是结算元数据(日期与外键),不是金额 —— 敏感的只有 amount_base,它继续
-- 只经遮蔽视图按 data.view_prices 出现。所以这四列直接授权,并进视图。
GRANT SELECT (remitted_at, remitted_journal_entry_id, relieved_at, relief_expense_id)
    ON public.processing_cost_entries TO authenticated;

CREATE OR REPLACE VIEW public.processing_cost_entries_masked WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    cost_type,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    is_estimate,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    -- ── FIN-6 的结算列(本次补入;CREATE OR REPLACE 只能在末尾加列)──────────
    remitted_at,
    remitted_journal_entry_id,
    relieved_at,
    relief_expense_id
   FROM processing_cost_entries
  WHERE has_permission('module.processing.view'::text);

-- ── 2. employment_history_masked:补 work_category ───────────────────────────
-- 同一类缺口,只是还没被人点到:work_category 基表有列权限,视图里却没有这一列,
-- 经视图选它会 42703。趁现在补上,别等它变成第二个 processing_cost_entries。
CREATE OR REPLACE VIEW public.employment_history_masked WITH (security_invoker = off) AS
 SELECT id,
    employee_id,
    effective_date,
    change_type,
    job_title,
    department_id,
    employment_type,
    employment_status,
    notes,
    created_at,
    created_by,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN old_monthly_salary
            ELSE NULL::numeric
        END AS old_monthly_salary,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN new_monthly_salary
            ELSE NULL::numeric
        END AS new_monthly_salary,
    work_category
   FROM employment_history
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();

COMMIT;
