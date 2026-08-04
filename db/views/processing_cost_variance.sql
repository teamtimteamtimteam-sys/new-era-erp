-- db/views/processing_cost_variance.sql
-- 估算 vs 实际,按成本类型 × 月(发票所在月)。目的不是看某一个月,而是让
-- 【系统性偏差】显形 —— 某类估算一直偏低,趋势会说话(FIN-6 D)。
-- cost_type 是表上的 CHECK 枚举(不是自由文本),分组可靠。
-- 只含估算冲抵(实际额行没有"估算 vs 实际"可言)。SECURITY INVOKER。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.

CREATE VIEW public.processing_cost_variance WITH (security_invoker = on) AS
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
  GROUP BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type
  ORDER BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type;
