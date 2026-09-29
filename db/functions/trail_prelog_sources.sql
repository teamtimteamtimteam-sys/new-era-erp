-- db/functions/trail_prelog_sources.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1):变更记录开始【之前】的历史从哪里拼回来 —— 每张表一行或几行。
--   kind = 'created':这一行本身就是一件事(领域历史表的一行、一次签发、一条授权、一张单据的创建)。
--        at_column / by_column 是它发生的时刻与做它的账号;影像取这一行今天的值
--        (历史表只增不改,所以就是当时的值;单据本身则是今天的值 —— 分界线上的说明句替读者说清楚)。
--   kind = 'stamp':一对生命周期戳(关闭、删除、分摊、释放……)。只知道它【之后】是什么,不知道之前 ——
--        所以拼出来的是一次只有"新值"的改动,changed 列 = at/by + extra 列。
--   by_column 为 NULL:这张表当时没有记人 —— 界面说"Not recorded",不猜。
-- 【绝不重复】(Q1)record_trail 只拼 at_column 早于 change_log_began_at() 的,并且 change_log 里已经记着
--   这一行的 INSERT(created)或这一戳的改动(stamp)时一律跳过 —— 同一件事不会出现两次。
-- 【为什么采购单的取消、批准不在 stamp 里】它们各有一行领域历史(purchase_order_history 'cancelled'、approval_log),
--   再拼一次戳就是两次。
CREATE OR REPLACE FUNCTION public.trail_prelog_sources()
 RETURNS TABLE(table_name text, kind text, at_column text, by_column text, extra text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_orders',                'created', 'created_at',   'created_by',   NULL::text[]),
        ('purchase_orders',                'stamp',   'closed_at',    NULL,           ARRAY['status']),
        ('purchase_orders',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason']),
        ('purchase_order_lines',           'created', 'created_at',   'created_by',   NULL),
        ('purchase_order_payment_terms',   'created', 'created_at',   NULL,           NULL),
        ('purchase_order_payment_terms',   'stamp',   'expected_date_set_at', 'expected_date_set_by', ARRAY['expected_date']),
        ('purchase_order_line_retentions', 'created', 'created_at',   'created_by',   NULL),
        ('purchase_order_line_retentions', 'stamp',   'released_at',  'released_by',  ARRAY['released_amount_ccy', 'withheld_amount_ccy', 'withholding_reason']),
        ('pricing_term_commitments',       'created', 'committed_at', 'committed_by', NULL),
        ('po_issues',                      'created', 'issued_at',    'issued_by',    NULL),
        ('contract_document_terms',        'created', 'linked_at',    'linked_by',    NULL),
        ('approval_log',                   'created', 'decided_at',   'actor_user_id', NULL),
        ('purchase_order_history',         'created', 'changed_at',   'changed_by',   NULL),
        ('processing_runs',                'created', 'created_at',   'created_by',   NULL),
        ('processing_runs',                'stamp',   'allocated_at', 'allocated_by', ARRAY['allocation_basis', 'capitalized_cost_base', 'capitalization_entry_id']),
        ('processing_runs',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['status', 'delete_reason']),
        ('processing_inputs',              'created', 'created_at',   NULL,           NULL),
        ('processing_outputs',             'created', 'created_at',   NULL,           NULL),
        ('processing_cost_entry_history',  'created', 'changed_at',   'changed_by',   NULL),
        ('batch_processing_cost_allocations', 'created', 'created_at', 'created_by',  NULL),
        ('processing_run_losses',          'created', 'created_at',   'created_by',   NULL),
        ('roles',                          'created', 'created_at',   'created_by',   NULL),
        ('roles',                          'stamp',   'deleted_at',   NULL,           ARRAY['is_active']),
        ('role_permissions',               'created', 'created_at',   'created_by',   NULL)
    ) AS p(table_name, kind, at_column, by_column, extra);
$function$;
