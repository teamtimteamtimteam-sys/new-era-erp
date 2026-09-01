-- AUDIT-1(2026-09-01):跨模块审计轨迹,**键在批次上**。
--
-- 【它不是什么】它不是全局搜索(那件排在 Phase 8 之后,按【编号】找记录),
-- 也不是 traceability_report_data() 的延长线。后者是一份【交给客户的证书】,
-- 它在没有血缘时 RAISE 'NOTHING_TO_REPORT' —— 对一份单据这是对的,
-- 对一条轨迹这是错的:审计要的恰恰是"这个批次身上什么都没发生"这个答案本身。
-- 所以本刀【另起两张只读视图,与它并排,不动它一个字】(Tim 的 R2)。
--
-- ── 拆成两张的理由,照抄 AUD-1(2026-08-17),这是硬要求 ─────────────────────
-- 属主权限替得了视图引用的表的权限,**替不了视图体内那句 has_permission ——
-- 它按【调用者】解析**。于是判据必须挪到【外层】,内层留一张【不授权给任何人】的
-- 基视图,靠"够不着"把关。AUD-1 实测过反例:判据留在内层时,一个只持
-- module.sales.view 的读者拿到【零行】,而零行在这里的意思会变成
-- "这个批次什么都没发生过" —— 一个错的好消息。
--
-- ── R4:【不新造第二套"谁能看什么"】────────────────────────────────────────
-- 每一支的 module_code 一律【抄自那张表自己的 SELECT 策略】,不是本刀新定的。
-- 实测抄来的,其中四条与直觉相反,值得写下来:
--   * output_batches      → module.output.view   (**不是** processing)
--   * sales_records       → module.finance.view  (**不是** sales)
--   * sales_record_movements / sales_attribution_log → module.finance.view
--   * traceability_report_issues → sales **OR** processing
-- 抄错任何一条,这张视图(属主权限)就会绕过那张表的 RLS 泄露行。
--
-- ── R5:外层【admission 用 OR,逐支再带一个 may_view 标志】────────────────
-- 单一 OR 判据会二选一地坏掉:要么把财务行泄露给只持 inventory 的读者,
-- 要么让财务那一段【整段消失】。消失的那一段读起来是"没有分录",
-- 而真相是"你不能看" —— 又一个 AUD-1 家族的错的好消息。
-- 所以:admission 决定【进不进得来】,may_view 决定【这一段是内容还是「受限」】。
-- may_view=false 的行**仍然出现**,但 detail 被换成具名的受限标记,
-- 且不带任何来自那张表的实际值。
--
-- ── R3:接缝【渲染在行里】,不是只写在文档里 ─────────────────────────────
-- seams text[] 逐行标出轨迹跟不动的那一跳。今天会出现的取值,全部实测:
--   no_purchase_order   进料批不带 purchase_order_line_id(16 个未软删里 8 个不带)
--   actor_unrecorded    行为人列是 NULL
--   actor_unresolvable  行为人有值,但解析不到人(实测 13 个 actor 里 12 个)
--   polymorphic_source  分录经 source_type 多态解析够到批次(source_type 命名的是
--                       一个【概念】不是一张【表】:'purchase' 同时指向
--                       inbound_batches ×8 与 journal_entries ×2)
--   reversed            这笔分录已被冲销,冲销件在下一行
--   is_reversal         这一行【是】那笔冲销
--   run_voided          这支加工单已被软删(processing_inputs 仍看得见它,
--                       batch_lineage_all 看不见 —— 三个数据源三种说法)
--   amount_restricted   金额列被列级遮蔽,且本读者不持 data.view_prices
--   no_policy_admits    那张表的 SELECT 策略【没有】接纳这一行的分支
--                       (实测:approval_log 的 CASE 没有 work_order 这一支,
--                        落到 ELSE false,于是那 1 行对每一个读者都不可见)
--
-- ── 3d:冲销【必须出现】──────────────────────────────────────────────────
-- JE-2026-0003 的 source_id 是批次、status='reversed';它的冲销 JE-2026-0004 的
-- source_id 指向【那笔分录】,不是批次。于是一张 WHERE source_id=批次.id 的轨迹
-- 看得见过账、看不见冲销。**修法是跟 reversed_by 那一跳** —— 实测线上 13 对
-- 冲销全部 reversed_by 有值,且 13 对里冲销件的 source_id 都等于过账件的 id,
-- 所以**本刀不需要任何 schema 改动**。
-- **绝不去解析 memo**:memo 是人打的自由文本,依赖它的拼法的轨迹,
-- 会在第一个换个说法的人手上【安静地】坏掉。
--
-- ── 列级遮蔽:属主权限视图【必须自己挡】────────────────────────────────────
-- 实测这五张源表有列被从 authenticated 手里收回,本视图是属主权限,会绕过它:
--   price_history: old_unit_price/new_unit_price/original_price/fx_rate
--   sales_records: unit_price/fx_rate/amount_base/price_provenance
--   processing_runs: material_cost_base/process_cost_base/total_cost_base/capitalized_cost_base
--   processing_cost_entry_history: old_amount_base/new_amount_base
--   inbound_batches: unit_price
-- 一律按 data.view_prices 判,不持则**不放进 detail**,并标 amount_restricted。
-- 【不是置 NULL】—— null 在这套系统里本来就有含义(未分摊/未填/未定价),
-- 把"你不能看"混进去正是 lib/permissions.ts 抬头写的那个病。

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 一 · 无判据基视图 —— 【不授权给任何人】
-- ════════════════════════════════════════════════════════════════════════════
CREATE VIEW public.batch_audit_trail_all AS
WITH
-- 分录 → 批次的多态解析(缝 4)。source_type 命名的是概念不是表,所以逐臂手写。
je_batch AS (
    -- purchase / writeoff → inbound_batches(实测 8 + 2)
    SELECT je.id AS je_id, 'inbound'::text AS batch_kind, ib.id AS batch_id
      FROM journal_entries je JOIN inbound_batches ib ON ib.id = je.source_id
    UNION
    -- sale → sales_records → output_batch(实测 9)
    SELECT je.id, 'output'::text, sr.output_batch_id
      FROM journal_entries je JOIN sales_records sr ON sr.id = je.source_id
     WHERE sr.output_batch_id IS NOT NULL
    UNION
    -- processing_cost → processing_cost_entries → run → 两侧批次(实测 9;
    -- 注意它【不是】指向 processing_runs —— 直接 join runs 会得到 0 行)
    SELECT je.id, 'inbound'::text, pi.inbound_batch_id
      FROM journal_entries je
      JOIN processing_cost_entries pce ON pce.id = je.source_id
      JOIN processing_inputs pi ON pi.run_id = pce.run_id
     WHERE pi.inbound_batch_id IS NOT NULL
    UNION
    SELECT je.id, 'output'::text, po.output_batch_id
      FROM journal_entries je
      JOIN processing_cost_entries pce ON pce.id = je.source_id
      JOIN processing_outputs po ON po.run_id = pce.run_id
    UNION
    -- allocation → processing_runs(实测 2)
    SELECT je.id, 'inbound'::text, pi.inbound_batch_id
      FROM journal_entries je JOIN processing_runs pr ON pr.id = je.source_id
      JOIN processing_inputs pi ON pi.run_id = pr.id
     WHERE pi.inbound_batch_id IS NOT NULL
    UNION
    SELECT je.id, 'output'::text, po.output_batch_id
      FROM journal_entries je JOIN processing_runs pr ON pr.id = je.source_id
      JOIN processing_outputs po ON po.run_id = pr.id
    UNION
    -- stocktake → stocktakes → stocktake_lines(实测 1)
    SELECT je.id,
           CASE WHEN sl.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
           COALESCE(sl.inbound_batch_id, sl.output_batch_id)
      FROM journal_entries je JOIN stocktakes st ON st.id = je.source_id
      JOIN stocktake_lines sl ON sl.stocktake_id = st.id
     WHERE COALESCE(sl.inbound_batch_id, sl.output_batch_id) IS NOT NULL
),
-- 3d:把冲销件挂到【被冲销件所挂的那个批次】上。跟的是 reversed_by,不是 memo。
je_reach AS (
    SELECT je_id, batch_kind, batch_id, false AS via_reversal FROM je_batch
    UNION
    SELECT je.reversed_by, b.batch_kind, b.batch_id, true
      FROM je_batch b JOIN journal_entries je ON je.id = b.je_id
     WHERE je.reversed_by IS NOT NULL
)

