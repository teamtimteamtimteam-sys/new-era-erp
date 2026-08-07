-- db/views/processing_cost_variance.sql
-- 估算 vs 实际,按成本类型 × 月(发票所在月)。目的不是看某一个月,而是让
-- 【系统性偏差】显形 —— 某类估算一直偏低,趋势会说话(FIN-6 D)。
-- cost_type 是表上的 CHECK 枚举(不是自由文本),分组可靠。
-- 只含估算冲抵(实际额行没有"估算 vs 实际"可言)。【属主权限】—— 见下。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.

--
-- OPS-12(2026-08-08):改为【属主权限】。原先是 security_invoker = on,而它读
-- processing_cost_entries.amount_base —— cut 2b 收回的敏感列。于是任何 authenticated
-- 调用者都撞 42501,这一页【从上线起就是空的】,被页面里的 `?? []` 盖成了干净的
-- HTTP 200。属主权限绕过列授权,所以把两道门原样写回视图体:
--   module.finance.view(这一页挂在财务子导航下)AND data.view_prices(它吐的是金额)。
-- 与 cut 2b 所有 _masked 视图同形、同理由。

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
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text)
  GROUP BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type
  ORDER BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type;

GRANT SELECT ON public.processing_cost_variance TO authenticated;
