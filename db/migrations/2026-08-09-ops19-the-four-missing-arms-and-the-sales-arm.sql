-- OPS-19:operations_now 补上原始定稿里漏掉的四支,外加 sales 真正够得着的那一支
--
-- 【为什么会漏】Phase 6 的定稿【只存在于一次对话里】,没有落进仓库 —— 与三份规划
-- 文档不在仓库里是同一个缺陷,代价是四支。本次连同修法一起补:支的清单现在写在
-- docs/dashboard-arm-inventory.md,加支【必须】在同一个提交里加一行。那份文件是规格,
-- 本文件只是它的实现。
--
-- 补的四支(定稿点名):
--   awaiting_assay   —— 批次【一份化验都没有】(assay_count = 0)。与 assay_unapplied
--                       【不是同一件事】:那支是"化验录了、还没执行"。两支互斥,
--                       同出 batch_assay_status。
--   batch_unpriced   —— pricing_status = 'unpriced'。一个未计价的批次 = 尚未确认的钱。
--   invoice_overdue  —— invoice_status.overdue(过了 due_date 且仍有未结额)。
--   ar_over_90 / ap_over_90 —— 账龄最老的那一档(bucket = 'b90_plus'),两侧各一支。
--                       拆成两支而不是合并:催客户与付供应商是两拨人的两件事。
--
-- 【顺带改了一支的粒度,明写在此】assay_unapplied 原先直接读 assay_results,一份
-- 未执行化验一行;现在与 awaiting_assay 同源读 batch_assay_status,【一个批次一行】。
-- 两支因此同粒度、可比、互斥。live 当前该支为 0,所以这次改动【不改变任何现有数字】。
--
-- 【新增 output_unsold_aging —— 为了 sales 这一行】OPS-18 的读者侧表暴露出:sales 持
-- 五个模块却一块牌子都没有,整页「受限」。当时猜的 AR/发票支【是错的】—— sales 没有
-- module.finance.view,那支对它同样是「受限」。真正够得着的是 module.output.view:
-- 成品压在手里卖不掉,本来就是销售的活。
-- 【60 天是提议,不是决定】证据、四档阈值的命中率、以及"全都告警等于没有告警"的
-- 反证都写在 docs/dashboard-arm-inventory.md;改它是一行迁移。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

CREATE OR REPLACE VIEW public.operations_now WITH (security_invoker = off) AS
SELECT a.item_type,
       a.permission,
       a.item_code,
       a.subject,
       a.item_date,
       (CURRENT_DATE - a.item_date) AS days_waiting
