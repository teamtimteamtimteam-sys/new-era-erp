-- db/migrations/2026-10-03-at1b3-trails-master-data-and-tools.sql
-- AUDIT-TRAIL-1b-3 —— 主数据与工具的审计记录:物料 · 库位 · 金属价格 · 定价公式与条款申请 · 任务 · 三个阈值面板;
--   删掉的主数据进被删记录(v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1b3_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1b Step 0 §a 的登记表与 Q2 · Q3 · Q9 · Q13 · M2 · M5 · M6,Tim 2026-09-29 照建议裁定;
--   1b-1 已经建好了 M1–M6,这一刀只加主语)
--   ① trail_subjects:加八个主语 —— material · storage_location · metal_price · pricing_formula · task ·
--      processing_settings · pricing_settings · receiving_settings(后三个:M5 的布尔主键,M6 只看面板自己的几列)。
--   ② trail_subject_members:物料的附件与化验要求;库位的允许分类;公式的应付金属、修改史、条款申请与它的审批;
--      任务的步骤、参与者、修改史。
--   ③ trail_prelog_sources:"记录开始之前"的来源 —— 建行时刻与删除戳;公式与任务的修改史;任务那一族的人是员工 id(M2)。
--   ④ save_storage_location(新):库位与它的允许分类【一次调用、一笔事务、只写变了的】(Q13)—— 取代应用里的三次写。
--   ⑤ deleted_records:加四类 —— 客户 · 供应商 · 物料 · 定价公式;"谁删的"取自变更记录(这四张表从来没有记过),
--      读不到就是 NULL(横幅只说日期,Q8)。同一组列,CREATE OR REPLACE。
--
-- 【不做什么】不改任何表、策略、授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册。
--
-- 【破窗】什么都不坏:
--   · 旧应用只用 1b-2 之前的二十一个主语调 record_trail,参数不变;新主语对旧应用不存在(它不叫它们)。
--   · 旧应用的库位保存仍是三次直连写 —— 两张表的写策略与触发器一个没动,它照旧能写;新函数只是多出来的一扇门。
--   · deleted_records 多了四类行:旧的 /settings/deleted 会把它们列出来,种类名一栏是 deleted.kind.<键>,而旧应用的
--     消息文件里没有那四个键 —— 窗口里那四类的"种类"一格会印出键本身(deleted.kind.customer),没有链接(旧的
--     KIND_HREF 不认它们,不给链接)。这一页只给 data.view_deleted(auditor · cfo 等)。这是唯一一处看得见的不同。
--   · 三支登记表都是 IMMUTABLE 的函数,替换不锁表;视图的 CREATE OR REPLACE 只在提交那一刻拿一下它自己的锁。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;二十九个主语;新函数 authenticated 能执行、anon 不能;
--   被删记录列得出线上那几类;并以 tim@(cfo)真的读几次(每一张任务的修改史一行不少;阈值面板读得到、不报错)。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子(1b-2 的形状,二十一个主语;新函数还不存在)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B3_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 21 THEN
        RAISE EXCEPTION 'AT1B3_PRE|expected the 21 subjects of 1b-2, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF to_regproc('public.save_storage_location') IS NOT NULL THEN
        RAISE EXCEPTION 'AT1B3_PRE|save_storage_location already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1b3_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE at1b3_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1b3_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
-- deleted_records 按【调用者】的模块码过滤(has_permission 读 JWT);迁移的属主身份没有 JWT,读到的会是 0 行 ——
--   一次权限拒绝长得和一次测量一模一样(AGENTS.md「一个 0 行的读数,先问它是谁读的」)。所以以 tim@(cfo,持每一个 view 码)读
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
CREATE TEMP TABLE at1b3_deleted_before ON COMMIT DROP AS
SELECT record_kind, record_id FROM deleted_records;
SELECT set_config('request.jwt.claims', '', true);

