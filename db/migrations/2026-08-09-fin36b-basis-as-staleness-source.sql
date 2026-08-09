-- FIN-36b:分摊基准变更成为【第四个过期源】
--
-- 前三个源(FIN-24/25):成本条目、输入批的 price_history、上游单重分摊。
-- 少了基准这一支,一次 UPDATE ... SET allocation_basis 会让【存着的单位成本】与
-- 【单据自称的方法】对不上,而 is_stale 仍然是 false —— 屏幕上毫无信号。
-- 这正是 FIN-25 给输入价格关掉的那个缺口,换了个来源。
--
-- 【两处都要改】processing_run_allocation_status 是定义的出处;batch_margin 在
-- OPS-20 里【就地重算了一遍】(理由见那份镜像:只有 finance 权限的读者从
-- allocation_status 读到零行,is_stale 会静默塌成 false)。fixture 31E 断言两者
-- 对同一个 run 给出同一个答案 —— 所以这里必须同改,否则那一臂立刻会红。
--
-- 单独一支迁移而不是并进 FIN-36:那一支已经跑过了,ALTER ADD COLUMN 不幂等。
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

BEGIN;

CREATE OR REPLACE VIEW public.processing_run_allocation_status WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    (r.capitalization_entry_id IS NULL OR je.status = 'posted') AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN journal_entries je ON je.id = r.capitalization_entry_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                    FROM processing_cost_entries e
                   WHERE e.run_id = r.id
                  UNION ALL
                  SELECT ph.created_at
                    FROM price_history ph
                    JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                   WHERE pi.run_id = r.id
                  UNION ALL
                  SELECT r2.allocated_at
                    FROM processing_inputs pi2
                    JOIN processing_outputs po2 ON po2.output_batch_id = pi2.output_batch_id
                    JOIN processing_runs r2 ON r2.id = po2.run_id
                   WHERE pi2.run_id = r.id AND r2.allocated_at IS NOT NULL
                UNION ALL
                -- FIN-36:【第四个过期源 —— 分摊基准被改动】前三个是成本条目、
                -- 输入批的 price_history、上游单重分摊。少了这一支,一次
                -- UPDATE ... SET allocation_basis 会让存着的单位成本与单据自称的
                -- 方法对不上而毫无信号 —— 与 FIN-25 给输入价格关掉的缺口同病异源。
                -- allocate_processing_costs 在同一事务里改基准并重写 allocated_at,
                -- 两个时点相等,而 is_stale 用严格大于 —— 重分摊不会自标过期。
                 SELECT r.allocation_basis_changed_at AS ts
) x) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL AND has_permission('module.processing.view'::text);

GRANT SELECT ON public.processing_run_allocation_status TO authenticated;

CREATE OR REPLACE VIEW public.batch_margin WITH (security_invoker = off) AS
 SELECT ob.id AS output_batch_id,
    ob.code AS batch_code,
    m.name AS material_name,
    s.qty_sold,
    s.revenue_base,
    r.id AS run_id,
    r.code AS run_code,
    po.unit_cost_base,
    round(po.unit_cost_base * s.qty_sold, 2) AS cost_current_base,
    round(s.revenue_base - po.unit_cost_base * s.qty_sold, 2) AS margin_base,
        CASE
            WHEN s.revenue_base <> 0::numeric THEN round((s.revenue_base - po.unit_cost_base * s.qty_sold) / s.revenue_base * 100::numeric, 1)
            ELSE NULL::numeric
        END AS margin_pct,
        CASE
            WHEN po.id IS NULL THEN 'no_run'::text
            WHEN po.unit_cost_base IS NULL THEN 'no_unit_cost'::text
            ELSE 'ok'::text
        END AS margin_status,
    COALESCE(po.cost_incomplete, false) AS cost_incomplete,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    s.cogs_posted_base,
    s.cogs_posted_base IS NOT NULL AND po.unit_cost_base IS NOT NULL AND s.cogs_posted_base <> round(po.unit_cost_base * s.qty_sold, 2) AS cogs_differs
   FROM output_batches ob
     JOIN materials m ON m.id = ob.material_id
     LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
     LEFT JOIN processing_runs r ON r.id = po.run_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                   FROM processing_cost_entries e
                  WHERE e.run_id = r.id
                UNION ALL
                 SELECT ph.created_at
                   FROM price_history ph
                     JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                  WHERE pi.run_id = r.id
                UNION ALL
                 SELECT r2.allocated_at
                   FROM processing_inputs pi2
                     JOIN processing_outputs po2 ON po2.output_batch_id = pi2.output_batch_id
                     JOIN processing_runs r2 ON r2.id = po2.run_id
                  WHERE pi2.run_id = r.id AND r2.allocated_at IS NOT NULL
                UNION ALL
                -- FIN-36:第四个过期源 —— 分摊基准被改动。与
                -- processing_run_allocation_status 里那一支【同一份定义】
                -- (fixture 31E 断言两者对同一个 run 给出同一个答案)。
                 SELECT r.allocation_basis_changed_at AS ts
) x) c ON true
     JOIN LATERAL ( SELECT sum(sr.quantity) AS qty_sold,
            sum(sr.amount_base) AS revenue_base,
            ( SELECT sum(l.debit - l.credit) AS sum
                   FROM sales_records sr2
                     JOIN journal_lines l ON l.entry_id = sr2.cogs_entry_id
                     JOIN accounts a ON a.id = l.account_id AND a.account_type = 'cogs'::text
                  WHERE sr2.output_batch_id = ob.id) AS cogs_posted_base
           FROM sales_records sr
          WHERE sr.output_batch_id = ob.id
         HAVING sum(sr.quantity) > 0::numeric) s ON true
  WHERE ob.deleted_at IS NULL AND has_permission('data.view_prices'::text) AND (has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text));

GRANT SELECT ON public.batch_margin TO authenticated;

COMMIT;
