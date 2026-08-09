-- OPS-20:批次毛利 —— Doc 2 说"生意最需要、而 Xero 结构上做不出来"的那个数
--
-- Phase 3 的完成定义里欠着的就是这一条。今天【不改表就能算】:收入来自
-- sales_records.amount_base,成本来自 processing_outputs.unit_cost_base × 已售数量。
--
-- ══ 一、从 output_batches 起 LEFT JOIN,永远不要从 processing_outputs 起 ══════
-- live 有一个批次(OUT-2026-0001)卖了 24,000 而【根本没有加工单】。以
-- processing_outputs 为主表,它会【一声不响地消失】—— 屏幕上不是错,是少一行,
-- 而少的那一行恰好是金额最大的那一笔。"没有成本依据"必须是一行,不是一个缺席。
--
-- ══ 二、成本缺失时毛利是 NULL,绝不按零成本算 ═══════════════════════════════
-- live 上四个有收入的批次里【三个】没有单位成本。COALESCE(unit_cost, 0) 会把这三个
-- 印成 100% 毛利 —— 而且是四舍五入到分的、看起来完全正常的 100%。
-- 这正是 AGENTS.md 那条"权利是【推导】出来的、消耗是【记录】下来的":收入被记录,
-- 成本靠推导,推导的那一半缺席,结果既合理又错误,还不报错。
-- 【本视图靠 NULL 传播实现这一条,不是靠 CASE】—— 少写一个 COALESCE 就退化了,
-- 所以 fixture 31 A 臂直接钉住"有收入无成本 → margin_base 与 margin_pct 皆为 NULL"。
--
-- ══ 三、三个限定词【跟着数字走】,不是旁边的脚注 ═════════════════════════════
--   cost_incomplete —— 有未计价的输入被当成零计入,毛利【被高估】;经由再加工传染
--                      (FIN-25 已把传染算进 processing_outputs.cost_incomplete,这里直接带出)
--   is_stale        —— 分摊之后成本又动了,单位成本过期
--   cogs_posted_base vs cost_current_base —— record_output_sale 过账 COGS 一次且
--                      【永不重述】,而重分摊把差额记在【当期的单据层】(FIN-24)。
--                      于是两个数不同,而且【两个都对】:一个是总账事实,一个是管理口径。
--                      本视图给的是【管理口径】(当前单位成本),并把总账那个数并列出来,
--                      cogs_differs 明说它们不同 —— 屏幕上必须写清楚用的是哪一个。
--
-- ══ 四、is_stale 在这里【重算了一遍】,这是有意的,并且被 fixture 钉住 ══════════
-- processing_run_allocation_status 是这条定义的出处(FIN-24/25 的三个过期源)。
-- 但它是属主权限 + has_permission('module.processing.view'),而 has_permission 按
-- 【调用者】解析 —— 一个只有 finance 的读者从它读到【零行】,LEFT JOIN 出来 is_stale
-- 就成了 NULL/false:那正是 OPS-14 修掉的病(借来的派生事实静默消失),而且恰好发生在
-- 最需要这个毛利数的角色身上。所以这里按同一份定义就地算,不去读那张视图。
-- 【重复的定义会漂,所以 fixture 31 D 臂断言两者对同一个 run 给出同一个答案。】
-- 改动其中一边时,另一边在 db/views/processing_run_allocation_status.sql,注释互指。
--
-- ══ 五、权限:属主权限 + data.view_prices AND (finance OR processing)═══════════
-- (AGENTS.md 常设决定 2,本次照它实现。)收入在财务那边,分摊成本在加工那边,而
-- 【没有任何 live 角色同时持有两个模块】—— 实测:finance 无 module.processing.view,
-- operations 无 module.finance.view。写成单模块谓词,这个数就对它该服务的人隐身。
-- 【OR 就是全部要点。】data.view_prices 是硬前提:毛利本身就是价格信息。
--
-- ══ 未售批次不在本视图里 ══════════════════════════════════════════════════════
-- 没卖出去就没有毛利可言;滞销由看板的 output_unsold_aging 那一支负责。
--
-- NOTE: introduced by db/migrations/2026-08-09-ops20-batch-gross-margin.sql.

CREATE VIEW public.batch_margin WITH (security_invoker = off) AS
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
