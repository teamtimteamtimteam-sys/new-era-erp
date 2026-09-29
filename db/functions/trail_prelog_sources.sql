-- db/functions/trail_prelog_sources.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1):变更记录开始【之前】的历史从哪里拼回来 —— 每张表一行或几行。
--   kind = 'created':这一行本身就是一件事(领域历史表的一行、一次签发、一条授权、一张单据的创建)。
--        at_column / by_column 是它发生的时刻与做它的人;影像取这一行今天的值
--        (历史表只增不改,所以就是当时的值;单据本身则是今天的值 —— 分界线上的说明句替读者说清楚)。
--   kind = 'stamp':一对生命周期戳(关闭、删除、分摊、释放……)。只知道它【之后】是什么,不知道之前 ——
--        所以拼出来的是一次只有"新值"的改动,changed 列 = at/by + extra 列。
--   by_column 为 NULL:这张表当时没有记人 —— 界面说"Not recorded",不猜。
-- AUDIT-TRAIL-1b-1(M2):by_kind 说 by_column 里存的是【谁的 id】:
--   'account'  一个登录账号(auth.uid() 写的 —— 绝大多数);经 account_person() 认人。
--   'employee' 一个员工 id(current_user_employee() 写的:交接班的确认人;1b-3 的任务那一族全是这种)。
--   记成 account 的员工 id 会被当成一个找不到的账号,读成"Removed account" —— 那是一句错话,不是一次"不知道"。
-- 【绝不重复】(Q1)record_trail 只拼 at_column 早于 change_log_began_at() 的,并且 change_log 里已经记着
--   这一行的 INSERT(created)或这一戳的改动(stamp)时一律跳过 —— 同一件事不会出现两次。
-- 【为什么采购单的取消、批准不在 stamp 里】它们各有一行领域历史(purchase_order_history 'cancelled'、approval_log),
--   再拼一次戳就是两次。同理:工单的关闭 / 取消(work_order_history)、仓库申请与收货定价申请的决定(approval_log)
--   都不登记戳。
-- 【一个例外,Tim 的 Q11】盘点的 posted_at:22/09/2026 之前过账的盘点【只有】这一戳(那时过账还不写 approval_log)。
--   之后过账的同一笔事务里两边都有 —— 时刻相同,归成一条,界面把"过账"与"批准"并成一句(lib/trail/render.ts)。
CREATE OR REPLACE FUNCTION public.trail_prelog_sources()
 RETURNS TABLE(table_name text, kind text, at_column text, by_column text, extra text[], by_kind text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_orders',                'created', 'created_at',   'created_by',   NULL::text[], 'account'),
        ('purchase_orders',                'stamp',   'closed_at',    NULL,           ARRAY['status'], 'account'),
        ('purchase_orders',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason'], 'account'),
        ('purchase_order_lines',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('purchase_order_payment_terms',   'created', 'created_at',   NULL,           NULL, 'account'),
        ('purchase_order_payment_terms',   'stamp',   'expected_date_set_at', 'expected_date_set_by', ARRAY['expected_date'], 'account'),
        ('purchase_order_line_retentions', 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('purchase_order_line_retentions', 'stamp',   'released_at',  'released_by',  ARRAY['released_amount_ccy', 'withheld_amount_ccy', 'withholding_reason'], 'account'),
        ('pricing_term_commitments',       'created', 'committed_at', 'committed_by', NULL, 'account'),
        ('po_issues',                      'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('contract_document_terms',        'created', 'linked_at',    'linked_by',    NULL, 'account'),
        ('approval_log',                   'created', 'decided_at',   'actor_user_id', NULL, 'account'),
        ('purchase_order_history',         'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('processing_runs',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('processing_runs',                'stamp',   'allocated_at', 'allocated_by', ARRAY['allocation_basis', 'capitalized_cost_base', 'capitalization_entry_id'], 'account'),
        ('processing_runs',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['status', 'delete_reason'], 'account'),
        ('processing_inputs',              'created', 'created_at',   NULL,           NULL, 'account'),
        ('processing_outputs',             'created', 'created_at',   NULL,           NULL, 'account'),
        ('processing_cost_entry_history',  'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('batch_processing_cost_allocations', 'created', 'created_at', 'created_by',  NULL, 'account'),
        ('processing_run_losses',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('roles',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('roles',                          'stamp',   'deleted_at',   NULL,           ARRAY['is_active'], 'account'),
        ('role_permissions',               'created', 'created_at',   'created_by',   NULL, 'account'),
        -- ── 批次(1b-1)────────────────────────────────────────────────────────────────────────────────
        -- 时刻取建行的那一刻(created_at):同一笔事务写下的行 now() 相同,于是收货与它的入库流水归成一条
        ('inbound_batches',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('inbound_batches',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason'], 'account'),
        ('inbound_batches',                'stamp',   'import_permit_verified_at', 'import_permit_verified_by', ARRAY['import_permit_ref'], 'account'),
        ('inbound_batches',                'stamp',   'source_reason_recorded_at', 'source_reason_recorded_by', ARRAY['source_reason_code', 'source_reason_note'], 'account'),
        ('output_batches',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('output_batches',                 'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason'], 'account'),
        ('inbound_batch_metals',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('output_batch_metals',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('assay_results',                  'created', 'created_at',   'created_by',   NULL, 'account'),
        ('assay_results',                  'stamp',   'applied_at',   'applied_by',   NULL, 'account'),
        ('assay_results',                  'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('assay_result_metals',            'created', 'created_at',   NULL,           NULL, 'account'),
        ('inbound_batch_safety_states',    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('output_batch_safety_states',     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('price_history',                  'created', 'created_at',   'created_by',   NULL, 'account'),
        ('receipt_price_requests',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('receipt_price_requests',         'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('prepayment_applications',        'created', 'created_at',   'created_by',   NULL, 'account'),
        ('inventory_movements',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('stocktake_lines',                'created', 'counted_at',   'created_by',   NULL, 'account'),
        ('stocktake_counts',               'created', 'counted_at',   'counted_by',   NULL, 'account'),
        ('certificates_of_destruction',    'created', 'created_at',   'issued_by',    NULL, 'account'),
        ('certificates_of_destruction',    'stamp',   'voided_at',    'voided_by',    ARRAY['void_reason'], 'account'),
        ('cod_issues',                     'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('warehouse_requests',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('warehouse_requests',             'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('freight_allocations',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payment_allocations',            'created', 'created_at',   NULL,           NULL, 'account'),
        ('finance_attachments',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('finance_attachments',            'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('journal_entries',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_records',                  'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_record_movements',         'created', 'created_at',   NULL,           NULL, 'account'),
        ('sales_attribution_log',          'created', 'attributed_at', 'attributed_by', NULL, 'account'),
        ('invoice_lines',                  'created', 'created_at',   NULL,           NULL, 'account'),
        ('sales_order_reservations',       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_order_reservations',       'stamp',   'released_at',  'released_by',  ARRAY['release_reason'], 'account'),
        ('sales_order_reservations',       'stamp',   'consumed_at',  'consumed_by',  NULL, 'account'),
        ('shipment_lines',                 'created', 'created_at',   NULL,           NULL, 'account'),
        ('traceability_report_issues',     'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('sales_settlements',              'created', 'computed_at',  'computed_by',  NULL, 'account'),
        ('sales_order_history',            'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('work_order_history',             'created', 'changed_at',   'changed_by',   NULL, 'account'),
        -- ── 工单 · 盘点(1b-1)──────────────────────────────────────────────────────────────────────────
        ('work_orders',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('work_order_lines',               'created', 'created_at',   NULL,           NULL, 'account'),
        ('work_order_expected_outputs',    'created', 'created_at',   NULL,           NULL, 'account'),
        ('stocktakes',                     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('stocktakes',                     'stamp',   'cancelled_at', 'cancelled_by', ARRAY['status', 'cancel_reason'], 'account'),
        ('stocktakes',                     'stamp',   'posted_at',    NULL,           ARRAY['status'], 'account'),
        -- ── 设备 · 交接班(1b-1)────────────────────────────────────────────────────────────────────────
        ('fixed_assets',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('equipment_maintenance',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('equipment_downtime',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('equipment_downtime',             'stamp',   'ended_at',     NULL,           NULL, 'account'),
        ('equipment_service_intervals',    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shift_handovers',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shift_handovers',                'stamp',   'acknowledged_at', 'acknowledged_by', NULL, 'employee'),
        ('shift_handover_items',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shift_handover_equipment_refs',  'created', 'created_at',   'created_by',   NULL, 'account'),
        -- ── AUDIT-TRAIL-1b-2 · 商务 ────────────────────────────────────────────────────────────────────
        -- 报价 / 订单:单据的建单那一刻【与】它事件史的 created 行都登记 —— 两者是同一笔事务写的(实测 created_at =
        --   changed_at,逐条),于是归成一条,界面把两者并成一句(lib/trail/render.ts);没有事件史的那两张测试订单
        --   (ZZ2B-SO1/2)因此也有一条"建单"。签发档(qt_issues · so_issues)【不登记】:事件史的 issued 已经记着(Step 0
        --   §a,Tim 的裁定)。订单的 confirmed / closed / cancelled 戳【不登记】:事件史里都有。
        --   预留的三个戳(建 · 放回 · 用掉)1b-1 已为批次页登记;在订单页上它们与事件史的 reserved / released / shipped
        --   是同一笔事务、同一时刻(实测),归成一条,界面并成一句。
        ('quotes',                         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('quote_lines',                    'created', 'created_at',   NULL,           NULL, 'account'),
        ('quote_history',                  'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('sales_orders',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_order_lines',              'created', 'created_at',   NULL,           NULL, 'account'),
        ('shipping_releases',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shipping_releases',              'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('shipping_release_lines',         'created', 'created_at',   NULL,           NULL, 'account'),
        ('shipments',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shipment_issues',                'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('customers',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('counterparty_contacts',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('counterparty_contacts',          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('customer_attachments',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('customer_attachments',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('customer_credit_history',        'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('customer_statements',            'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('customer_statements',            'stamp',   'superseded_at', NULL,          ARRAY['superseded_reason', 'superseded_by'], 'account'),
        ('statement_issues',               'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('collection_chases',              'created', 'created_at',   'chased_by',    NULL, 'account'),
        ('collection_chases',              'stamp',   'superseded_at', NULL,          ARRAY['superseded_reason', 'superseded_by'], 'account'),
        ('collection_chase_documents',     'created', 'created_at',   NULL,           NULL, 'account'),
        ('collection_promises',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('collection_promises',            'stamp',   'outcome_recorded_at', 'outcome_recorded_by', ARRAY['outcome', 'outcome_note'], 'account'),
        ('commission_agreements',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('commission_agreements',          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- 供应商:批准那一戳登记 —— supplier_status_history 与 approval_log 的供应商那一支都是 24/09 才有的(ROLE-1 Batch 2a),
        --   而在那之前批准过的供应商只剩这一戳;之后批准的,同一笔事务里三边同一时刻,归成一条,审批并进状态那一句。
        ('suppliers',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('suppliers',                      'stamp',   'approved_at',  'approved_by',  NULL, 'account'),
        ('supplier_compliance',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('supplier_compliance',            'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('supplier_attachments',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('supplier_attachments',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('supplier_status_history',        'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('containers',                     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('container_milestones',           'created', 'recorded_at',  'recorded_by',  NULL, 'account'),
        ('container_documents',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('forwarder_details',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('forwarder_rate_quotes',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('forwarder_rate_quotes',          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('lanes',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('lanes',                          'stamp',   'checklist_reviewed_at', NULL,  NULL, 'account'),
        ('lanes',                          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('lane_document_requirements',     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('lane_document_requirements',     'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('ports',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('ports',                          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('company_compliance',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('company_compliance',             'stamp',   'deleted_at',   NULL,           NULL, 'account')
    ) AS p(table_name, kind, at_column, by_column, extra, by_kind);
$function$;
