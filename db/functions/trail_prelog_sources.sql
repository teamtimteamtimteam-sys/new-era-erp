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
        ('company_compliance',             'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- ── AUDIT-TRAIL-1b-3 · 主数据与工具 ────────────────────────────────────────────────────────────
        -- 物料、库位、金属价格:没有历史表,只有建行那一刻与删除那一戳(这几张表从来没有记过【谁】删的 —— by 为 NULL,
        --   界面说 "Not recorded",横幅只说日期,Q8)
        ('materials',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('materials',                      'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('material_attachments',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('material_attachments',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('material_required_metals',       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('storage_locations',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('storage_location_allowed_classes', 'created', 'created_at', 'created_by',   NULL, 'account'),
        ('metal_prices',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('metal_prices',                   'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- 公式:修改史(create / update / delete / restore / metal_set / metal_clear)是主线。公式本身的建行那一刻与它的应付金属
        --   【也】登记 —— 与 1b-2 的报价 / 订单同一个做法:修改史由 AFTER 触发器在同一笔事务里写,时刻相同,归成一条,界面并成
        --   一句(lib/trail/render.ts);而线上那一张公式早于修改史(修改史 0 行),不登记它就一条"建立"都没有。
        --   删除那一戳【不】登记:修改史的 delete 记着。
        ('pricing_formulas',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('pricing_formula_metals',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('pricing_formula_history',        'created', 'changed_at',   'changed_by',   NULL, 'account'),
        -- 条款申请:提出 · 撤回;决定由审批留痕说(approval_log 已登记,decided_at 那一戳不再登记)
        ('terms_requests',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('terms_requests',                 'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        -- 任务(M2:步骤与修改史里的人是【员工 id】):修改史只在团队任务上写(私人任务一行都不写,trg_tasks_history),
        --   所以私人任务"记录开始之前"那一段只能来自建行与戳 —— 任务的建立与删除、步骤的建立与打勾。
        --   团队任务上同一件事两边都有(步骤加上 = node_added,打勾 = node_done):同一笔事务、同一时刻,归成一条,
        --   界面按步骤认,只说一次(fixture 240 的 N 臂)。参与者【不】登记:每一次进出修改史都记着,
        --   唯一不记的是归属人自己那头一行 —— 那是有意的("变更记录记的是改动,不是初始状态")。
        ('tasks',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('tasks',                          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('task_nodes',                     'created', 'created_at',   'created_by',   NULL, 'employee'),
        ('task_nodes',                     'stamp',   'done_at',      'done_by',      ARRAY['done'], 'employee'),
        ('task_history',                   'created', 'changed_at',   'changed_by',   NULL, 'employee'),
        -- AUDIT-TRAIL-1c-1:账上的单据。★ Q9(Tim 2026-10-03):下面三个戳是那几件事【唯一】的记录,按 Q11 的例外登记 ——
        --   invoices.voided_at(线上三次作废都早于发票申请,没有申请、没有审批留痕)· payment_requests.paid_at(没有任何
        --   历史表记"付了")· expense_claims.decided_at(线上两张已决定的报销单,approval_log 里一行 expense_claim 都没有)。
        --   之后有审批留痕的那几次,两边同一笔事务、同一刻,归成一条,界面把审批并进那一句(render.ts 的 foldApprovals)。
        --   申请的决定(decided_at)其余一律【不】登记 —— approval_log 记着它,再拼一次戳就是两次。
        ('journal_lines',                  'created', 'created_at',   NULL,           NULL, 'account'),
        ('journal_requests',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('journal_requests',               'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('invoices',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('invoices',                       'stamp',   'voided_at',    'voided_by',    ARRAY['status', 'void_reason'], 'account'),
        ('invoice_issues',                 'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('invoice_requests',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('invoice_requests',               'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('credit_notes',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('credit_note_lines',              'created', 'created_at',   NULL,           NULL, 'account'),
        ('cn_issues',                      'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('payments',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payment_requests',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payment_requests',               'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status'], 'account'),
        ('payment_requests',               'stamp',   'paid_at',      'paid_by',      ARRAY['status', 'result_payment_id', 'result_transfer_id', 'result_journal_entry_id'], 'account'),
        ('bank_transfers',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_transfers',                 'stamp',   'reversed_at',  'reversed_by',  ARRAY['reversal_entry_id'], 'account'),
        ('wht_remittances',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('expenses',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('expense_claims',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('expense_claims',                 'stamp',   'decided_at',   'decided_by',   ARRAY['status', 'decision_notes', 'expense_id'], 'account'),
        ('expense_claims',                 'stamp',   'withdrawn_at', NULL,           ARRAY['status'], 'account'),
        ('fixed_asset_cost_entries',       'created', 'created_at',   'created_by',   NULL, 'account'),
        -- AUDIT-TRAIL-1c-2:其余的单据与合同。★ Q9(Tim 2026-10-03)的另外两个戳在这一刀登记 ——
        --   freight_documents.reversed_at(线上 4 张运费单全部冲销过,那是那件事唯一的记录)· bank_statements.reconciled_at
        --   (BS-2026-0002 对过账,却没有一行 bank_reconciliations —— 只有这一戳)。有对账记录的那几次,两边同一笔、同一刻
        --   (reconciled_at),归成一条,界面只说一次。
        --   修改史是主线的两张(fixed_asset_history、fx_rate_history):一件事两行(1b-3 的规矩)—— 记录开始之后变更记录那一行说,
        --   之前修改史那一行说;资产卡与汇率自己的建行那一刻【也】登记,同一笔、同一刻,界面并成一句(报价 / 订单的先例)。
        --   撤回汇率那一下【不】登记成戳(fx_rates 没有 deleted_by;withdraw_fx_rate 在同一笔里写一行 'withdrawn' 修改史,
        --   那一行就是这件事的记录 —— 再拼一次戳就是两次)。
        ('freight_documents',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('freight_documents',              'stamp',   'reversed_at',  'reversed_by',  ARRAY['status', 'reversal_reason', 'reversal_entry_id'], 'account'),
        ('fixed_asset_history',            'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('fixed_asset_depreciation',       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('fixed_asset_depreciation_anchors', 'created', 'created_at', 'created_by',   NULL, 'account'),
        ('asset_disposal_requests',        'created', 'created_at',   'created_by',   NULL, 'account'),
        ('asset_disposal_requests',        'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('bank_statements',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_statements',                'stamp',   'reconciled_at', 'reconciled_by', ARRAY['status'], 'account'),
        ('bank_statements',                'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('bank_statement_lines',           'created', 'created_at',   NULL,           NULL, 'account'),
        ('bank_line_matches',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_reconciliations',           'created', 'reconciled_at', 'reconciled_by', NULL, 'account'),
        ('bank_reconciliations',           'stamp',   'superseded_at', NULL,          ARRAY['superseded_reason'], 'account'),
        ('bank_reconciliation_variance_items', 'created', 'created_at', 'created_by', NULL, 'account'),
        ('gst_periods',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('gst_periods',                    'stamp',   'filed_at',     'filed_by',     ARRAY['status', 'filed_on', 'filed_reference'], 'account'),
        ('gst_return_boxes',               'created', 'created_at',   NULL,           NULL, 'account'),
        ('gst_filing_requests',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('gst_filing_requests',            'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('fx_rates',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('fx_rate_history',                'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('management_packs',               'created', 'produced_at',  'produced_by',  NULL, 'account'),
        ('management_packs',               'stamp',   'superseded_at', NULL,          ARRAY['superseded_by', 'superseded_reason'], 'account'),
        ('contracts',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_grade_specs',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_insurance_obligations', 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_volume_commitments',    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_pricing_terms',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_settlement_terms',      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_refining_charges',      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_penalty_elements',      'created', 'created_at',   'created_by',   NULL, 'account'),
        -- AUDIT-TRAIL-1c-3:期末、设置与清单页上的记录。
        --   ★ finance_settings 与 company_profile【什么都不登记】:它们只有一对整行共用的 updated_at / updated_by,
        --     说不出改的是哪一块面板的哪一列(Step 0 §c)—— 记录开始之前没有任何一条"谁注册了 GST、何时"的记录,照直不说。
        --   锁期面板记录开始之前的内容就是 period_closes:关账的那一刻(created)与反结的那一戳(stamp)。
        --   年结同形;现金预测:冻结那一刻 + 被取代那一戳(superseded_by 是【一张预测的 id】,不是人 —— 所以戳上不记人);
        --   导入模板:建立 + 删除那一戳(表里没有 deleted_by)。报销单、人工分录申请、转账、缴纳在 1c-1 已经登记。
        ('period_closes',                  'created', 'closed_at',    'closed_by',    NULL, 'account'),
        ('period_closes',                  'stamp',   'reopened_at',  'reopened_by',  ARRAY['reopen_reason'], 'account'),
        ('year_closes',                    'created', 'closed_at',    'closed_by',    NULL, 'account'),
        ('year_closes',                    'stamp',   'reopened_at',  'reopened_by',  ARRAY['reopen_reason', 'reversal_journal_id'], 'account'),
        ('cash_forecasts',                 'created', 'frozen_at',    'frozen_by',    NULL, 'account'),
        ('cash_forecasts',                 'stamp',   'superseded_at', NULL,          ARRAY['superseded_by', 'superseded_reason'], 'account'),
        ('cash_forecast_lines',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_import_profiles',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_import_profiles',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q12):这几样是那几件事【唯一】的记录,按 Q11 / 1c Q9 的例外登记 ——
        --   账号的建立(auth.users.created_at;没有记人 —— "Not recorded")· 授权与收回(user_roles 的两对戳:线上 9 次授予、
        --   2 次收回全在记录开始之前)· 附加账号的挂接(employee_accounts 与它的挂接史:同一笔、同一刻,界面说一次)·
        --   审批方针的修改史(22/09/2026 那一次开审批)· 导入批次。
        --   员工:建立 + 删除那一戳(表里没有 deleted_by)+ 匿名化那一戳;任职履历:每一行就是一件事。★ 薪资执行写的那一行
        --   created_by 记的是【提出申请的人】,不是批准执行的人(salary_change_execute_internal,Q31)—— 线上记录开始之前
        --   一行这种都没有(调薪申请 0 行);之后那一刻的"谁"由变更记录说(批准的人)。
        --   调薪申请:提出 + 撤回;决定由审批留痕说(decided_at / executed_at 不登记)。部门、培训记录:建立 + 删除那一戳。
        ('auth.users',                     'created', 'created_at',   NULL,           NULL, 'account'),
        ('user_roles',                     'created', 'granted_at',   'granted_by',   NULL, 'account'),
        ('user_roles',                     'stamp',   'revoked_at',   'revoked_by',   ARRAY['revoke_reason'], 'account'),
        ('employee_accounts',              'created', 'linked_at',    'linked_by',    NULL, 'account'),
        ('employee_account_history',       'created', 'changed_at',   'actor_user_id', NULL, 'account'),
        ('finance_settings_history',       'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('import_batches',                 'created', 'imported_at',  'imported_by',  NULL, 'account'),
        ('employees',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('employees',                      'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('employees',                      'stamp',   'anonymised_at', 'anonymised_by', NULL, 'account'),
        ('employment_history',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('salary_change_requests',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('salary_change_requests',         'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('departments',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('departments',                    'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('training_records',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('training_records',               'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 的 Q12):请假与考勤。这几样戳是那几件事【唯一】的记录(Q11 / 1c Q9 的例外):
        --   · 请假的 decided_at / decided_by —— 取消【改写】同一对戳(cancel_leave_request),所以线上两次本人取消只剩它;
        --     批准 / 驳回时审批留痕同一笔、同一刻写下,两行归成一条,界面按【状态】说一次(status 在 extra 里)。
        --   · 加班的冲销与丢弃(reversed_* · discarded_*):送审与决定在审批留痕里,不登记 decided_*(重新送审会把它清掉)。
        --     行的 voided_at 与冲销 / 丢弃同一笔、同一刻 —— 并进那一句;那张表没有记人。
        --   · 考勤的 completed_* 与 reopened_*:重开清掉完成那一对、覆盖上一次重开 —— 只剩【最近】那一次,界面照直说。
        --     行的 recorded_* 与 frozen_at(冻结没有记人,与完成同一刻)。
        --   · 医疗报销的 withdrawn_at:撤回【没有】记人(withdraw_medical_claim 只写 updated_by —— 不拿它猜,界面说 "Not recorded")。
        --     批准 / 驳回由审批留痕说(decided_at 与它同一刻,不再登记)。
        --   · 假别与公共假期:建立那一刻(都由迁移种下,没有记人);之后的改动只有共用的 updated_*,说不出改了哪一列。
        ('leave_requests',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('leave_requests',                 'stamp',   'decided_at',   'decided_by',   ARRAY['status', 'decision_notes'], 'account'),
        ('leave_consumption',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('leave_grants',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('leave_grants',                   'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('leave_types',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('public_holidays',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('medical_claims',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('medical_claims',                 'stamp',   'withdrawn_at', NULL,           ARRAY['status'], 'account'),
        ('overtime_batches',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('overtime_batches',               'stamp',   'reversed_at',  'reversed_by',  ARRAY['status', 'reverse_reason'], 'account'),
        ('overtime_batches',               'stamp',   'discarded_at', 'discarded_by', ARRAY['status'], 'account'),
        ('overtime_lines',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('overtime_lines',                 'stamp',   'voided_at',    NULL,           NULL, 'account'),
        ('attendance_periods',             'created', 'opened_at',    'opened_by',    NULL, 'account'),
        ('attendance_periods',             'stamp',   'completed_at', 'completed_by', ARRAY['status'], 'account'),
        ('attendance_periods',             'stamp',   'reopened_at',  'reopened_by',  ARRAY['reopen_reason'], 'account'),
        ('attendance_lines',               'stamp',   'recorded_at',  'recorded_by',  ARRAY['note'], 'account'),
        ('attendance_lines',               'stamp',   'frozen_at',    NULL,           NULL, 'account'),
        -- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 的 Q12):工资与评审。Step 0 交给这一刀的两个戳 —— 那件事【唯一】的记录:
        --   · 工资申请的 withdrawn_at / withdrawn_by —— 撤回不写审批留痕(withdraw_payroll_request),它是唯一的记录;
        --     送审 · 批准 · 驳回在审批留痕里(不登记 decided_*);执行(executed_*)与过账 / 撤销的分录同一笔、同一刻 —— 分录的建立说它。
        --   · 评审的 voided_at / voided_by —— 作废不写审批留痕(void_review),理由一并取(void_reason)。
        --     送审 · 批准 · 本人确认在审批留痕里(不登记 submitted_* / approved_* / acknowledged_at)。
        --   另外是几张表的建立:工资期(与它的工资行同一笔、同一刻 —— 归成一条)· 工资行(没有 created_by:"Not recorded";
        --     每次保存删了重插,所以它的建立是【最近一次】保存)· 申请 · 评审 · 目标 · 轮次 · 评分刻度 · KPI 条目。
        --   ★ 本刀自己多登记了一个(交回报告的自决事项):KPI 的 scored_at / scored_by —— 打分只写那一行(score_kpi_entry),
        --     不写任何留痕,再打一次会覆盖它;之前那一段里它是那一次打分唯一的记录(与 Q12 同一条理由)。
        --   ★ 没有登记:工资行的 paid_at(与发薪分录同一笔、同一刻 —— 发薪那一句由分录的建立说)· 评审的
        --     self_assessment_submitted_at(重开会把它清掉,而且它没有记人)。
        ('payroll_periods',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payroll_lines',                  'created', 'created_at',   NULL,           NULL, 'account'),
        ('payroll_requests',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payroll_requests',               'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status'], 'account'),
        ('performance_reviews',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('performance_reviews',            'stamp',   'voided_at',    'voided_by',    ARRAY['status', 'void_reason'], 'account'),
        ('review_goals',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('review_cycles',                  'created', 'created_at',   'created_by',   NULL, 'account'),
        ('review_rating_scale',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('kpi_entries',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('kpi_entries',                    'stamp',   'scored_at',    'scored_by',    ARRAY['score', 'score_kind'], 'account')
    ) AS p(table_name, kind, at_column, by_column, extra, by_kind);
$function$;
