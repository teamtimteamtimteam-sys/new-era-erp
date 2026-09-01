-- db/views/batch_audit_trail.sql
-- AUDIT-1:跨模块审计轨迹,**键在批次上**(batch_kind + batch_id)。
--
-- 【两层判据,各管一件事】(Tim 的 R5)
--   外层 WHERE has_any_permission([...])  → admission:进不进得来。
--   逐行 may_view = has_permission(module_code) → 这一段是【内容】还是【「受限」】。
-- 单一 OR 判据会二选一地坏掉:要么把财务行泄露给只持 inventory 的读者,
-- 要么让财务那一段【整段消失】。消失读起来是「没有分录」,真相是「你不能看」——
-- 又一个 AUD-1 家族的错的好消息。所以受限的行【仍然在】,只是不带任何源表的值。
--
-- 【列级遮蔽:属主权限视图必须自己挡】实测五张源表有列被从 authenticated 收回
-- (price_history / sales_records / processing_runs / processing_cost_entry_history
--  / inbound_batches 的金额列)。本视图是属主权限,会绕过它,所以金额一律
-- 不进 detail,并由 seams 里的 amount_restricted 说出来 ——
-- **不是置 NULL**:null 在这套系统里本来就有含义(未分摊/未填/未定价)。
--
-- 【实测(2026-09-01,IN-2026-0001,33 行)】
--   admin        33 行,33 行可见
--   finance      33 行,run_input / cost_entry_change 受限
--   仅 inventory 33 行,10 行可见、23 行受限、**泄露值 0**,
--                且 9 行分录【仍然是行】而不是消失的一段。
--
-- NOTE: introduced by db/migrations/2026-09-01-audit1-batch-audit-trail.sql.

CREATE VIEW public.batch_audit_trail WITH (security_invoker = off) AS
 SELECT batch_kind,
    batch_id,
    occurred_at,
    business_date,
    event_kind,
    module_code,
    has_permission(module_code) AS may_view,
        CASE
            WHEN has_permission(module_code) THEN actor_id
            ELSE NULL::uuid
        END AS actor_id,
    actor_space,
    source_table,
        CASE
            WHEN has_permission(module_code) THEN source_id
            ELSE NULL::uuid
        END AS source_id,
        CASE
            WHEN has_permission(module_code) THEN source_code
            ELSE NULL::text
        END AS source_code,
        CASE
            WHEN has_permission(module_code) THEN href
            ELSE NULL::text
        END AS href,
        CASE
            WHEN has_permission(module_code) THEN detail
            ELSE NULL::jsonb
        END AS detail,
    (seams ||
        CASE
            WHEN ('has_masked_amount'::text = ANY (seams)) AND NOT has_permission('data.view_prices'::text) THEN ARRAY['amount_restricted'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN actor_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
               FROM employees e
              WHERE e.user_id = t.actor_id)) THEN ARRAY['actor_unresolvable'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM batch_audit_trail_all t
  WHERE has_any_permission(ARRAY['module.inbound.view'::text, 'module.output.view'::text, 'module.inventory.view'::text, 'module.processing.view'::text, 'module.finance.view'::text, 'module.sales.view'::text, 'module.purchasing.view'::text, 'module.stocktakes.view'::text]);

COMMENT ON VIEW public.batch_audit_trail IS
    'AUDIT-1:跨模块审计轨迹,键在批次上(batch_kind + batch_id)。外层判据 = OR admission(进不进得来),逐行 may_view = 那一支自己的模块权限(这一段是内容还是「受限」)。单一 OR 判据会二选一地坏掉:泄露财务行,或让财务整段消失 —— 后者读起来是「没有分录」而真相是「你不能看」,正是 AUD-1 那个错的好消息。seams 逐行说出轨迹跟不动的那一跳;绝不省略行。';

GRANT SELECT ON public.batch_audit_trail TO authenticated;
