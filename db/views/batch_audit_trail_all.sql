-- db/views/batch_audit_trail_all.sql
-- AUDIT-1:batch_audit_trail 的【无判据基视图】。
--
-- 【为什么要拆】照抄 AUD-1(2026-08-17),这是硬要求。属主权限替得了视图引用的
-- 表的权限,**替不了体内那句 has_permission —— 它按【调用者】解析**。判据留在
-- 内层时,一个只持部分模块权限的读者拿到的是【零行】,而零行在这里的意思会变成
-- 「这个批次什么都没发生过」—— 一个错的好消息。判据挪到外层,内层留这一张。
--
-- 【不授权给任何人】它是内层算子,靠"够不着"把关;对外读 batch_audit_trail。
--
-- 【20 支,每支的 module_code 抄自那张源表【自己的】SELECT 策略】(Tim 的 R4:
-- 不新造第二套"谁能看什么")。实测抄来的,其中四条与直觉相反:
--   output_batches → module.output.view(**不是** processing)
--   sales_records / sales_record_movements / sales_attribution_log → module.finance.view
-- 抄错任何一条,这张属主权限视图就会绕过那张表的 RLS 泄露行。
--
-- 【分录那一支跟 reversed_by,不解析 memo】(3d)。JE-2026-0003 的 source_id 是
-- 批次、status='reversed';它的冲销 JE-2026-0004 的 source_id 指向【那笔分录】。
-- 一张 WHERE source_id=批次.id 的轨迹于是看得见过账、看不见冲销。实测线上 13 对
-- 冲销全部 reversed_by 有值,所以跟这一跳就够,**本刀不需要任何 schema 改动**。
-- memo 是人打的自由文本,依赖它拼法的轨迹会在第一个换说法的人手上安静地坏掉。
--
-- NOTE: introduced by db/migrations/2026-09-01-audit1-batch-audit-trail.sql.