-- ── 1 · 三支登记表:原地替换(同一签名,镜像原样)──────────────────────────────

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
--                'page'(M3):页面的码就是门;根行自己的那几次改动照子行的规矩走 —— 读者过不了根表的读规则,
--                那几条就是 Restricted(Q4)。equipment 用它:根表 fixed_assets 只给财务读,而这一页给加工的人。
--   root_columns 非空(M6):根行只取这几列的改动(一块面板只管它自己编辑的那几个字段,Q25 的同一条规矩)。
--                NULL = 整行。1b-3 的三个阈值面板会用到它;本刀先建好,fixture 237 用一个临时主语证它。
-- view_codes 与页面守卫逐字同一组码:
--   purchase_order → /purchasing/orders/[id]        requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id]     requireModule(MOD.processing) = module.processing.view
--   role           → /settings/roles/[id]           requireManagePermissions()     = action.manage_permissions
--   inbound_batch  → /inbound/[id]/edit             requireModule(MOD.inbound)     = module.inbound.view
--   output_batch   → /output/[id]/edit              requireModule(MOD.output)      = module.output.view
--   work_order     → /operation/orders/[id]         requireModule(MOD.processing)  = module.processing.view
--   stocktake      → /stocktakes/[id]               requireModule(MOD.stocktakes)  = module.stocktakes.view
--   equipment      → /operation/equipment/[id]      requireModule(MOD.processing)  = module.processing.view
--   shift_handover → /operation/handovers/[id]      requireModule(MOD.processing)  = module.processing.view
--   warehouse_request → /inventory 的申请一块        requireModule(MOD.inventory)   = module.inventory.view(+ 财务)
-- AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a 的商务那一半):
--   quote          → /sales/quotes/[id]              requireModule(MOD.sales)       = module.sales.view
--   sales_order    → /sales/orders/[id]              requireModule(MOD.sales)       = module.sales.view
--   shipment       → /sales/shipments/[id]           action.ship_goods,否则 requireModule(MOD.sales)(M1:任一)
--   customer       → /sales/customers/[id]           requireModule(MOD.customers)   = module.customers.view
--   commission_agreement → /sales/commissions/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   supplier       → /suppliers/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   container      → /logistics/containers/[id]      requireModule(MOD.logistics)   = module.logistics.view
--   forwarder      → /logistics/forwarders/[id]      requireModule(MOD.logistics)   = module.logistics.view
--                    根表是 suppliers(读规则 module.suppliers.view)—— M3:页面的码是门,根行自己的改动逐行判
--   lane · port    → /logistics/lanes(只有清单页,按条合起来,见 app/components/trail/ListTrail.tsx)module.logistics.view
--   company_licence → /purchasing/licences(只有清单页)门是 module.purchasing.view,而这张表的读规则是
--                    module.suppliers.view —— 这一块只画在持 suppliers.view 的那一支里(页面本来就那样分),所以登记后者
-- AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a 的主数据与工具):
--   material       → /materials/[id]/edit(只有这一页,Q2)requireModule(MOD.materials) = module.materials.view
--   storage_location → /inventory/locations/[id]/edit(只有这一页)requireModule(MOD.inventory) = module.inventory.view
--   metal_price    → /tools/pricing/metal-prices/[id]/edit(只有这一页)requireEditPermission('action.metal_prices')
--   pricing_formula → /tools/pricing/formulas/[id]/edit(只有这一页)requireModule(MOD.pricing) = module.pricing.view
--   task           → /tools/tasks/[id]                requireModule(MOD.tasks)       = module.tasks.view
--                    私人任务也读得到(Q3):根行要过 tasks 自己的读规则(团队任务 · 自己的 · 或持 module.tasks.view_all)——
--                    那正是"谁打得开这一页"的同一个判据,而遮蔽那一步本来就先问任务隐私
--   processing_settings → /operation/orders 的工单阈值面板          module.processing.view;M6:只取面板编辑的两列
--   pricing_settings    → /tools/pricing/metal-prices 的异常阈值面板  module.pricing.view;M6:只取那一列
--   receiving_settings  → /purchasing/discrepancies 的收货阈值面板   module.inbound.view(面板只画在这一支里);M6:三列
--                    三张都是单行表,主键 id boolean —— M5:页面传 'true',读法按根行自己的类型重建那个键
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct'])
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

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
        ('task_history',                   'created', 'changed_at',   'changed_by',   NULL, 'employee')
    ) AS p(table_name, kind, at_column, by_column, extra, by_kind);