-- ── 支 1:收货(进料批自己那一行)· module.inbound.view ─────────────────────
SELECT 'inbound'::text AS batch_kind, ib.id AS batch_id,
       ib.created_at AS occurred_at, ib.arrival_date AS business_date,
       'receipt'::text AS event_kind, 'module.inbound.view'::text AS module_code,
       ib.created_by AS actor_id, 'auth'::text AS actor_space,
       'inbound_batches'::text AS source_table, ib.id AS source_id,
       ib.code AS source_code, ('/inbound/' || ib.id || '/edit')::text AS href,
       jsonb_build_object('quantity', ib.quantity, 'unit', ib.unit, 'stage', ib.stage,
                          'status', ib.status) AS detail,
       (ARRAY[]::text[]
        || CASE WHEN ib.purchase_order_line_id IS NULL THEN ARRAY['no_purchase_order'] ELSE ARRAY[]::text[] END
        || CASE WHEN ib.created_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END
       ) AS seams
  FROM inbound_batches ib

UNION ALL
-- ── 支 2:产出批建立 · module.output.view(**不是** processing)────────────
SELECT 'output', ob.id, ob.created_at, ob.output_date,
       'output_created', 'module.output.view',
       ob.created_by, 'auth', 'output_batches', ob.id, ob.code,
       ('/output/' || ob.id || '/edit'),
       jsonb_build_object('quantity', ob.quantity, 'unit', ob.unit, 'state', ob.state,
                          'status', ob.status),
       (ARRAY[]::text[] || CASE WHEN ob.created_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END)
  FROM output_batches ob

