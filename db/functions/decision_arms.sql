-- db/functions/decision_arms.sql
-- SYSTEM-MAP-2(Tim 2026-10-27 Q3):提醒页的哪一支是一种【审批】,是哪一种(waiting_decisions 的 item_type)。
--   是审批的那几支,operations_now 只留读者此刻批得了的那几行(与待办同一支 waiting_decisions);别的支(到期、逾期、低库存……)
--   照旧按读码给全公司看(Tim 2.4 (11))。
--   第二列 parent_keyed:那一支的 item_id 是单据所在的那一页的主体(工资期 · 收货批 · 发票 · 销售单 · 员工 · GST 期),
--   不是申请本身 —— 那几支按 (parent_id, 标签) 对上 waiting_decisions 的那一行。门户证书那一支的 item_id 是那家供应商
--   (提交住在供应商档案页上),标签是证书号(没有就是种类码)。
--   ★ 不在这里:stocktake_open(Tim Q4 a,盘点留在提醒页)· ncr_open(那一支说的是"一批被扣着",一个例外,不是一次待办;
--     不合格报告的决定在待办上)· shipping_release_ready(已放行、等仓库发货,不是一个审批)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.decision_arms()
 RETURNS TABLE(arm text, decision_type text, parent_keyed boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT v.a, v.d, v.p
      FROM (VALUES
        ('leave_pending',                   'leave_request',          false),
        ('claim_pending',                   'medical_claim',          false),
        ('review_submitted',                'performance_review',     false),
        ('capture_draft_pending',           'capture_draft',          false),
        ('payment_request_pending',         'payment_request',        false),
        ('supplier_pending_approval',       'supplier',               false),
        ('payroll_request_pending',         'payroll_request',        true),
        ('receipt_price_request_pending',   'receipt_price_request',  true),
        ('invoice_request_pending',         'invoice_request',        true),
        ('shipping_release_pending',        'shipping_release',       true),
        ('journal_request_pending',         'journal_request',        false),
        ('warehouse_request_pending',       'warehouse_request',      false),
        ('terms_request_pending',           'terms_request',          false),
        ('asset_disposal_pending',          'asset_disposal_request', false),
        ('salary_change_pending',           'salary_change_request',  true),
        ('gst_filing_pending',              'gst_filing_request',     true),
        ('expense_claim_pending',           'expense_claim',          false),
        ('purchase_order_approval_pending', 'purchase_order',         false),
        ('overtime_batch_pending',          'overtime_batch',         false),
        ('work_order_release_pending',      'work_order',             false),
        ('blending_plan_release_pending',   'blending_plan',          false),
        ('portal_certificate_pending',      'portal_certificate',     true)
      ) v(a, d, p)
$function$;

COMMENT ON FUNCTION public.decision_arms() IS
'SYSTEM-MAP-2(Tim Q3):提醒页的审批支 → waiting_decisions 的种类(两个读者:operations_now · 提醒页);parent_keyed = 那一支的 item_id 是单据所在页的主体,按 (parent_id, 标签) 对行。不在表里的支(盘点 · ncr_open · 已放行等发货 · 一切例外支)不按读者逐行过滤。';
