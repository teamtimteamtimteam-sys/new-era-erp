-- db/views/processing_cost_entry_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.processing_cost_entry_lookup WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    cost_type,
    is_estimate,
    created_at,
    deleted_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    remitted_at,
    relieved_at
   FROM processing_cost_entries e
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.processing_cost_entry_lookup IS
    'FIX-2a:加工成本条目的【查名】视图 —— id / 加工单 / 成本类型 / 是否估算 / 创建时间 / 汇缴与冲销时点,外加按 data.view_prices 遮的金额(与 processing_cost_entries_masked 同一条列谓词)。财务的分录、总账、月结与加工成本四处要把一条分录指回它的来源单据,并回答"还欠着哪些"。fu1 补了 remitted_at / relieved_at:它们是状态时点不是钱,而两页的 .is() 过滤链要它们 —— 主迁移只读了 select 列表、没读过滤链,于是两页 42703(冒烟抓到,类型系统看不见)。行谓词 processing.view OR finance.view。';

GRANT SELECT ON public.processing_cost_entry_lookup TO authenticated;