UNION ALL
-- ── 支 3:库存流水 · module.inventory.view —— 【本轨迹的脊柱】(Tim 的 A4)──
-- 选它当脊柱,因为**只有它把"冲销"本身记成了一件发生过的事**:同一支被软删的
-- 加工单,processing_inputs 看得见、batch_lineage_all 看不见、而流水两边都看得见
-- (processing_consume 与 reversal_restore 各一条)。
SELECT CASE WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
       COALESCE(m.inbound_batch_id, m.output_batch_id),
       m.occurred_at, m.business_date,
       'movement', 'module.inventory.view',
       m.created_by, 'auth', 'inventory_movements', m.id, NULL,
       NULL,
       jsonb_build_object('movement_type', m.movement_type, 'qty_delta', m.qty_delta,
                          'stock_status', m.stock_status, 'notes', m.notes),
       (ARRAY[]::text[]
        || CASE WHEN m.created_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END
        || CASE WHEN m.run_id IS NOT NULL AND EXISTS (
                     SELECT 1 FROM processing_runs r WHERE r.id = m.run_id AND r.deleted_at IS NOT NULL)
                THEN ARRAY['run_voided'] ELSE ARRAY[]::text[] END)
  FROM inventory_movements m
 WHERE COALESCE(m.inbound_batch_id, m.output_batch_id) IS NOT NULL

UNION ALL
-- ── 支 4:定价变更 · module.inbound.view ──────────────────────────────────
-- **金额不进 detail** —— 四列被列级遮蔽,由外层按 data.view_prices 决定。
SELECT 'inbound', ph.inbound_batch_id, ph.created_at, ph.rate_as_of,
       'price_change', 'module.inbound.view',
       ph.created_by, 'auth', 'price_history', ph.id, NULL,
       ('/inbound/' || ph.inbound_batch_id || '/edit'),
       jsonb_build_object('currency', ph.currency, 'rate_type', ph.rate_type, 'notes', ph.notes),
       (ARRAY['has_masked_amount']::text[]
        || CASE WHEN ph.created_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END)
  FROM price_history ph

