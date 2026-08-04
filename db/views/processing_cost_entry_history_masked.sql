-- db/views/processing_cost_entry_history_masked.sql
-- 成本条目历史的遮蔽伴生视图。金额与 processing_cost_entries.amount_base 同口径:
-- 归 data.view_prices。【每一列都在】—— 加列时这里和列清单授权必须一起改,
-- 否则 db/gate.py 的【列权限缺口】判据会失败(FIN-7-fu 的教训)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin8-cost-entry-history-and-stale-allocation.sql.

CREATE VIEW public.processing_cost_entry_history_masked WITH (security_invoker = off) AS
 SELECT id,
    entry_id,
    run_id,
    change_type,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_amount_base
            ELSE NULL::numeric
        END AS old_amount_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_amount_base
            ELSE NULL::numeric
        END AS new_amount_base,
    old_cost_type,
    new_cost_type,
    old_is_estimate,
    new_is_estimate,
    changed_at,
    changed_by
   FROM processing_cost_entry_history
  WHERE has_permission('module.processing.view'::text);

GRANT SELECT ON public.processing_cost_entry_history_masked TO authenticated;