FROM (
    -- ══ 进料(module.inbound.view)—— 三支同出 batch_assay_status,互斥 ══════════
    -- 【为什么 JOIN inbound_batches】batch_assay_status 不带日期列,而每支都要一个
    -- item_date 去算 days_waiting。取的只是日期,不是金额 —— 与 cash_flow 用
    -- accounts.is_cash 挑行同一个性质:目录查询,不是重新推导。
    SELECT 'awaiting_assay'::text AS item_type,
           'module.inbound.view'::text AS permission,
           b.batch_code AS item_code,
           b.supplier_name AS subject,
           COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
      FROM batch_assay_status b
      JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
     WHERE b.assay_count = 0
    UNION ALL
    SELECT 'assay_unapplied'::text AS item_type,
           'module.inbound.view'::text AS permission,
           b.batch_code AS item_code,
           b.latest_assay_code AS subject,
           COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
      FROM batch_assay_status b
      JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
     WHERE b.has_unapplied_assay
    UNION ALL
    SELECT 'batch_unpriced'::text AS item_type,
           'module.inbound.view'::text AS permission,
           b.batch_code AS item_code,
           b.supplier_name AS subject,
           COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
      FROM batch_assay_status b
      JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
     WHERE b.pricing_status = 'unpriced'
    UNION ALL
    -- ══ 加工 ══════════════════════════════════════════════════════════════════
    SELECT 'allocation_stale'::text AS item_type,
           'module.processing.view'::text AS permission,
           s.code AS item_code,
           NULL::text AS subject,
           s.last_cost_change::date AS item_date
      FROM processing_run_allocation_status s
     WHERE s.is_stale OR (s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL)
    UNION ALL
    -- ══ 采购 ══════════════════════════════════════════════════════════════════
    SELECT 'po_awaiting_receipt'::text AS item_type,
           'module.purchasing.view'::text AS permission,
           po.code AS item_code,
           po.status AS subject,
           po.order_date AS item_date
      FROM purchase_orders po
     WHERE po.deleted_at IS NULL AND po.status IN ('confirmed', 'receiving')
    UNION ALL
    -- ══ 盘点 ══════════════════════════════════════════════════════════════════
    SELECT 'stocktake_open'::text AS item_type,
           'module.stocktakes.view'::text AS permission,
           st.code AS item_code,
           NULL::text AS subject,
           st.started_at::date AS item_date
      FROM stocktakes st
     WHERE st.deleted_at IS NULL AND st.status = 'open'
    UNION ALL
    -- ══ 产出:压在手里卖不掉的成品(sales 这一行唯一够得着的支)════════════════
    -- 60 天是【提议】—— 阈值就是这一支本身,证据见 docs/dashboard-arm-inventory.md。
    SELECT 'output_unsold_aging'::text AS item_type,
           'module.output.view'::text AS permission,
           ob.code AS item_code,
           ob.state AS subject,
           COALESCE(ob.output_date, ob.created_at::date) AS item_date
      FROM output_batches ob
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0
       AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
    UNION ALL
    -- ══ HR 三支 ═══════════════════════════════════════════════════════════════
    SELECT 'leave_pending'::text AS item_type,
           'module.hr.view'::text AS permission,
           lr.code AS item_code,
           e.legal_name AS subject,
           lr.created_at::date AS item_date
      FROM leave_requests lr
      JOIN employees e ON e.id = lr.employee_id
     WHERE lr.status = 'pending' AND lr.deleted_at IS NULL
    UNION ALL
    SELECT 'claim_pending'::text AS item_type,
           'module.hr.view'::text AS permission,
           mc.code AS item_code,
           e.legal_name AS subject,
           mc.created_at::date AS item_date
      FROM medical_claims mc
      JOIN employees e ON e.id = mc.employee_id
     WHERE mc.status = 'submitted' AND mc.deleted_at IS NULL
    UNION ALL
    SELECT 'review_submitted'::text AS item_type,
           'module.hr.view'::text AS permission,
           e.code AS item_code,
           e.legal_name AS subject,
           COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
      FROM performance_reviews r
      JOIN employees e ON e.id = r.employee_id
     WHERE r.status = 'submitted'
    UNION ALL
    -- ══ 财务四支 ══════════════════════════════════════════════════════════════
    -- 【三支的存在性挂在被 data.view_prices 遮蔽的列上】—— 只有 module.finance.view
    -- 而没有 data.view_prices 的读者会【少报】而不是显示「受限」。live 上任何持
    -- finance 的角色都同时持 prices(常设决定 1),故当前不可达;隐患与"为什么不能
    -- 简单地把 permission 改成 data.view_prices"记在 docs/dashboard-arm-inventory.md。
    SELECT 'invoice_overdue'::text AS item_type,
           'module.finance.view'::text AS permission,
           i.code AS item_code,
           i.customer_name AS subject,
           i.due_date AS item_date
      FROM invoice_status i
     WHERE i.overdue
    UNION ALL
    SELECT 'ar_over_90'::text AS item_type,
           'module.finance.view'::text AS permission,
           ar.doc_code AS item_code,
           ar.customer_name AS subject,
           ar.sale_date AS item_date
      FROM ar_open_items ar
     WHERE ar.bucket = 'b90_plus'
    UNION ALL
    SELECT 'ap_over_90'::text AS item_type,
           'module.finance.view'::text AS permission,
           ap.doc_code AS item_code,
           ap.supplier_name AS subject,
           ap.doc_date AS item_date
      FROM ap_open_items ap
     WHERE ap.bucket = 'b90_plus'
    UNION ALL
    SELECT 'fx_rate_gap'::text AS item_type,
           'module.finance.view'::text AS permission,
           g.currency AS item_code,
           array_to_string(g.missing_types, ', ') AS subject,
           g.rate_date AS item_date
      FROM fx_rate_gaps g
     WHERE g.rate_date >= (CURRENT_DATE - 45)
    UNION ALL
    SELECT 'bank_unmatched'::text AS item_type,
           'module.finance.view'::text AS permission,
           s.bank_account_code AS item_code,
           s.code AS subject,
           l.line_date AS item_date
      FROM bank_statement_lines l
      JOIN bank_statements s ON s.id = l.statement_id
     WHERE l.match_status = 'unmatched' AND s.deleted_at IS NULL
) a
WHERE has_permission(a.permission);

COMMIT;