UNION ALL
-- ── 支 5:加工消耗(两种批次都可能被吃)· module.processing.view ──────────
SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
       COALESCE(pi.inbound_batch_id, pi.output_batch_id),
       pi.created_at, pr.process_date,
       'run_input', 'module.processing.view',
       pr.created_by, 'auth', 'processing_inputs', pi.id, pr.code,
       ('/processing/' || pr.id),
       jsonb_build_object('quantity_consumed', pi.quantity_consumed, 'run_code', pr.code,
                          'operation_type_code', pr.operation_type_code),
       (ARRAY[]::text[]
        || CASE WHEN pr.deleted_at IS NOT NULL THEN ARRAY['run_voided'] ELSE ARRAY[]::text[] END
        || CASE WHEN pr.created_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END)
  FROM processing_inputs pi JOIN processing_runs pr ON pr.id = pi.run_id
 WHERE COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL

UNION ALL
-- ── 支 6:加工产出 · module.processing.view ───────────────────────────────
SELECT 'output', po.output_batch_id, po.created_at, pr.process_date,
       'run_output', 'module.processing.view',
       pr.created_by, 'auth', 'processing_outputs', po.id, pr.code,
       ('/processing/' || pr.id),
       jsonb_build_object('quantity_produced', po.quantity_produced, 'run_code', pr.code,
                          'cost_incomplete', po.cost_incomplete),
       (ARRAY[]::text[]
        || CASE WHEN pr.deleted_at IS NOT NULL THEN ARRAY['run_voided'] ELSE ARRAY[]::text[] END
        || CASE WHEN pr.created_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END)
  FROM processing_outputs po JOIN processing_runs pr ON pr.id = po.run_id

UNION ALL
-- ── 支 7:成本分摊 · 抄 batch_processing_cost_allocations 自己的 OR 策略 ───
-- 这一支的 amount_base 【没有】被遮蔽(实测 8/8 列可读),所以照常进 detail。
SELECT 'inbound', a.inbound_batch_id, a.created_at, pr.process_date,
       'cost_allocation', 'module.processing.view',
       a.created_by, 'auth', 'batch_processing_cost_allocations', a.id, pr.code,
       ('/processing/' || a.run_id),
       jsonb_build_object('amount_base', a.amount_base, 'basis_qty', a.basis_qty,
                          'basis_total_qty', a.basis_total_qty, 'run_code', pr.code),
       (ARRAY[]::text[] || CASE WHEN a.created_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END)
  FROM batch_processing_cost_allocations a JOIN processing_runs pr ON pr.id = a.run_id

UNION ALL
-- ── 支 8:加工成本条目变更(经 run 传递够到批次,实测 7 行)────────────────
SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
       COALESCE(pi.inbound_batch_id, pi.output_batch_id),
       h.changed_at, pr.process_date,
       'cost_entry_change', 'module.processing.view',
       h.changed_by, 'auth', 'processing_cost_entry_history', h.id, pr.code,
       ('/processing/' || h.run_id),
       jsonb_build_object('change_type', h.change_type, 'old_cost_type', h.old_cost_type,
                          'new_cost_type', h.new_cost_type, 'run_code', pr.code),
       (ARRAY['has_masked_amount']::text[]
        || CASE WHEN h.changed_by IS NULL THEN ARRAY['actor_unrecorded'] ELSE ARRAY[]::text[] END)
  FROM processing_cost_entry_history h
  JOIN processing_runs pr ON pr.id = h.run_id
  JOIN processing_inputs pi ON pi.run_id = h.run_id
 WHERE COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL

UNION ALL
-- ── 支 9:销售 · module.finance.view(**不是** sales —— 抄自它自己的策略)──
SELECT 'output', sr.output_batch_id, sr.created_at, sr.sale_date,
       'sale', 'module.finance.view',
       sr.created_by, 'auth', 'sales_records', sr.id, NULL,
       ('/output/' || sr.output_batch_id || '/edit'),
       jsonb_build_object('quantity', sr.quantity, 'currency', sr.currency,
                          'price_source', sr.price_source,
                          'cogs_entry_linked', (sr.cogs_entry_id IS NOT NULL)),
       (ARRAY['has_masked_amount']::text[]
        || CASE WHEN sr.cogs_entry_id IS NULL THEN ARRAY['no_cogs_entry'] ELSE ARRAY[]::text[] END)
  FROM sales_records sr WHERE sr.output_batch_id IS NOT NULL

