-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
--
-- 【为什么是一张视图而不是九个页面各查各的】仪表盘的每一块牌子背后都是"有多少件
-- 事在等"这一类问题;九个问题九处写,就是九份会各自漂移的实现。hr_alerts 已经证明
-- 过这个形状:一个 UNION,每一种等待状态一支,页面只负责画。
--
-- 【属主权限 + 每支自带 permission 列,外层一次性把关】(OPS-14 修法 (a))。
-- 本视图横跨六个模块,invoker 会让 RLS 把读者无权模块的行【静默丢掉】—— 行消失
-- 在这里意味着"那个数少算了",而不是报错。属主权限读全量,外层
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
-- 不是零。谓词写一次而不是九遍 —— hr_alerts 的注释说过,复述 N 遍只会给下一个
-- 加支的人留一个漏写的机会;这里每支【声明】自己的权限码,外层【执行】它。
--
-- 【缺席 ≠ 零,页面必须自己分辨】视图对无权读者不发一行,于是"没有行"有两种
-- 含义:真的零,或者你看不见。app/page.tsx 先查权限再渲染每块牌子 —— 无权显示
-- 「受限」(common.restricted),绝不显示 0。这是仪表盘最容易犯、且任何 gate 都
-- 查不出的那个错(0 与"你看不见"在屏幕上一模一样 —— moduleGuard 的老病换了件衣服)。
--
-- 【item_type 写成 'x'::text 字面量】check-i18n 的 sqlLiteralAs 解析器现读本文件,
-- dashboard.item.* 的后缀集合就是这里的支列表 —— 加一支,键检查自动跟着变宽。
--
-- 【两笔贵的读数,按界所限】(OPS-16 报告点名的两处):
--   * fx_rate_gaps 按 (日期,币种) 对每组跑 fx_rate_asof,本身不受期间约束 ——
--     这里限 rate_date >= CURRENT_DATE - 45:仪表盘答"最近有没有漏",完整历史
--     归 /finance/month-end 按月翻。谓词落在分组键上,能下推进聚合。
--   * 银行对账这支【只数报表侧的未匹配行】(bank_statement_lines,行数 = 导入量,
--     天然有界)。bank_reconciliation_status 的账簿侧 LATERAL 要扫 journal_lines
--     全表 —— 那是对账页的活,不上人人都开的首页。
--
-- 【不在此列的】批次毛利 —— 有未决的设计问题(哪些限定词随数字走、已过账 COGS
-- 还是当前成本),自成一切,谓词已录在 AGENTS.md 常设决定 2。月结的七个信号 ——
-- /finance/month-end 是它们的枢纽,首页放一个入口,不复制信号。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

CREATE VIEW public.operations_now WITH (security_invoker = off) AS
SELECT a.item_type,
       a.permission,
       a.item_code,
       a.subject,
       a.item_date,
       (CURRENT_DATE - a.item_date) AS days_waiting
FROM (
    -- ── 进料:化验已录、尚未执行 ──(/inbound 角标的同一个条件,batch_assay_status 同源)
    SELECT 'assay_unapplied'::text AS item_type,
           'module.inbound.view'::text AS permission,
           ib.code AS item_code,
           ar.code AS subject,
           ar.created_at::date AS item_date
      FROM assay_results ar
      JOIN inbound_batches ib ON ib.id = ar.inbound_batch_id
     WHERE ar.applied_at IS NULL AND ar.deleted_at IS NULL AND ib.deleted_at IS NULL
    UNION ALL
    -- ── 加工:分摊已过期,或有成本却从未分摊 ──(月结页 allocProblems 的同一个条件)
    -- 读的是 processing_run_allocation_status(属主权限,OPS-14 审过);它内部的
    -- module.processing.view 谓词按调用者解析,与本视图外层的把关同码同判。
    SELECT 'allocation_stale'::text AS item_type,
           'module.processing.view'::text AS permission,
           s.code AS item_code,
           NULL::text AS subject,
           s.last_cost_change::date AS item_date
      FROM processing_run_allocation_status s
     WHERE s.is_stale OR (s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL)
    UNION ALL
    -- ── 采购:已确认待收货 ──('draft' 是还在编辑的单,不是在等谁)
    SELECT 'po_awaiting_receipt'::text AS item_type,
           'module.purchasing.view'::text AS permission,
           po.code AS item_code,
           po.status AS subject,
           po.order_date AS item_date
      FROM purchase_orders po
     WHERE po.deleted_at IS NULL AND po.status IN ('confirmed', 'receiving')
    UNION ALL
    -- ── 盘点:开着没关 ──
    SELECT 'stocktake_open'::text AS item_type,
           'module.stocktakes.view'::text AS permission,
           st.code AS item_code,
           NULL::text AS subject,
           st.started_at::date AS item_date
      FROM stocktakes st
     WHERE st.deleted_at IS NULL AND st.status = 'open'
    UNION ALL
    -- ── HR:待批假单 ──(人名标签跟着单据走 —— 常设决定 3,且本支就在 HR 模块内)
    SELECT 'leave_pending'::text AS item_type,
           'module.hr.view'::text AS permission,
           lr.code AS item_code,
           e.legal_name AS subject,
           lr.created_at::date AS item_date
      FROM leave_requests lr
      JOIN employees e ON e.id = lr.employee_id
     WHERE lr.status = 'pending' AND lr.deleted_at IS NULL
    UNION ALL
    -- ── HR:待批医疗报销 ──
    SELECT 'claim_pending'::text AS item_type,
           'module.hr.view'::text AS permission,
           mc.code AS item_code,
           e.legal_name AS subject,
           mc.created_at::date AS item_date
      FROM medical_claims mc
      JOIN employees e ON e.id = mc.employee_id
     WHERE mc.status = 'submitted' AND mc.deleted_at IS NULL
    UNION ALL
    -- ── HR:已提交待审批的评估 ──(hr_alerts 管病态:没评估人、超期;这支管常态队列)
    SELECT 'review_submitted'::text AS item_type,
           'module.hr.view'::text AS permission,
           e.code AS item_code,
           e.legal_name AS subject,
           COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
      FROM performance_reviews r
      JOIN employees e ON e.id = r.employee_id
     WHERE r.status = 'submitted'
    UNION ALL
    -- ── 财务:近 45 天有外币过账、当天缺牌价 ──(界限理由见文件头)
    SELECT 'fx_rate_gap'::text AS item_type,
           'module.finance.view'::text AS permission,
           g.currency AS item_code,
           array_to_string(g.missing_types, ', ') AS subject,
           g.rate_date AS item_date
      FROM fx_rate_gaps g
     WHERE g.rate_date >= (CURRENT_DATE - 45)
    UNION ALL
    -- ── 财务:银行报表未匹配行 ──(只数报表侧,界限理由见文件头)
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

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
