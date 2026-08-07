-- db/migrations/2026-08-08-ops12-cost-variance-view-rights.sql
-- OPS-12:/finance/cost-variance 从上线那天起就是坏的 —— 被 `?? []` 盖住了。
--
-- 【怎么发现的】清掉那一处 `?? []`(换成 mustRows)之后,路由冒烟当场 500:
--     42501 permission denied for table processing_cost_entries
-- 也就是说这一页【从来没有出过数】:它一直安安静静地回 HTTP 200 + 一张空表,
-- 而冒烟断言 2xx,正好从旁边走过去。审计当年判它 "SHOWS FALSE DATA —— 只误导、
-- 不放行",判得对,但那句"只误导"底下压着一个真实的、活的权限缺陷。
--
-- 【根因】本视图是 security_invoker = on,而它读 processing_cost_entries.amount_base
-- —— 那是 cut 2b 收回的敏感列(归 data.view_prices,只能经 _masked 视图读)。
-- 于是任何 authenticated 调用者都撞 42501。这是 AGENTS.md 里 FIN-6 那条
-- 「给被遮蔽的表加列 → 页面 42501 而静默空白」的【第三个实例】,而且是反过来的
-- 方向:不是列没授权,是【视图以调用者身份去读一列本来就不该授权的东西】。
-- gate 的 colgrant 判词看不见它 —— 那条查的是"被遮蔽表的每一列要么授权、要么在
-- 遮蔽视图里"(本表两条都满足),它不查【谁在读这些列】。
--
-- 【修法与 _masked 视图同形】改为属主权限(security_invoker = off),并把权限谓词
-- 【原样写回视图体】—— 这正是 cut 2b 给所有遮蔽视图定下的做法,理由也一样:
-- invoker 视图以调用者身份读基表,任何强到能挡住原始列的机制都会把视图本身挡掉。
-- 谓词是两条【与】:
--   * module.finance.view —— 这一页挂在财务子导航下;
--   * data.view_prices    —— 视图吐的是 amount_base 汇总出来的金额,
--                            属主权限绕过了列授权,所以必须在这里把那道门补回来,
--                            否则等于把敏感金额授给了任何能进财务模块的人。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-08-ops12-cost-variance-view-rights.sql

BEGIN;

DROP VIEW public.processing_cost_variance;

CREATE VIEW public.processing_cost_variance WITH (security_invoker = off) AS
 SELECT date_trunc('month'::text, e.expense_date::timestamp with time zone)::date AS month,
    x.cost_type,
    round(sum(x.accrued), 2) AS estimated_total,
    round(sum(x.actual), 2) AS actual_total,
    round(sum(x.actual) - sum(x.accrued), 2) AS variance,
        CASE
            WHEN sum(x.actual) > sum(x.accrued) THEN 'under_estimated'::text
            WHEN sum(x.actual) < sum(x.accrued) THEN 'over_estimated'::text
            ELSE 'exact'::text
        END AS direction
   FROM ( SELECT pce.relief_expense_id,
            pce.cost_type,
            sum(pce.amount_base) AS accrued,
            max(ex.amount_base) AS actual
           FROM processing_cost_entries pce
             JOIN expenses ex ON ex.id = pce.relief_expense_id
          WHERE pce.relieved_at IS NOT NULL
          GROUP BY pce.relief_expense_id, pce.cost_type) x
     JOIN expenses e ON e.id = x.relief_expense_id
  WHERE has_permission('module.finance.view'::text)
    AND has_permission('data.view_prices'::text)
  GROUP BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type
  ORDER BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type;

GRANT SELECT ON public.processing_cost_variance TO authenticated;

COMMIT;