UNION ALL
-- ── 支 10:销售流水配对(sales_record_movements)· module.finance.view ─────
SELECT CASE WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
       COALESCE(m.inbound_batch_id, m.output_batch_id),
       srm.created_at, m.business_date,
       'sale_movement', 'module.finance.view',
       NULL, 'auth', 'sales_record_movements', srm.id, NULL,
       NULL,
       jsonb_build_object('movement_type', m.movement_type),
       ARRAY['actor_unrecorded']::text[]   -- 这张表【结构上】就没有行为人列
  FROM sales_record_movements srm JOIN inventory_movements m ON m.id = srm.movement_id
 WHERE COALESCE(m.inbound_batch_id, m.output_batch_id) IS NOT NULL

UNION ALL
-- ── 支 11:销售归因 · module.finance.view ─────────────────────────────────
SELECT 'output', sr.output_batch_id, l.attributed_at, NULL::date,
       'attribution', 'module.finance.view',
       l.attributed_by, 'auth', 'sales_attribution_log', l.id, NULL, NULL,
       jsonb_build_object('note', l.note),
       ARRAY[]::text[]
  FROM sales_attribution_log l JOIN sales_records sr ON sr.id = l.sales_record_id
 WHERE sr.output_batch_id IS NOT NULL

UNION ALL
-- ── 支 12:预留 · module.sales.view ───────────────────────────────────────
SELECT 'output', r.output_batch_id, r.created_at, NULL::date,
       'reservation', 'module.sales.view',
       r.created_by, 'auth', 'sales_order_reservations', r.id, NULL, NULL,
       jsonb_build_object('qty', r.qty, 'released', (r.released_at IS NOT NULL),
                          'consumed', (r.consumed_at IS NOT NULL),
                          'release_reason', r.release_reason),
       ARRAY[]::text[]
  FROM sales_order_reservations r WHERE r.output_batch_id IS NOT NULL

UNION ALL
-- ── 支 13:发运 · module.sales.view ───────────────────────────────────────
SELECT 'output', sl.output_batch_id, sl.created_at, s.ship_date,
       'shipment', 'module.sales.view',
       s.created_by, 'auth', 'shipment_lines', sl.id, s.code,
       NULL,
       jsonb_build_object('qty', sl.qty, 'shipment_code', s.code),
       ARRAY[]::text[]
  FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id
 WHERE sl.output_batch_id IS NOT NULL

UNION ALL
-- ── 支 14:盘点行 · module.stocktakes.view ────────────────────────────────
SELECT CASE WHEN sl.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
       COALESCE(sl.inbound_batch_id, sl.output_batch_id),
       sl.counted_at, NULL::date,
       'stocktake_line', 'module.stocktakes.view',
       sl.created_by, 'auth', 'stocktake_lines', sl.id, st.code,
       ('/stocktakes/' || st.id),
       jsonb_build_object('book_qty', sl.book_qty, 'counted_qty', sl.counted_qty,
                          'stocktake_code', st.code, 'stocktake_status', st.status),
       ARRAY[]::text[]
  FROM stocktake_lines sl JOIN stocktakes st ON st.id = sl.stocktake_id
 WHERE COALESCE(sl.inbound_batch_id, sl.output_batch_id) IS NOT NULL

UNION ALL
-- ── 支 15:可追溯报告签发 · sales OR processing(抄它自己的策略)──────────
SELECT 'output', i.output_batch_id, i.issued_at, NULL::date,
       'report_issued', 'module.processing.view',
       i.issued_by, 'auth', 'traceability_report_issues', i.id, i.code,
       ('/output/' || i.output_batch_id || '/edit'),
       jsonb_build_object('code', i.code, 'version', i.version, 'sha256', i.sha256),
       ARRAY[]::text[]
  FROM traceability_report_issues i