CREATE VIEW public.batch_audit_trail_all AS
 WITH je_batch AS (
         SELECT je.id AS je_id,
            'inbound'::text AS batch_kind,
            ib.id AS batch_id
           FROM journal_entries je
             JOIN inbound_batches ib ON ib.id = je.source_id
        UNION
         SELECT je.id,
            'output'::text AS text,
            sr.output_batch_id
           FROM journal_entries je
             JOIN sales_records sr ON sr.id = je.source_id
          WHERE sr.output_batch_id IS NOT NULL
        UNION
         SELECT je.id,
            'inbound'::text AS text,
            pi.inbound_batch_id
           FROM journal_entries je
             JOIN processing_cost_entries pce ON pce.id = je.source_id
             JOIN processing_inputs pi ON pi.run_id = pce.run_id
          WHERE pi.inbound_batch_id IS NOT NULL
        UNION
         SELECT je.id,
            'output'::text AS text,
            po.output_batch_id
           FROM journal_entries je
             JOIN processing_cost_entries pce ON pce.id = je.source_id
             JOIN processing_outputs po ON po.run_id = pce.run_id
        UNION
         SELECT je.id,
            'inbound'::text AS text,
            pi.inbound_batch_id
           FROM journal_entries je
             JOIN processing_runs pr ON pr.id = je.source_id
             JOIN processing_inputs pi ON pi.run_id = pr.id
          WHERE pi.inbound_batch_id IS NOT NULL
        UNION
         SELECT je.id,
            'output'::text AS text,
            po.output_batch_id
           FROM journal_entries je
             JOIN processing_runs pr ON pr.id = je.source_id
             JOIN processing_outputs po ON po.run_id = pr.id
        UNION
         SELECT je.id,
                CASE
                    WHEN sl.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS "case",
            COALESCE(sl.inbound_batch_id, sl.output_batch_id) AS "coalesce"
           FROM journal_entries je
             JOIN stocktakes st ON st.id = je.source_id
             JOIN stocktake_lines sl ON sl.stocktake_id = st.id
          WHERE COALESCE(sl.inbound_batch_id, sl.output_batch_id) IS NOT NULL
        ), je_reach AS (
         SELECT je_batch.je_id,
            je_batch.batch_kind,
            je_batch.batch_id,
            false AS via_reversal
           FROM je_batch
        UNION
         SELECT je.reversed_by,
            b.batch_kind,
            b.batch_id,
            true
           FROM je_batch b
             JOIN journal_entries je ON je.id = b.je_id
          WHERE je.reversed_by IS NOT NULL
        )
 SELECT 'inbound'::text AS batch_kind,
    ib.id AS batch_id,
    ib.created_at AS occurred_at,
    ib.arrival_date AS business_date,
    'receipt'::text AS event_kind,
    'module.inbound.view'::text AS module_code,
    ib.created_by AS actor_id,
    'auth'::text AS actor_space,
    'inbound_batches'::text AS source_table,
    ib.id AS source_id,
    ib.code AS source_code,
    ('/inbound/'::text || ib.id) || '/edit'::text AS href,
    jsonb_build_object('quantity', ib.quantity, 'unit', ib.unit, 'stage', ib.stage, 'status', ib.status) AS detail,
    (ARRAY[]::text[] ||
        CASE
            WHEN ib.purchase_order_line_id IS NULL THEN ARRAY['no_purchase_order'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN ib.created_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM inbound_batches ib
UNION ALL
 SELECT 'output'::text AS batch_kind,
    ob.id AS batch_id,
    ob.created_at AS occurred_at,
    ob.output_date AS business_date,
    'output_created'::text AS event_kind,
    'module.output.view'::text AS module_code,
    ob.created_by AS actor_id,
    'auth'::text AS actor_space,
    'output_batches'::text AS source_table,
    ob.id AS source_id,
    ob.code AS source_code,
    ('/output/'::text || ob.id) || '/edit'::text AS href,
    jsonb_build_object('quantity', ob.quantity, 'unit', ob.unit, 'state', ob.state, 'status', ob.status) AS detail,
    ARRAY[]::text[] ||
        CASE
            WHEN ob.created_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM output_batches ob
UNION ALL
 SELECT
        CASE
            WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(m.inbound_batch_id, m.output_batch_id) AS batch_id,
    m.occurred_at,
    m.business_date,
    'movement'::text AS event_kind,
    'module.inventory.view'::text AS module_code,
    m.created_by AS actor_id,
    'auth'::text AS actor_space,
    'inventory_movements'::text AS source_table,
    m.id AS source_id,
    NULL::text AS source_code,
    NULL::text AS href,
    jsonb_build_object('movement_type', m.movement_type, 'qty_delta', m.qty_delta, 'stock_status', m.stock_status, 'notes', m.notes) AS detail,
    (ARRAY[]::text[] ||
        CASE
            WHEN m.created_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN m.run_id IS NOT NULL AND (EXISTS ( SELECT 1
               FROM processing_runs r
              WHERE r.id = m.run_id AND r.deleted_at IS NOT NULL)) THEN ARRAY['run_voided'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM inventory_movements m
  WHERE COALESCE(m.inbound_batch_id, m.output_batch_id) IS NOT NULL
UNION ALL
 SELECT 'inbound'::text AS batch_kind,
    ph.inbound_batch_id AS batch_id,
    ph.created_at AS occurred_at,
    ph.rate_as_of AS business_date,
    'price_change'::text AS event_kind,
    'module.inbound.view'::text AS module_code,
    ph.created_by AS actor_id,
    'auth'::text AS actor_space,
    'price_history'::text AS source_table,
    ph.id AS source_id,
    NULL::text AS source_code,
    ('/inbound/'::text || ph.inbound_batch_id) || '/edit'::text AS href,
    jsonb_build_object('currency', ph.currency, 'rate_type', ph.rate_type, 'notes', ph.notes) AS detail,
    ARRAY['has_masked_amount'::text] ||
        CASE
            WHEN ph.created_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM price_history ph
UNION ALL
 SELECT
        CASE
            WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
    pi.created_at AS occurred_at,
    pr.process_date AS business_date,
    'run_input'::text AS event_kind,
    'module.processing.view'::text AS module_code,
    pr.created_by AS actor_id,
    'auth'::text AS actor_space,
    'processing_inputs'::text AS source_table,
    pi.id AS source_id,
    pr.code AS source_code,
    '/processing/'::text || pr.id AS href,
    jsonb_build_object('quantity_consumed', pi.quantity_consumed, 'run_code', pr.code, 'operation_type_code', pr.operation_type_code) AS detail,
    (ARRAY[]::text[] ||
        CASE
            WHEN pr.deleted_at IS NOT NULL THEN ARRAY['run_voided'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN pr.created_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM processing_inputs pi
     JOIN processing_runs pr ON pr.id = pi.run_id
  WHERE COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL
UNION ALL
 SELECT 'output'::text AS batch_kind,
    po.output_batch_id AS batch_id,
    po.created_at AS occurred_at,
    pr.process_date AS business_date,
    'run_output'::text AS event_kind,
    'module.processing.view'::text AS module_code,
    pr.created_by AS actor_id,
    'auth'::text AS actor_space,
    'processing_outputs'::text AS source_table,
    po.id AS source_id,
    pr.code AS source_code,
    '/processing/'::text || pr.id AS href,
    jsonb_build_object('quantity_produced', po.quantity_produced, 'run_code', pr.code, 'cost_incomplete', po.cost_incomplete) AS detail,
    (ARRAY[]::text[] ||
        CASE
            WHEN pr.deleted_at IS NOT NULL THEN ARRAY['run_voided'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN pr.created_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM processing_outputs po
     JOIN processing_runs pr ON pr.id = po.run_id
UNION ALL
 SELECT 'inbound'::text AS batch_kind,
    a.inbound_batch_id AS batch_id,
    a.created_at AS occurred_at,
    pr.process_date AS business_date,
    'cost_allocation'::text AS event_kind,
    'module.processing.view'::text AS module_code,
    a.created_by AS actor_id,
    'auth'::text AS actor_space,
    'batch_processing_cost_allocations'::text AS source_table,
    a.id AS source_id,
    pr.code AS source_code,
    '/processing/'::text || a.run_id AS href,
    jsonb_build_object('amount_base', a.amount_base, 'basis_qty', a.basis_qty, 'basis_total_qty', a.basis_total_qty, 'run_code', pr.code) AS detail,
    ARRAY[]::text[] ||
        CASE
            WHEN a.created_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM batch_processing_cost_allocations a
     JOIN processing_runs pr ON pr.id = a.run_id
UNION ALL
 SELECT
        CASE
            WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
    h.changed_at AS occurred_at,
    pr.process_date AS business_date,
    'cost_entry_change'::text AS event_kind,
    'module.processing.view'::text AS module_code,
    h.changed_by AS actor_id,
    'auth'::text AS actor_space,
    'processing_cost_entry_history'::text AS source_table,
    h.id AS source_id,
    pr.code AS source_code,
    '/processing/'::text || h.run_id AS href,
    jsonb_build_object('change_type', h.change_type, 'old_cost_type', h.old_cost_type, 'new_cost_type', h.new_cost_type, 'run_code', pr.code) AS detail,
    ARRAY['has_masked_amount'::text] ||
        CASE
            WHEN h.changed_by IS NULL THEN ARRAY['actor_unrecorded'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM processing_cost_entry_history h
     JOIN processing_runs pr ON pr.id = h.run_id
     JOIN processing_inputs pi ON pi.run_id = h.run_id
  WHERE COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL
UNION ALL
 SELECT 'output'::text AS batch_kind,
    sr.output_batch_id AS batch_id,
    sr.created_at AS occurred_at,
    sr.sale_date AS business_date,
    'sale'::text AS event_kind,
    'module.finance.view'::text AS module_code,
    sr.created_by AS actor_id,
    'auth'::text AS actor_space,
    'sales_records'::text AS source_table,
    sr.id AS source_id,
    NULL::text AS source_code,
    ('/output/'::text || sr.output_batch_id) || '/edit'::text AS href,
    jsonb_build_object('quantity', sr.quantity, 'currency', sr.currency, 'price_source', sr.price_source, 'cogs_entry_linked', sr.cogs_entry_id IS NOT NULL) AS detail,
    ARRAY['has_masked_amount'::text] ||
        CASE
            WHEN sr.cogs_entry_id IS NULL THEN ARRAY['no_cogs_entry'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM sales_records sr
  WHERE sr.output_batch_id IS NOT NULL
UNION ALL
 SELECT
        CASE
            WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(m.inbound_batch_id, m.output_batch_id) AS batch_id,
    srm.created_at AS occurred_at,
    m.business_date,
    'sale_movement'::text AS event_kind,
    'module.finance.view'::text AS module_code,
    NULL::uuid AS actor_id,
    'auth'::text AS actor_space,
    'sales_record_movements'::text AS source_table,
    srm.id AS source_id,
    NULL::text AS source_code,
    NULL::text AS href,
    jsonb_build_object('movement_type', m.movement_type) AS detail,
    ARRAY['actor_unrecorded'::text] AS seams
   FROM sales_record_movements srm
     JOIN inventory_movements m ON m.id = srm.movement_id
  WHERE COALESCE(m.inbound_batch_id, m.output_batch_id) IS NOT NULL
UNION ALL
 SELECT 'output'::text AS batch_kind,
    sr.output_batch_id AS batch_id,
    l.attributed_at AS occurred_at,
    NULL::date AS business_date,
    'attribution'::text AS event_kind,
    'module.finance.view'::text AS module_code,
    l.attributed_by AS actor_id,
    'auth'::text AS actor_space,
    'sales_attribution_log'::text AS source_table,
    l.id AS source_id,
    NULL::text AS source_code,
    NULL::text AS href,
    jsonb_build_object('note', l.note) AS detail,
    ARRAY[]::text[] AS seams
   FROM sales_attribution_log l
     JOIN sales_records sr ON sr.id = l.sales_record_id
  WHERE sr.output_batch_id IS NOT NULL
UNION ALL
 SELECT 'output'::text AS batch_kind,
    r.output_batch_id AS batch_id,
    r.created_at AS occurred_at,
    NULL::date AS business_date,
    'reservation'::text AS event_kind,
    'module.sales.view'::text AS module_code,
    r.created_by AS actor_id,
    'auth'::text AS actor_space,
    'sales_order_reservations'::text AS source_table,
    r.id AS source_id,
    NULL::text AS source_code,
    NULL::text AS href,
    jsonb_build_object('qty', r.qty, 'released', r.released_at IS NOT NULL, 'consumed', r.consumed_at IS NOT NULL, 'release_reason', r.release_reason) AS detail,
    ARRAY[]::text[] AS seams
   FROM sales_order_reservations r
  WHERE r.output_batch_id IS NOT NULL
UNION ALL
 SELECT 'output'::text AS batch_kind,
    sl.output_batch_id AS batch_id,
    sl.created_at AS occurred_at,
    s.ship_date AS business_date,
    'shipment'::text AS event_kind,
    'module.sales.view'::text AS module_code,
    s.created_by AS actor_id,
    'auth'::text AS actor_space,
    'shipment_lines'::text AS source_table,
    sl.id AS source_id,
    s.code AS source_code,
    NULL::text AS href,
    jsonb_build_object('qty', sl.qty, 'shipment_code', s.code) AS detail,
    ARRAY[]::text[] AS seams
   FROM shipment_lines sl
     JOIN shipments s ON s.id = sl.shipment_id
  WHERE sl.output_batch_id IS NOT NULL
UNION ALL
 SELECT
        CASE
            WHEN sl.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(sl.inbound_batch_id, sl.output_batch_id) AS batch_id,
    sl.counted_at AS occurred_at,
    NULL::date AS business_date,
    'stocktake_line'::text AS event_kind,
    'module.stocktakes.view'::text AS module_code,
    sl.created_by AS actor_id,
    'auth'::text AS actor_space,
    'stocktake_lines'::text AS source_table,
    sl.id AS source_id,
    st.code AS source_code,
    '/stocktakes/'::text || st.id AS href,
    jsonb_build_object('book_qty', sl.book_qty, 'counted_qty', sl.counted_qty, 'stocktake_code', st.code, 'stocktake_status', st.status) AS detail,
    ARRAY[]::text[] AS seams
   FROM stocktake_lines sl
     JOIN stocktakes st ON st.id = sl.stocktake_id
  WHERE COALESCE(sl.inbound_batch_id, sl.output_batch_id) IS NOT NULL
UNION ALL
 SELECT 'output'::text AS batch_kind,
    i.output_batch_id AS batch_id,
    i.issued_at AS occurred_at,
    NULL::date AS business_date,
    'report_issued'::text AS event_kind,
    'module.processing.view'::text AS module_code,
    i.issued_by AS actor_id,
    'auth'::text AS actor_space,
    'traceability_report_issues'::text AS source_table,
    i.id AS source_id,
    i.code AS source_code,
    ('/output/'::text || i.output_batch_id) || '/edit'::text AS href,
    jsonb_build_object('code', i.code, 'version', i.version, 'sha256', i.sha256) AS detail,
    ARRAY[]::text[] AS seams
   FROM traceability_report_issues i
UNION ALL
 SELECT b.batch_kind,
    b.batch_id,
    a.decided_at AS occurred_at,
    NULL::date AS business_date,
    'approval'::text AS event_kind,
        CASE a.subject_type
            WHEN 'purchase_order'::text THEN 'module.purchasing.view'::text
            ELSE '__no_policy__'::text
        END AS module_code,
    a.actor_user_id AS actor_id,
    'auth'::text AS actor_space,
    'approval_log'::text AS source_table,
    a.id AS source_id,
    a.subject_code AS source_code,
    NULL::text AS href,
    jsonb_build_object('subject_type', a.subject_type, 'decision', a.decision, 'level', a.level, 'note', a.note) AS detail,
    ARRAY[]::text[] ||
        CASE
            WHEN a.subject_type <> 'purchase_order'::text THEN ARRAY['no_policy_admits'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM approval_log a
     JOIN LATERAL ( SELECT 'inbound'::text AS batch_kind,
            ib.id AS batch_id
           FROM inbound_batches ib
          WHERE a.subject_type = 'purchase_order'::text AND ib.purchase_order_id = a.subject_id
        UNION
         SELECT 'inbound'::text AS text,
            pi2.inbound_batch_id
           FROM processing_runs r2
             JOIN processing_inputs pi2 ON pi2.run_id = r2.id
          WHERE a.subject_type = 'work_order'::text AND r2.work_order_id = a.subject_id AND pi2.inbound_batch_id IS NOT NULL) b ON true
UNION ALL
 SELECT
        CASE
            WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
    h.changed_at AS occurred_at,
    NULL::date AS business_date,
    'work_order_change'::text AS event_kind,
    'module.processing.view'::text AS module_code,
    h.changed_by AS actor_id,
    'auth'::text AS actor_space,
    'work_order_history'::text AS source_table,
    h.id AS source_id,
    NULL::text AS source_code,
    NULL::text AS href,
    jsonb_build_object('change_type', h.change_type, 'detail', h.detail, 'amend_reason', h.amend_reason) AS detail,
    ARRAY[]::text[] AS seams
   FROM work_order_history h
     JOIN processing_runs pr ON pr.work_order_id = h.work_order_id
     JOIN processing_inputs pi ON pi.run_id = pr.id
  WHERE COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL
UNION ALL
 SELECT 'inbound'::text AS batch_kind,
    ib.id AS batch_id,
    h.changed_at AS occurred_at,
    NULL::date AS business_date,
    'po_change'::text AS event_kind,
    'module.purchasing.view'::text AS module_code,
    h.changed_by AS actor_id,
    'auth'::text AS actor_space,
    'purchase_order_history'::text AS source_table,
    h.id AS source_id,
    NULL::text AS source_code,
    NULL::text AS href,
    jsonb_build_object('change_type', h.change_type, 'amend_reason', h.amend_reason) AS detail,
    ARRAY[]::text[] AS seams
   FROM purchase_order_history h
     JOIN inbound_batches ib ON ib.purchase_order_id = h.purchase_order_id
UNION ALL
 SELECT 'output'::text AS batch_kind,
    sr.output_batch_id AS batch_id,
    h.changed_at AS occurred_at,
    NULL::date AS business_date,
    'so_change'::text AS event_kind,
    'module.sales.view'::text AS module_code,
    h.changed_by AS actor_id,
    'auth'::text AS actor_space,
    'sales_order_history'::text AS source_table,
    h.id AS source_id,
    NULL::text AS source_code,
    NULL::text AS href,
    jsonb_build_object('change_type', h.change_type, 'detail', h.detail, 'amend_reason', h.amend_reason) AS detail,
    ARRAY[]::text[] AS seams
   FROM sales_order_history h
     JOIN sales_records sr ON sr.sales_order_line_id = h.sales_order_line_id
  WHERE sr.output_batch_id IS NOT NULL
UNION ALL
 SELECT r.batch_kind,
    r.batch_id,
    je.created_at AS occurred_at,
    je.entry_date AS business_date,
    'journal_entry'::text AS event_kind,
    'module.finance.view'::text AS module_code,
    je.created_by AS actor_id,
    'auth'::text AS actor_space,
    'journal_entries'::text AS source_table,
    je.id AS source_id,
    je.code AS source_code,
    '/finance/journal/'::text || je.id AS href,
    jsonb_build_object('code', je.code, 'memo', je.memo, 'status', je.status, 'source_type', je.source_type, 'reversed_by_code', ( SELECT j2.code
           FROM journal_entries j2
          WHERE j2.id = je.reversed_by)) AS detail,
    (ARRAY['polymorphic_source'::text] ||
        CASE
            WHEN je.status = 'reversed'::text THEN ARRAY['reversed'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN r.via_reversal THEN ARRAY['is_reversal'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM je_reach r
     JOIN journal_entries je ON je.id = r.je_id;

COMMENT ON VIEW public.batch_audit_trail_all IS
    'AUDIT-1:batch_audit_trail 的【无判据基视图】。20 支 UNION ALL,每支的 module_code 抄自那张源表【自己的 SELECT 策略】(R4:不新造第二套可见性)。【不授权给任何人】,靠够不着把关;对外读 batch_audit_trail。分录那一支跟 reversed_by 把冲销挂回同一个批次(3d),绝不解析 memo。';

-- ★【客户端读不到本视图】REVOKE —— 它不带判据,读得到它就等于绕过那道门 ★
-- 这一句【必须留在镜像里】,不能只留在迁移里:重建走的是镜像,而 Supabase 在
-- public 上的 DEFAULT PRIVILEGES 会给每一张新建关系自动带上 anon 与 authenticated
-- 的全部权限。少了它,**重建出来的库判据可以被绕过去,而线上不能** ——
-- 两边行为不同,fixture 183G 当场抓到过一次(先例写法:stock_class_violations_all)。
REVOKE ALL ON public.batch_audit_trail_all FROM authenticated, anon;