$function$;

-- ── 2 · 库位的保存:一次调用、只写变了的(Q13)────────────────────────────────

-- db/functions/save_storage_location.sql
-- AUDIT-TRAIL-1b-3(Tim 的 Q13,AT-1b Step 0,2026-09-29):保存一个库位 —— 新建或修改,连同它允许存放的废物分类,
--   【一次调用、一笔事务、只写变了的】。
--
-- 【为什么要它】此前 app/inventory/locations/actions.ts 分三次写:改库位那一行 · 删掉它全部的允许分类 · 再把勾上的
--   全部插回去 —— 三笔事务。于是审计记录里每保存一次,没动过的分类也读成"拿掉了"又"加上了",而且是三条记录
--   (Step 0 §f)。现在:库位那一行只有真的变了才写;分类只删【不再勾着】的、只插【新勾上】的;全在这一笔里。
-- 【空集合是合法的,它的意思是"未配置"】与原来的动作同一条:不拦空。
-- 【违规提醒照旧】trg_slac_notify_written 只接 INSERT(清空到零行 = 未配置,不是违规)。原来"整体删了再插"每次都
--   让它响;现在只拿掉、不加的那一次没有 INSERT,它不会响 —— 而拿掉一个分类恰恰可能让已有存量变成违规。
--   所以这一支在那种情形下自己按同一个判据叫一次 notify_class_violations(剩下的集合非空时,与原来一字不差)。
--   集合一条都没变的保存不再叫 —— 原来那一次是"整体重写"的副作用,不是一个新的配置。
-- 【SECURITY DEFINER 的理由】notify_class_violations 对 authenticated 收回了执行权;门在函数第一行
--   (require_permission('module.inventory.edit'),与两张表的写策略同一个码)。change_log 的"谁"取自登录,不受影响。
CREATE OR REPLACE FUNCTION public.save_storage_location(p_code text, p_name text, p_classes text[], p_id uuid DEFAULT NULL::uuid, p_zone text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id      uuid := p_id;
    v_classes text[] := ARRAY(SELECT DISTINCT c FROM unnest(COALESCE(p_classes, ARRAY[]::text[])) c WHERE c IS NOT NULL AND c <> '');
    v_removed integer := 0;
    v_added   integer := 0;
BEGIN
    PERFORM require_permission('module.inventory.edit');
    IF v_id IS NULL THEN
        INSERT INTO storage_locations (code, name, zone, notes)
        VALUES (p_code, p_name, p_zone, p_notes)
        RETURNING id INTO v_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = v_id) THEN
            RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', v_id;
        END IF;
        UPDATE storage_locations
           SET code = p_code, name = p_name, zone = p_zone, notes = p_notes
         WHERE id = v_id
           AND (code, name, zone, notes) IS DISTINCT FROM (p_code, p_name, p_zone, p_notes);
    END IF;

    DELETE FROM storage_location_allowed_classes
     WHERE location_id = v_id AND NOT (classification_code = ANY (v_classes));
    GET DIAGNOSTICS v_removed = ROW_COUNT;

    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    SELECT v_id, c FROM unnest(v_classes) c
     WHERE NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes a
                        WHERE a.location_id = v_id AND a.classification_code = c);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    IF v_removed > 0 AND v_added = 0 AND cardinality(v_classes) > 0 THEN
        PERFORM notify_class_violations('location_configured', NULL, ARRAY[v_id]);
    END IF;
    RETURN v_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.save_storage_location(text, text, text[], uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_storage_location(text, text, text[], uuid, text, text) TO authenticated, service_role;

-- ── 3 · 被删记录:加四类(镜像原样;同一组列)──────────────────────────────────

-- db/views/deleted_records.sql
-- AUDEL-3:全站被软删的记录,一条一行 —— 编号、种类、时刻、谁、为什么,
-- 以及台账上那条注销/冲销流水。被回滚的加工单也在这里(它的"删除"就是它的冲销)。
--
-- 【地面:RLS 根本不过滤已删的行】七张带 delete_reason 的表,SELECT 策略全部只是
-- has_permission('module.X.view') —— 没有任何一条带 deleted_at IS NULL。过滤发生在
-- 【应用查询】里。所以这一刀不需要动任何策略、也不需要新权限码。
--
-- 【每一行跟着它自己模块的读权限】permission 列 + 外层 has_permission(调用者)——
-- 无权的那一类【整类缺席】,不是显示成零。这是 /margin 那一课:为跨模块页面合成
-- 一个新权限码,会是"谁能看什么"的第二份定义,与各模块的策略必然漂开。
--
-- 【属主权限,不是 invoker】跨七个模块;invoker 会让 RLS 静默丢行,而行消失在这里
-- 的意思会变成"没有东西被删过"(OPS-14 的 xmodule 那一课)。
--
-- 【只读,永不提供恢复】撤销删除是一个没有人做过的决定 —— 注销流水已经进台账、
-- 回滚的投入已经还回去。一个按钮会替所有人默默把那个决定做掉。
--
-- 【record_kind 的取值就是下面那几个字面量】—— check-i18n 的 deleted.kind. 前缀
-- 现读本文件,加一支就自动被查到。
--
-- NOTE: introduced by db/migrations/2026-08-17-audel3-a-place-to-see-what-was-deleted.sql.
--
-- ★ AUDIT-TRAIL-1b-3(Tim 的 Q9 · Q8,2026-09-29):多了四类 —— 客户 · 供应商 · 物料 · 定价公式。
--   这四张表【从来没有记过谁删的】(没有 deleted_by、没有 delete_reason)。"谁"只能从 change_log 里那一次
--   把 deleted_at 置上的改动读出来(变更记录 28/09/2026 23:58 才开始);读不到就是 NULL —— 页面与横幅只说日期,
--   【不】拿 updated_by 去猜(Q8:updated_by 是最后一个碰过它的人,不一定是删它的人)。
--   属主权限照旧,所以视图读得到 change_log(应用角色对它没有任何授权);行一级仍由每一支自己的 permission 裁决。
--   detail 那一格放名字(这几类记录没有数量可说;编号旁边的名字是人认得它的方式)。

CREATE OR REPLACE VIEW public.deleted_records AS
 SELECT record_kind,
    permission,
    record_id,
    code,
    deleted_at,
    deleted_by,
    delete_reason,
    movement_id,
    detail
   FROM ( SELECT 'inbound_batch'::text AS record_kind,
            'module.inbound.view'::text AS permission,
            b.id AS record_id,
            b.code,
            b.deleted_at,
            b.deleted_by,
            b.delete_reason,
            ( SELECT m.id
                   FROM inventory_movements m
                  WHERE m.inbound_batch_id = b.id AND m.movement_type = 'writeoff'::text
                  ORDER BY m.occurred_at DESC
                 LIMIT 1) AS movement_id,
            (b.quantity || ' '::text) || COALESCE(b.unit, ''::text) AS detail
           FROM inbound_batches b
          WHERE b.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'output_batch'::text AS text,
            'module.output.view'::text AS text,
            b.id,
            b.code,
            b.deleted_at,
            b.deleted_by,
            b.delete_reason,
            ( SELECT m.id
                   FROM inventory_movements m
                  WHERE m.output_batch_id = b.id AND (m.movement_type = ANY (ARRAY['writeoff'::text, 'reversal_void'::text]))
                  ORDER BY m.occurred_at DESC
                 LIMIT 1) AS id,
            (b.quantity || ' '::text) || COALESCE(b.unit, ''::text) AS text
           FROM output_batches b
          WHERE b.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'processing_run'::text AS text,
            'module.processing.view'::text AS text,
            r.id,
            r.code,
            r.deleted_at,
            r.deleted_by,
            r.delete_reason,
            NULL::uuid AS uuid,
            r.status
           FROM processing_runs r
          WHERE r.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'stocktake'::text AS text,
            'module.stocktakes.view'::text AS text,
            s.id,
            s.code,
            s.deleted_at,
            s.deleted_by,
            s.delete_reason,
            NULL::uuid AS uuid,
            s.status
           FROM stocktakes s
          WHERE s.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'purchase_order'::text AS text,
            'module.purchasing.view'::text AS text,
            p.id,
            p.code,
            p.deleted_at,
            p.deleted_by,
            p.delete_reason,
            NULL::uuid AS uuid,
            p.status
           FROM purchase_orders p
          WHERE p.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'sales_order'::text AS text,
            'module.sales.view'::text AS text,
            o.id,
            o.code,
            o.deleted_at,
            o.deleted_by,
            o.delete_reason,
            NULL::uuid AS uuid,
            o.status
           FROM sales_orders o
          WHERE o.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'quote'::text AS text,
            'module.sales.view'::text AS text,
            q.id,
            q.code,
            q.deleted_at,
            q.deleted_by,
            q.delete_reason,
            NULL::uuid AS uuid,
            q.status
           FROM quotes q
          WHERE q.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'customer'::text AS text,
            'module.customers.view'::text AS text,
            c.id,
            c.code,
            c.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'customers'::text AND l.row_key = jsonb_build_object('id', c.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            c.legal_name
           FROM customers c
          WHERE c.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'supplier'::text AS text,
            'module.suppliers.view'::text AS text,
            s.id,
            s.code,
            s.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'suppliers'::text AND l.row_key = jsonb_build_object('id', s.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            s.legal_name
           FROM suppliers s
          WHERE s.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'material'::text AS text,
            'module.materials.view'::text AS text,
            m.id,
            m.code,
            m.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'materials'::text AND l.row_key = jsonb_build_object('id', m.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            m.name
           FROM materials m
          WHERE m.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'pricing_formula'::text AS text,
            'module.pricing.view'::text AS text,
            f.id,
            f.code,
            f.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'pricing_formulas'::text AND l.row_key = jsonb_build_object('id', f.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            f.name
           FROM pricing_formulas f
          WHERE f.deleted_at IS NOT NULL) a
  WHERE has_permission(permission);

COMMENT ON VIEW public.deleted_records IS
    'AUDEL-3:全站被软删的记录,一条一行 —— 编号、种类、时刻、谁、为什么,以及台账上那条注销/冲销流水。被回滚的加工单也在这里(它的"删除"就是它的冲销)。【每一行跟着它自己模块的读权限】(permission 列 + 外层 has_permission),无权的那一类整类缺席而不是显示成零 —— 不为跨模块页面合成新权限码(/margin 那一课)。属主权限:invoker 会让 RLS 静默丢行,而行消失在这里意味着"没有东西被删过"。【只读,永不提供恢复】—— 撤销删除是一个没有人做过的决定,一个按钮会替所有人默默做掉它。';

GRANT SELECT ON public.deleted_records TO authenticated;

-- ── 4 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.at1b3_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE at1b3_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_m    int;
    v_j    jsonb;
    t      record;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1b3_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1b3_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B3_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1b3_pending_before b EXCEPT SELECT a.k, a.id FROM at1b3_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1b3_pending_after a EXCEPT SELECT b.k, b.id FROM at1b3_pending_before b)) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1b3_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1b3_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:二十九个主语;每一个 shown 成员表都在 change_log 的覆盖里;登记表与读法对 authenticated 的执行权照旧;
    --    新函数 authenticated 能执行、anon 不能(apply_migration.sh 在本事务里回放 zzz_function_grants)
    IF (SELECT count(*) FROM trail_subjects()) <> 29 THEN
        RAISE EXCEPTION 'AT1B3_PROOF|expected 29 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT m.table_name, ', ') INTO v_bad FROM trail_subject_members() m
     WHERE m.shown AND NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                                    WHERE tr.event_object_table = m.table_name AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B3_PROOF|member tables without the change-log trigger: %', v_bad; END IF;
    SELECT string_agg(s.root_table, ', ') INTO v_bad FROM trail_subjects() s
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.triggers tr WHERE tr.event_object_table = s.root_table AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B3_PROOF|root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)', 'public.save_storage_location(text, text, text[], uuid, text, text)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B3_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B3_PROOF|anon can execute %', f;
        END IF;
    END LOOP;

    -- ⑤ 被删记录(以 tim@ 读 —— 见文首那一句):原来那几类一行不少;新的四类与基表里删掉的行数逐类相等
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    IF (SELECT count(*) FROM at1b3_deleted_before) = 0 THEN
        RAISE EXCEPTION 'AT1B3_PROOF|the before-reading of deleted_records is empty — a refused read, not a measurement';
    END IF;
    IF EXISTS (SELECT record_kind, record_id FROM at1b3_deleted_before EXCEPT SELECT record_kind, record_id FROM deleted_records) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|a deleted record that was listed before is no longer listed';
    END IF;
    FOR t IN SELECT * FROM (VALUES ('customer', 'customers'), ('supplier', 'suppliers'), ('material', 'materials'),
                                   ('pricing_formula', 'pricing_formulas')) v(kind, tbl) LOOP
        EXECUTE format('SELECT count(*) FROM %I WHERE deleted_at IS NOT NULL', t.tbl) INTO v_n;
        SELECT count(*) INTO v_m FROM deleted_records WHERE record_kind = t.kind;
        RAISE NOTICE 'AT1B3 deleted %: % in the table, % listed for tim@ (% with a person)', t.kind, v_n, v_m,
            (SELECT count(*) FROM deleted_records WHERE record_kind = t.kind AND deleted_by IS NOT NULL);
        IF v_n <> v_m THEN RAISE EXCEPTION 'AT1B3_PROOF|deleted %: % in the table but % listed', t.kind, v_n, v_m; END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 真的读几次:每一张任务(删掉的也读 —— 读规则不过滤 deleted_at)以它【归属人】的账号读 —— 归属人永远打得开自己的任务
    --    (Q3;私人任务对别人是私的:tim@ 不持 module.tasks.view_all,读别人的私人任务被按名拒,那是对的);修改史一行不少。
    --    归属人没有账号的,退回 tim@;一张团队任务被拒 = 坏了。三个阈值面板以 tim@ 读得到(M5:主键 'true')
    FOR t IN SELECT tk.id, tk.code, tk.task_type, COALESCE(e.user_id, '634c00f9-c3a9-4444-9eed-b624cb6a2a93'::uuid) AS reader,
                    CASE WHEN e.id IS NULL THEN 'no owner' WHEN e.user_id IS NULL THEN 'owner ' || e.code || ' has no login'
                         ELSE 'owner ' || e.code || COALESCE(' (' || e.employment_status || CASE WHEN e.deleted_at IS NOT NULL THEN ', deleted' ELSE '' END || ')', '') END AS why
               FROM tasks tk LEFT JOIN employees e ON e.id = tk.owner_id ORDER BY tk.code LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', t.reader, 'role', 'authenticated')::text, true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail('task', t.id::text, 500) r;
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            IF t.task_type = 'team' OR SQLERRM NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
                RAISE EXCEPTION 'AT1B3_PROOF|task % (%) refused for its reader: %', t.code, t.task_type, SQLERRM;
            END IF;
            RAISE NOTICE 'AT1B3 task % (personal) refused by name for its reader (%) — % history rows', t.code, t.why,
                (SELECT count(*) FROM task_history WHERE task_id = t.id);
            CONTINUE;
        END;
        SELECT count(*) INTO v_n FROM task_history h WHERE h.task_id = t.id
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) e
                            WHERE e ->> 'table_name' = 'task_history' AND e -> 'row_key' ->> 'id' = h.id::text);
        IF v_n > 0 THEN RAISE EXCEPTION 'AT1B3_PROOF|% task history row(s) of % missing from its trail', v_n, t.code; END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    FOREACH k IN ARRAY ARRAY['processing_settings', 'pricing_settings', 'receiving_settings'] LOOP
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM record_trail(k, 'true', 20);
        EXECUTE 'RESET ROLE';
        RAISE NOTICE 'AT1B3 % trail rows for tim@: %', k, v_n;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑦ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1b3_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1B3 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1b3_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1B3_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1b3_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1b3_pending_decider_check(boolean);

COMMIT;