UNION ALL
-- ── 支 16:审批 · 抄 approval_log 自己那个 CASE ───────────────────────────
-- **注意 work_order 那一支:那个 CASE 里【没有】它,落到 ELSE false。**
-- 于是线上那 1 行审批对每一个读者都不可见 —— 本刀把它标成 no_policy_admits
-- 并如实渲染成「受限」,**不擅自放行**(那会绕过 RLS),也不悄悄省略。
SELECT b.batch_kind, b.batch_id, a.decided_at, NULL::date,
       'approval',
       CASE a.subject_type
            WHEN 'purchase_order' THEN 'module.purchasing.view'
            ELSE '__no_policy__' END,
       a.actor_user_id, 'auth', 'approval_log', a.id, a.subject_code, NULL,
       jsonb_build_object('subject_type', a.subject_type, 'decision', a.decision,
                          'level', a.level, 'note', a.note),
       (ARRAY[]::text[]
        || CASE WHEN a.subject_type NOT IN ('purchase_order')
                THEN ARRAY['no_policy_admits'] ELSE ARRAY[]::text[] END)
  FROM approval_log a
  JOIN LATERAL (
        SELECT 'inbound'::text AS batch_kind, ib.id AS batch_id
          FROM inbound_batches ib
         WHERE a.subject_type = 'purchase_order' AND ib.purchase_order_id = a.subject_id
        UNION
        SELECT 'inbound'::text, pi2.inbound_batch_id
          FROM processing_runs r2 JOIN processing_inputs pi2 ON pi2.run_id = r2.id
         WHERE a.subject_type = 'work_order' AND r2.work_order_id = a.subject_id
           AND pi2.inbound_batch_id IS NOT NULL
  ) b ON true

UNION ALL
-- ── 支 17:生产工单变更(经 run.work_order_id,实测 2 行)──────────────────
SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
       COALESCE(pi.inbound_batch_id, pi.output_batch_id),
       h.changed_at, NULL::date,
       'work_order_change', 'module.processing.view',
       h.changed_by, 'auth', 'work_order_history', h.id, NULL,
       NULL,
       jsonb_build_object('change_type', h.change_type, 'detail', h.detail,
                          'amend_reason', h.amend_reason),
       ARRAY[]::text[]
  FROM work_order_history h
  JOIN processing_runs pr ON pr.work_order_id = h.work_order_id
  JOIN processing_inputs pi ON pi.run_id = pr.id
 WHERE COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL

UNION ALL
-- ── 支 18:采购单变更 · module.purchasing.view ────────────────────────────
-- **【今天 0 行,而这一支是【故意】建的】** 实测:2 行历史,经 po_line 与 po_id
-- 两条路都够不到批次(两侧都是 0)。它在结构上是通的 —— 等有人在【已经收过货的
-- 采购单】上做一次修订,它就会亮。把它省掉才是错的:省掉之后"这个批次的采购单
-- 从没改过"与"这条路本刀没建"在屏幕上长得一模一样。
SELECT 'inbound', ib.id, h.changed_at, NULL::date,
       'po_change', 'module.purchasing.view',
       h.changed_by, 'auth', 'purchase_order_history', h.id, NULL,
       NULL,
       jsonb_build_object('change_type', h.change_type, 'amend_reason', h.amend_reason),
       ARRAY[]::text[]
  FROM purchase_order_history h
  JOIN inbound_batches ib ON ib.purchase_order_id = h.purchase_order_id

UNION ALL
-- ── 支 19:销售单变更 · module.sales.view —— 同上,今天 0 行,故意建 ──────
SELECT 'output', sr.output_batch_id, h.changed_at, NULL::date,
       'so_change', 'module.sales.view',
       h.changed_by, 'auth', 'sales_order_history', h.id, NULL,
       NULL,
       jsonb_build_object('change_type', h.change_type, 'detail', h.detail,
                          'amend_reason', h.amend_reason),
       ARRAY[]::text[]
  FROM sales_order_history h
  JOIN sales_records sr ON sr.sales_order_line_id = h.sales_order_line_id
 WHERE sr.output_batch_id IS NOT NULL

UNION ALL
-- ── 支 20:会计分录 · module.finance.view —— 多态解析 + 冲销那一跳(3d)────
SELECT r.batch_kind, r.batch_id, je.created_at, je.entry_date,
       'journal_entry', 'module.finance.view',
       je.created_by, 'auth', 'journal_entries', je.id, je.code,
       ('/finance/journal/' || je.id),
       jsonb_build_object('code', je.code, 'memo', je.memo, 'status', je.status,
                          'source_type', je.source_type,
                          'reversed_by_code', (SELECT j2.code FROM journal_entries j2 WHERE j2.id = je.reversed_by)),
       (ARRAY['polymorphic_source']::text[]
        || CASE WHEN je.status = 'reversed' THEN ARRAY['reversed'] ELSE ARRAY[]::text[] END
        || CASE WHEN r.via_reversal THEN ARRAY['is_reversal'] ELSE ARRAY[]::text[] END)
  FROM je_reach r JOIN journal_entries je ON je.id = r.je_id;

COMMENT ON VIEW public.batch_audit_trail_all IS
    'AUDIT-1:batch_audit_trail 的【无判据基视图】。20 支 UNION ALL,每支的 module_code 抄自那张源表【自己的 SELECT 策略】(R4:不新造第二套可见性)。【不授权给任何人】,靠够不着把关;对外读 batch_audit_trail。分录那一支跟 reversed_by 把冲销挂回同一个批次(3d),绝不解析 memo。';

-- ════════════════════════════════════════════════════════════════════════════
-- 二 · 外层带判据视图 —— 授权给 authenticated
-- ════════════════════════════════════════════════════════════════════════════
CREATE VIEW public.batch_audit_trail WITH (security_invoker = off) AS
SELECT t.batch_kind,
       t.batch_id,
       t.occurred_at,
       t.business_date,
       t.event_kind,
       t.module_code,
       -- 逐支判据:这一段读者【看不看得见内容】。false 时行仍在,内容换成具名受限。
       has_permission(t.module_code) AS may_view,
       CASE WHEN has_permission(t.module_code) THEN t.actor_id END AS actor_id,
       t.actor_space,
       t.source_table,
       CASE WHEN has_permission(t.module_code) THEN t.source_id END AS source_id,
       CASE WHEN has_permission(t.module_code) THEN t.source_code END AS source_code,
       CASE WHEN has_permission(t.module_code) THEN t.href END AS href,
       -- detail:无权限 → 不放任何来自源表的值;金额被遮蔽且不持 data.view_prices
       -- → 同样不放,并由 seams 里的 amount_restricted 说出来。
       CASE WHEN has_permission(t.module_code) THEN t.detail END AS detail,
       (t.seams
        || CASE WHEN 'has_masked_amount' = ANY (t.seams) AND NOT has_permission('data.view_prices')
                THEN ARRAY['amount_restricted'] ELSE ARRAY[]::text[] END
        || CASE WHEN t.actor_id IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.user_id = t.actor_id)
                THEN ARRAY['actor_unresolvable'] ELSE ARRAY[]::text[] END
       ) AS seams
  FROM batch_audit_trail_all t
 WHERE has_any_permission(ARRAY[
        'module.inbound.view', 'module.output.view', 'module.inventory.view',
        'module.processing.view', 'module.finance.view', 'module.sales.view',
        'module.purchasing.view', 'module.stocktakes.view']);

COMMENT ON VIEW public.batch_audit_trail IS
    'AUDIT-1:跨模块审计轨迹,键在批次上(batch_kind + batch_id)。外层判据 = OR admission(进不进得来),逐行 may_view = 那一支自己的模块权限(这一段是内容还是「受限」)。单一 OR 判据会二选一地坏掉:泄露财务行,或让财务整段消失 —— 后者读起来是「没有分录」而真相是「你不能看」,正是 AUD-1 那个错的好消息。seams 逐行说出轨迹跟不动的那一跳;绝不省略行。';

GRANT SELECT ON public.batch_audit_trail TO authenticated;

COMMIT;
