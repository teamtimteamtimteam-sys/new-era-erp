-- db/migrations/2026-10-04-at1d2-trails-leave-and-time.sql
-- AUDIT-TRAIL-1d-2 —— 请假与考勤的审计记录(v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1d2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1d Step 0 的 Q1–Q38,Tim 2026-10-04 全部照建议裁定;这是 1d-2 那一刀)
--   ① trail_subjects:九个主语 —— leave_request · my_leave_request(M8)· leave_grant · leave_types(M11)· public_holidays(M11)·
--      medical_claim · my_medical_claim(M8)· overtime_batch(M1:hr.view · overtime_enter · overtime_approve)· attendance_period。
--   ② trail_subject_members:它们的成员;费用多一个成员 medical_claims(Q37,家仍在报销单)。
--   ③ trail_prelog_sources:Q12 的那几个戳(请假的决定 · 加班的冲销与丢弃 · 考勤的完成与重开 · 医疗报销的撤回)与几张表的建立。
--   ④ trail_ref_label:假期发放的名字;加班批的链接。trail_row_record:加班批那几行的 Record 一栏落在 /hr/overtime(Q36)。
--   ⑤ document_types:medical_claim 与 attendance_period 的 link_mode 改成 detail(Q36)。加班批【不】进 document_types(没有 code 列)。
--
-- 【不做什么】不改任何表结构、策略、表上的授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册;不建、不停、不删任何账号。
--
-- 【破窗】写的路一条都不坏:五支函数同签名原地替换,record_trail 不动;旧应用不叫九个新主语。提前看得见、而且是有意的:
--   费用页的旧应用读到报销单那几行(新成员),旧的造句器把它们说成通用的 "Medical claim …";汇总页上加班那几行的 Record 一栏
--   多了链接;全站搜索里医疗报销与考勤期间点进详情页(两页早就有)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;七十七个主语;并以 admin@ 把新主语在线上的每一条记录读一遍
--   (一条被拒 = 坏了)。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子(1d-1 的形状,六十八个主语)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D2_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 68 THEN
        RAISE EXCEPTION 'AT1D2_PRE|expected the 68 subjects of 1d-1, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'public.record_trail(text, text, integer)'::regprocedure
                      AND 'op_key' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1D2_PRE|record_trail does not return op_key';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1d2_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE at1d2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1d2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;

-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    (AUDIT-TRAIL-1d-1 多了两种:'collection' —— M11,一张表整张是一条记录;'gate:<名字>' —— M12,比表的规则更窄)
--                'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
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
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第一刀:账上的单据):
--   journal_entry   → /finance/journal/[id]             requireModule(MOD.finance)     = module.finance.view
--   invoice         → /finance/invoices/[id]            requireModule(MOD.finance)     = module.finance.view
--   credit_note     → /finance/credit-notes/[id]        requireModule(MOD.finance)     = module.finance.view
--   payment         → /finance/payments/[id]            requireModule(MOD.finance)     = module.finance.view
--   payment_request → /finance/payment-requests/[id]    requireModule(MOD.finance)     = module.finance.view
--                    (行内转账、代扣税缴纳与它们的冲销也住在这一页 —— 它们没有自己的页,Q17)
--   expense         → /finance/expenses/[id]            requireModule(MOD.finance)     = module.finance.view
--   payable         → /finance/payables/[batchId]       requireModule(MOD.finance)     = module.finance.view
--                    根表是 inbound_batches(读规则 module.inbound.view)—— M3:页面的码是门(Q5,forwarder 的先例);
--                    M6:只取应付那几列(数量、单价、供应商、采购单、计价状态、到货日、注销三列)—— 批次的仓库那一面
--                    (化验、安全状态、库位……)住在 /inbound/[id]/edit 的 inbound_batch 上,不在应付页上再说一遍。
--                    注销那三列必须在里面:M6 丢掉 root_columns 之外的戳(record_trail),不在里面注销就看不见(Q5 的横幅)。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第二刀:其余的单据与合同):
--   sale            → /finance/receivables/[saleId]     requireModule(MOD.finance)     = module.finance.view
--   freight         → /finance/freight/[id]             requireModule(MOD.finance)     = module.finance.view
--                    (根表的读规则是 inbound.view OR finance.view,再加一条 finance.edit 的 ALL —— 页面的码过得了,不需要 M3)
--   fixed_asset     → /finance/assets/[id]              requireModule(MOD.finance)     = module.finance.view
--                    根表与 equipment 同一张 fixed_assets(supplier / forwarder 的先例:一张表两个主语,Q10)——
--                    equipment 的门是加工,这一页的门是财务;根表的读规则就是 finance.view,所以是 'table'
--   bank_statement  → /finance/bank/statements/[id]     requireModule(MOD.finance)     = module.finance.view
--                    删掉的对账单也读得到(Q6:持 data.view_deleted 的人只读打开;根表的读规则不过滤已删的行)
--   gst_period      → /finance/gst/[periodId]           requireModule(MOD.finance)     = module.finance.view
--   fx_rate         → /finance/fx/[id]/edit(只有这一页,Q2)requireModule(MOD.finance) = module.finance.view
--                    撤回了的汇率也读得到(Q7:页面对本来的读者只读打开)
--   management_pack → /finance/packs/[id]               requireModule(MOD.finance)     = module.finance.view
--   contract        → /contracts/[id]                   requireModule(MOD.suppliers)   = module.suppliers.view
--                    根表的读规则按方向:卖方合同要 customers.view、买方合同要 suppliers.view —— 页面在 RLS 下读、读不到就 404,
--                    所以 'table' 与页面同一个答案(看不见的合同对他而言不存在)
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第三刀:期末、设置与清单页上的记录):
--   finance_lock    → /finance/settings 锁期面板之下 · /finance/close 关账史之下(Q25 · Q29)  module.finance.view
--                    根表 finance_settings(单行,id boolean —— M5,页面传 'true');M6:只取 locked_before 一列;
--                    月结 / 反结(period_closes)经 M7 整张表属于这一行(两张表之间一个键都没有,Q3)
--   finance_gst     → /finance/settings GST 面板之下                                       module.finance.view
--                    同一行(M5);M6:只取 gst_registered、gst_registration_no 两列 —— 两块面板各看各的(Q25);
--                    这一行上没有面板的六列(gst_rate_pct · system_start_date · 三个财年列 · default_allocation_basis)
--                    哪一块都不取,只在 /settings/change-history 上找得到(Q4);审批方针那四列归 AT-1d(Q2)
--   company_profile → /finance/company                                                     requireModule(MOD.finance)
--                    单行(M5),整行 —— 一块面板编辑整行;银行那五列按 HISTORY-1 的规则对不持 data.view_banking 的人遮
--   year_close      → /finance/close 年结那一块(清单块,ListTrail)                          module.finance.view
--   journal_request → /finance/journal 每一张申请卡片里(Q17,一张一块)                     module.finance.view
--   expense_claim   → /finance/claims 每一张报销单一块(Q20)                                module.finance.view
--   my_expense_claim → /me 报销人自己那几张(Q20 的另一半)—— ★ M8:没有页面码(view_codes 为空数组),
--                    根行自己那张表的读规则就是门(expense_claims:module.finance.view 或者【这张单说的就是你】);
--                    只许与 'table' 同用(record_trail 里拒绝 'page' —— 那会对每一个人敞开)。
--                    审批留痕那一支(approval_log 的 expense_claim)不给本人开口子,所以本人看到的是 Restricted(Q4)
--   bank_transfer   → /finance/bank 转账那一块(清单块)                                     module.finance.view
--   wht_remittance  → /finance/wht 缴纳那一块(清单块)                                      module.finance.view
--   cash_forecast · cash_forecast_line → /finance/cash-forecast(清单块,Q16:冻结 + 作废旧的一张是一次操作)
--   bank_import_profile → /finance/bank/import(清单块,删掉的也读)                         module.finance.view
--   (重估 / 折旧 / 工资付款 / 加工成本结算的批次与批量汇率【不】另立主语:它们各自的清单块读 journal_entry · expense ·
--    fx_rate 那几个现成主语,Q16 的 op_key 把一次操作并成一条 —— Q18 · Q19)
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第一刀:机制、设置与员工):
--   account         → /settings/accounts 每一行一块(Q24)        requireManagePermissions()     = action.manage_permissions
--                    ★ M9:根表 auth.users 不在 public 里 —— trail_log_only_tables() 给它一份安全投影与声明的读码;
--                    事件(建立 / 停用 / 恢复 / 失败 / 回滚)住在 change_log(record_account_event)
--   approval_policy → /settings/approvals(Q25,1c 的 Q2 挪过来)requireFunction(FN.approvals) = action.manage_permissions
--                    同一行 finance_settings(M5);M6:只取它编辑的四列;修改史 finance_settings_history 经 M7 整张属于这一行。
--                    根表的读规则是 module.finance.view —— 'table':读者两个码都要(线上唯一持 manage_permissions 的 admin 两个都有,Q23)
--   employee        → /hr/employees/[id]                        requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这就是你】—— 与页面同一个答案
--   department      → /hr/departments/[id]/edit(只有这一页)   requireModule(MOD.hr)          = module.hr.view
--   training_record → /hr/training/[id]/edit(只有这一页,Q29) requireModule(MOD.hr)          = module.hr.view
--   import_batch    → /settings/import 的批次一块(清单块,Q24) can('action.bulk_import')      = action.bulk_import
--   dictionary_*    → /settings/dictionaries 每一段一块(Q4)    每一段自己的查看码(registry.ts 的 viewPermission)
--                    ★ M11:'collection' —— 没有根行,那张字典表的每一行、change_log 里它的每一行都属于这一块;根键照写那张表的主键
--                    (code),record_trail 不用它。
--   ☞ M12('gate:reviewer')本刀没有主语用它(它的第一个用户是 AT-1d-3 的 /my-reviews);fixture 244 用一个临时主语证它。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第二刀:请假与考勤):
--   leave_request     → /hr/leave/[id]                  requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这张单说的就是你】—— 与页面同一个答案
--   my_leave_request  → /me 本人那几张(Q14,M8:没有页面码 —— 根行自己的读规则就是门;审批与消耗那几行对本人是 Restricted)
--   leave_grant       → /hr/leave/grants 那一块(清单块,按年)         module.hr.view
--   leave_types       → /hr/leave/types(M11 集合,根键 code)         module.hr.view
--   public_holidays   → /hr/leave/holidays(M11 集合 —— 假期是【硬删】的,一行删掉之后只剩变更记录里那一份影像)
--   medical_claim     → /hr/claims/[id]                 requireModule(MOD.hr)          = module.hr.view
--   my_medical_claim  → /me 本人那几张(Q14,M8)
--   overtime_batch    → /hr/overtime/[id]               requireFunction(FN.overtime)   = M1:hr.view · overtime_enter · overtime_approve
--                    (与页面守卫、与 overtime_batches 的读规则逐字同一组码)
--   attendance_period → /hr/attendance/[id]             requireModule(MOD.hr)          = module.hr.view
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
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL),
        -- AUDIT-TRAIL-1d-2
        ('leave_request',     ARRAY['module.hr.view'],            'leave_requests',     'id', 'table', NULL),
        ('my_leave_request',  ARRAY[]::text[],                    'leave_requests',     'id', 'table', NULL),
        ('leave_grant',       ARRAY['module.hr.view'],            'leave_grants',       'id', 'table', NULL),
        ('leave_types',       ARRAY['module.hr.view'],            'leave_types',        'code', 'collection', NULL),
        ('public_holidays',   ARRAY['module.hr.view'],            'public_holidays',    'id', 'collection', NULL),
        ('medical_claim',     ARRAY['module.hr.view'],            'medical_claims',     'id', 'table', NULL),
        ('my_medical_claim',  ARRAY[]::text[],                    'medical_claims',     'id', 'table', NULL),
        ('overtime_batch',    ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve'], 'overtime_batches', 'id', 'table', NULL),
        ('attendance_period', ARRAY['module.hr.view'],            'attendance_periods', 'id', 'table', NULL)
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
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

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
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
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
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true)
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
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
        ('attendance_lines',               'stamp',   'frozen_at',    NULL,           NULL, 'account')
    ) AS p(table_name, kind, at_column, by_column, extra, by_kind);
$function$;

-- db/functions/trail_ref_label.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一个被引用的值 → 屏幕上认得出的名字。数据库解析,界面只负责造句。
--   返回 {"label": …, "gone": bool, "person": {…}}(person 只在 p_table = 'auth.users' 时有):
--   · 单据(document_types 登记的表)→ 单据编号(PO-2026-0010);客户 / 供应商 → 法定名;物料 → 名称;
--     员工 → 称呼名,没有就法定名;批次 → 编号 · 物料名(外加 unit);采购单明细行 → 采购单编号 line N;
--     字典(有 name_en 的表)→ name_en;币种 → 代码;其余依次试 name / legal_name / title / label。
--   · 一个都没有 → label 为 NULL,界面说 "a <thing>"。【绝不回落到 uuid 或内部代码】。
--   · 那一行已经被硬删 → 取 change_log 里它最后一份完整影像,gone = true(界面加 "(since deleted)");
--     连影像都没有(早于变更记录,或从未存在)→ label NULL + gone = true(界面说 "a … that has since been deleted")。
--   · 'auth.users':一个登录账号 → 那个人(trail_actor 同一套答法)。
-- AUDIT-TRAIL-1b-1:
--   · 加工单多带一个 ended(它已经回滚了)—— 批次页上"用在加工 PROC-…"那一条据此加一句灰字
--     "This processing was later rolled back"(旧批次记录的 run_voided,Q5)。
--   · 交接班 → "DD/MM/YYYY · 班次";停机 → "机器编号 · DD/MM/YYYY HH:MM"(新加坡时间)—— 两张表都没有编号或名字,
--     以前只能说 "a handover" / "a downtime"。
-- AUDIT-TRAIL-1b-2:订单 / 报价明细行 → "SO-… line N";港口 → "代码 名称";航段 → "起运港 → 目的港";
--   执照与合规证书 → "种类 · 编号";附件 → 文件名;集装箱单据 → 单据种类 —— 这几张表都没有编号或 name 一类的列。
--   物料多带一个 unit(与批次同一个做法):订单 / 报价明细行的数量据此说成 "10 kg"。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q12 · Q33):
--   · 员工 → 走 trail_actor(与"谁做的"同一份答法):不持 module.hr.view 的读者只认得出他自己,别人一律 Restricted ——
--     与 ActorName、与每一页的人名同一条规矩(§9.7 早就说"每一个指着人的值都走同一个函数",而此前这一支直接把名字交了出去)。
--     付款、费用、报销单、付款申请上的 employee_id 都是这一种。匿名化了的人说 "A former employee"(以前是一个空名字)。
--   · 单据(document_types 里 link_mode = 'detail' 的)多带一个 href(详情页的路径)—— 审计记录里"被 JE-… 冲销"那一行
--     是一个链接(Q33),路径来自登记表,界面不拼路由。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §g · Q14):这几张表没有编号或名字,以前只能说 "a …":
--   · 销售 → "OUT-2026-0186 sale 01/08/2026"(卖的那一批 + 售出日;与 "PO-… line N" 同一种说法),外加 href 指向它的应收页
--     (Q14:销售没有 code 列,所以【不】进 document_types —— 进了,全站搜索会对它拼一句 SELECT code,当场报错;
--      Record 一栏的名字与链接由这里与 trail_row_record 给,与单据同一个形状);
--   · 汇率 → "USD · TT selling rate · 01/08/2026";对账单行 → "BS-… line N";分录行 → "JE-… · 科目";申报格 → "Box 1";
--     对账记录 → "BS-… reconciliation DD/MM/YYYY";折旧 → "FA-… · period ending DD/MM/YYYY"。
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a):这几张也没有编号或名字 ——
--   · 财务设置那一行 → "Finance settings";公司资料那一行 → "Company profile"(两张都是单行表,id = true);
--   · 月结 → "Period ending DD/MM/YYYY";年结 → "Year ending DD/MM/YYYY";
--   · 行内转账 → "Transfer DD/MM/YYYY · Cash at Bank – SGD → Cash at Bank – USD"(两头按科目表的名字说,不说 1000 / 1010)。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a):
--   · 登录账号('auth.users')多带一个 label —— 认得出的那个人的名字(trail_actor 同一份答法:不持 hr.view 的读者只认得出
--     自己):/settings/change-history 的 Record 一栏(授权、附加账号的家是账号,Q22)读 label,不读 person。认不出就没有名字,
--     界面说 "a login account" —— 【不】回落到邮箱(那是账号的身份数据,不是它的名字)。
--   · 培训记录 → 培训的名字;导入批次 → 文件名(两张表都没有 name / title / label 一类的列)。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a · Q36):
--   · 假期发放 → "Annual leave 2027"(假别的英文名 + 那一个假期年;那张表没有名字一类的列);
--   · 加班批 → 它的 label("OT 2026-10 #1",照旧),外加 href 指向 /hr/overtime/<id>。加班批没有 code 列,所以它【不】进
--     document_types(全站搜索会对登记的每一张表拼一句 SELECT code —— 销售那一刀记过同一个理由);链接在这里给,与销售同一个形状。
-- 【属主身份】按表名动态读;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_ref_label(p_table text, p_column text, p_value text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_gone  boolean := false;
    v_label text;
    v_doc   boolean;
    v_extra text;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'auth.users' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        v_img := trail_actor('prelog', p_value::uuid, NULL);
        RETURN jsonb_build_object('person', v_img, 'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'employees' AND p_column = 'id' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        -- label 一并带回(只在认得出名字时):/settings/change-history 的 Record 一栏读 label,不读 person
        v_img := trail_actor('prelog', NULL, p_value::uuid);
        RETURN jsonb_build_object('person', v_img, 'gone', false,
                                  'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I::text = $1 LIMIT 1', p_table, p_column)
       INTO v_img USING p_value;
    IF v_img IS NULL THEN
        v_gone := true;
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_img
          FROM change_log c
         WHERE c.table_name = p_table AND c.row_key = jsonb_build_object(p_column, p_value)
           AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
        IF v_img IS NULL THEN
            RETURN jsonb_build_object('label', NULL, 'gone', true);
        END IF;
    END IF;
    v_doc := EXISTS (SELECT 1 FROM document_types d WHERE d.table_name = p_table);
    v_label := CASE
        WHEN p_table = 'employees' THEN
            CASE WHEN v_img ->> 'anonymised_at' IS NULL
                 THEN COALESCE(NULLIF(v_img ->> 'preferred_name', ''), v_img ->> 'legal_name') END
        WHEN p_table IN ('suppliers', 'customers') THEN v_img ->> 'legal_name'
        WHEN p_table = 'materials' THEN v_img ->> 'name'
        WHEN p_table = 'currencies' THEN v_img ->> 'code'
        WHEN p_table = 'training_records' THEN v_img ->> 'training_name'
        WHEN p_table = 'import_batches' THEN v_img ->> 'file_name'
        WHEN p_table = 'purchase_order_lines' THEN
            (SELECT po.code FROM purchase_orders po WHERE po.id::text = v_img ->> 'purchase_order_id')
            || ' line ' || (v_img ->> 'line_no')
        WHEN v_doc AND v_img ? 'code' THEN v_img ->> 'code'
        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'
        WHEN v_img ? 'name' THEN v_img ->> 'name'
        WHEN v_img ? 'legal_name' THEN v_img ->> 'legal_name'
        WHEN v_img ? 'title' THEN v_img ->> 'title'
        WHEN v_img ? 'label' THEN v_img ->> 'label'
    END;
    IF p_table = 'shift_handovers' THEN
        v_label := to_char((v_img ->> 'handover_date')::date, 'DD/MM/YYYY')
                   || COALESCE(' · ' || (SELECT s.name_en FROM shifts s WHERE s.code = v_img ->> 'shift_code'), '');
    ELSIF p_table = 'equipment_downtime' THEN
        v_label := COALESCE((SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'equipment_id') || ' · ', '')
                   || to_char(((v_img ->> 'started_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY HH24:MI');
    ELSIF p_table IN ('sales_order_lines', 'quote_lines', 'invoice_lines') THEN
        -- AUDIT-TRAIL-1b-2:订单 / 报价的明细行 → "SO-2026-0001 line 1"(与采购单明细同一种说法)
        -- AUDIT-TRAIL-1c-1:发票明细行同一种说法(贷项通知的每一行冲的是发票的哪一行)
        v_label := CASE p_table
            WHEN 'sales_order_lines' THEN (SELECT so.code FROM sales_orders so WHERE so.id::text = v_img ->> 'sales_order_id')
            WHEN 'invoice_lines' THEN (SELECT i.code FROM invoices i WHERE i.id::text = v_img ->> 'invoice_id')
            ELSE (SELECT q.code FROM quotes q WHERE q.id::text = v_img ->> 'quote_id') END
            || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'ports' THEN
        -- 港口 → "SGSIN Singapore"(航段页、货代页上的同一种写法)
        v_label := concat_ws(' ', v_img ->> 'code', v_img ->> 'name');
    ELSIF p_table = 'lanes' THEN
        -- 航段没有名字 → "起运港 → 目的港"(两头各按港口那一句说)
        v_label := COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'origin_port_id'), '?')
                   || ' → ' ||
                   COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'destination_port_id'), '?');
    ELSIF p_table IN ('company_compliance', 'supplier_compliance') THEN
        -- 执照 / 证书 → "证书种类 · 编号"
        v_label := concat_ws(' · ', (SELECT ct.name_en FROM certificate_types ct WHERE ct.code = v_img ->> 'cert_type_code'),
                             NULLIF(v_img ->> 'cert_no', ''));
    ELSIF p_table IN ('customer_attachments', 'supplier_attachments') THEN
        v_label := v_img ->> 'file_name';
    ELSIF p_table = 'container_documents' THEN
        v_label := v_img ->> 'document_type';
    ELSIF p_table = 'sales_records' THEN
        v_label := COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id::text = v_img ->> 'output_batch_id') || ' sale ', 'Sale ')
                   || to_char((v_img ->> 'sale_date')::date, 'DD/MM/YYYY');
        RETURN jsonb_build_object('label', v_label, 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/finance/receivables/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'fx_rates' THEN
        v_label := concat_ws(' · ', v_img ->> 'currency',
                             CASE v_img ->> 'rate_type' WHEN 'tt_buy' THEN 'TT buying rate' WHEN 'tt_sell' THEN 'TT selling rate'
                                                        WHEN 'mid' THEN 'Mid rate' END,
                             to_char((v_img ->> 'rate_date')::date, 'DD/MM/YYYY'));
    ELSIF p_table = 'journal_lines' THEN
        -- 对账单的一行匹配到的那一行分录 → "JE-2026-0001 · Cash at Bank – SGD"(分录号 · 科目)
        v_label := concat_ws(' · ', (SELECT je.code FROM journal_entries je WHERE je.id::text = v_img ->> 'entry_id'),
                             (SELECT a.name_en FROM accounts a WHERE a.id::text = v_img ->> 'account_id'));
    ELSIF p_table = 'bank_statement_lines' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id') || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'gst_return_boxes' THEN
        v_label := 'Box ' || regexp_replace(v_img ->> 'box', '^box', '');
    ELSIF p_table = 'bank_reconciliations' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id')
                   || ' reconciliation ' || to_char(((v_img ->> 'reconciled_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY');
    ELSIF p_table = 'fixed_asset_depreciation' THEN
        v_label := (SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'asset_id')
                   || ' · period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'finance_settings' THEN
        v_label := 'Finance settings';
    ELSIF p_table = 'company_profile' THEN
        v_label := 'Company profile';
    ELSIF p_table = 'period_closes' THEN
        v_label := 'Period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'year_closes' THEN
        v_label := 'Year ending ' || to_char((v_img ->> 'year_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'bank_transfers' THEN
        v_label := 'Transfer ' || to_char((v_img ->> 'transfer_date')::date, 'DD/MM/YYYY') || ' · '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'from_account'), '?') || ' → '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'to_account'), '?');
    ELSIF p_table = 'leave_grants' THEN
        v_label := concat_ws(' ', (SELECT lt.name_en FROM leave_types lt WHERE lt.code = v_img ->> 'leave_type_code'), v_img ->> 'leave_year');
    ELSIF p_table = 'overtime_batches' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/hr/overtime/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'processing_runs' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'ended', v_img ->> 'deleted_at' IS NOT NULL);
    END IF;
    IF p_table = 'materials' THEN
        -- AUDIT-TRAIL-1b-2:物料带回它的单位 —— 订单 / 报价的明细行没有单位列,"10"要说成"10 kg"
        --   只在影像里真有单位时才带(一份早于变更记录、只剩名字的影像不说单位 —— 与"名字 + gone"那一形状逐字相同)
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN v_img ->> 'unit' IS NOT NULL THEN jsonb_build_object('unit', v_img ->> 'unit') ELSE '{}'::jsonb END;
    END IF;
    IF p_table IN ('inbound_batches', 'output_batches') THEN
        IF v_img ->> 'material_id' IS NOT NULL THEN
            SELECT m.name INTO v_extra FROM materials m WHERE m.id::text = v_img ->> 'material_id';
            IF v_extra IS NOT NULL THEN
                v_label := v_label || ' · ' || v_extra;
            END IF;
        END IF;
        -- 批次的数量单位随名字一起带回 —— 加工单的"用了 300"要说成"300 kg",而投入 / 产出行自己没有单位列
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'unit', v_img ->> 'unit');
    END IF;
    RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
           || COALESCE((SELECT jsonb_build_object('href', d.route || '/' || p_value) FROM document_types d
                         WHERE d.table_name = p_table AND d.link_mode = 'detail' AND p_column = 'id' AND NOT v_gone
                         ORDER BY d.key LIMIT 1), '{}'::jsonb);
END;
$function$;

-- db/functions/trail_row_record.sql
-- AUDIT-TRAIL-1a(Tim 的 Q30):/settings/change-history 的"Record"一栏 —— 一行记录【属于哪一张单据 / 哪一条记录】。
--   先后:① 这张表本身是单据(document_types)→ 它自己;② 它是某个审计记录主语的子行 / 孙行 / 相关行
--   (trail_subject_members)→ 沿父键走到那条根记录;③ 它有一列指着某张单据 → 那张单据;④ 都不是 → 它自己。
--   返回 {"table", "id", "label", "gone", "doc_key", "route", "link_mode"}(后三项只在它是单据时有,界面据此造链接)。
--   外键值从这一次的影像取,取不到再取这一行今天的样子(一次编辑只记改了的那几列)。
-- AUDIT-TRAIL-1b-1:同一张表挂在几个主语下时(加工投入既在加工单上、也在批次上;approval_log 按 subject_type 分给
--   十来种单据),只沿【home】的那一条、并且【match 对得上这一行】、外键有值的那一条往上走 —— 否则汇总页的 Record 一栏
--   会随登记表的字母顺序变,一次加工投入突然"属于"一个批次。往上一跳的垫脚石(hop = 'up')从不参与。
-- AUDIT-TRAIL-1c-2(Tim 的 Q14):销售是一个主语的根了 —— 它那一行(与沿 home 走上来的子行)的家是【这一笔销售】,
--   链接落在它的应收页 /finance/receivables/<id>。销售没有 code 列,所以它【不】进 document_types(全站搜索会对登记的
--   每一张表拼一句 SELECT code);名字由 trail_ref_label 给,路由在这里给,与单据同一个形状(doc_key 'sale',link_mode 'detail')。
-- AUDIT-TRAIL-1d-2(Q36):加班批同一个形状 —— 没有 code 列,不进 document_types;链接落在 /hr/overtime/<id>(doc_key 'overtime_batch')。
-- 【属主身份】EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_row_record(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_cur   record;
    v_table text := p_table;
    v_id    text;
    v_pk    text[];
    m       record;
    f       record;
    v_hops  integer := 0;
    v_lab   jsonb;
    v_dkey  text;
    v_route text;
    v_mode  text;
BEGIN
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_cur FROM trail_current_image(p_table, p_key);
    v_img := COALESCE(v_cur.image, '{}'::jsonb) || COALESCE(p_old, '{}'::jsonb) || COALESCE(p_new, '{}'::jsonb);
    v_pk := trail_pk_columns(p_table);
    v_id := CASE WHEN cardinality(v_pk) = 1 THEN p_key ->> v_pk[1] END;

    IF NOT EXISTS (SELECT 1 FROM document_types dt WHERE dt.table_name = p_table)
       AND NOT EXISTS (SELECT 1 FROM trail_subjects() ts WHERE ts.root_table = p_table) THEN
        -- ② 登记过的子行:沿父键往上走,最多三跳
        --   AUDIT-TRAIL-1c-1(M7):hop = 'all' 的家是那个单行设置表本身 —— 没有外键可走,那一行的键取它唯一那一行的根键
        LOOP
            SELECT tm.* INTO m FROM trail_subject_members() tm
             WHERE tm.table_name = v_table AND tm.home AND v_img @> tm.match
               AND ((tm.hop = 'down' AND v_img ->> tm.fk_column IS NOT NULL)
                    OR (tm.hop = 'all' AND EXISTS (SELECT 1 FROM trail_subjects() ts
                                                    WHERE ts.subject = tm.subject AND ts.root_table = tm.parent_table)))
             ORDER BY tm.subject, tm.ord LIMIT 1;
            EXIT WHEN NOT FOUND OR v_hops >= 3;
            v_table := m.parent_table;
            IF m.hop = 'all' THEN
                EXECUTE format('SELECT t.%I::text FROM public.%I t LIMIT 1',
                               (SELECT ts.root_key FROM trail_subjects() ts WHERE ts.subject = m.subject), v_table)
                   INTO v_id;
            ELSE
                v_id := v_img ->> m.fk_column;
            END IF;
            v_hops := v_hops + 1;
            SELECT * INTO v_cur FROM trail_current_image(v_table, jsonb_build_object('id', v_id));
            v_img := COALESCE(v_cur.image, '{}'::jsonb);
        END LOOP;
        -- ③ 没走动:找第一列指着单据的外键
        IF v_hops = 0 THEN
            FOR f IN SELECT ft.* FROM trail_fk_targets(p_table) ft
                      WHERE ft.target_table IN (SELECT dt.table_name FROM document_types dt)
                        AND ft.column_name NOT IN ('created_by', 'updated_by') LOOP
                IF v_img ->> f.column_name IS NOT NULL THEN
                    v_table := f.target_table;
                    v_id := v_img ->> f.column_name;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
    END IF;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('table', v_table, 'id', NULL, 'label', NULL, 'gone', false);
    END IF;
    v_lab := trail_ref_label(v_table, COALESCE((trail_pk_columns(v_table))[1], 'id'), v_id);
    SELECT dt.key, dt.route, dt.link_mode INTO v_dkey, v_route, v_mode FROM document_types dt WHERE dt.table_name = v_table ORDER BY dt.key LIMIT 1;
    IF v_table = 'sales_records' THEN
        v_dkey := 'sale'; v_route := '/finance/receivables'; v_mode := 'detail';
    ELSIF v_table = 'overtime_batches' THEN
        v_dkey := 'overtime_batch'; v_route := '/hr/overtime'; v_mode := 'detail';
    END IF;
    RETURN jsonb_build_object('table', v_table, 'id', v_id,
        'label', v_lab ->> 'label', 'gone', COALESCE((v_lab ->> 'gone')::boolean, false),
        'doc_key', v_dkey, 'route', v_route, 'link_mode', v_mode);
END;
$function$;

-- ── 2 · document_types(Q36):医疗报销与考勤期间链到它们的详情页(两页早就在)──────────────────────────
UPDATE document_types SET link_mode = 'detail' WHERE key IN ('medical_claim', 'attendance_period') AND link_mode = 'list';

-- ── 3 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.at1d2_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE at1d2_pending_after ON COMMIT DROP AS
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
    v_rows int;
    t      record;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1d2_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1d2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D2_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D2_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 只多 document_types 那两行(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1d2_pending_before b EXCEPT SELECT a.k, a.id FROM at1d2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1d2_pending_after a EXCEPT SELECT b.k, b.id FROM at1d2_pending_before b)) THEN
        RAISE EXCEPTION 'AT1D2_PROOF|a pending document changed state';
    END IF;
    -- 唯一的新行是 document_types 那两行改动(Q36:种子表也有变更记录)—— 恰好两行,别的一行都不许多
    IF (SELECT count(*) FROM change_log WHERE seq > (SELECT mx FROM at1d2_log_before)) <> 2
       OR EXISTS (SELECT 1 FROM change_log WHERE seq > (SELECT mx FROM at1d2_log_before) AND (table_name <> 'document_types' OR op <> 'UPDATE'))
       OR (SELECT n FROM at1d2_log_before) + 2 <> (SELECT count(*) FROM change_log) THEN
        RAISE EXCEPTION 'AT1D2_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1d2_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:七十七个主语;每一个 shown 成员表与根表都在 change_log 的覆盖里;执行权
    IF (SELECT count(*) FROM trail_subjects()) <> 77 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|expected 77 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT x.t, ', ') INTO v_bad FROM (
        SELECT m.table_name AS t FROM trail_subject_members() m WHERE m.shown
        UNION SELECT s.root_table FROM trail_subjects() s) x
     -- M9:只在变更记录里出现的表没有触发器(它的事件由 record_account_event 写)
     WHERE x.t NOT IN (SELECT l.table_name FROM trail_log_only_tables() l)
       AND
           NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                        WHERE tr.event_object_table = x.t AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D2_PROOF|member or root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D2_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D2_PROOF|anon can execute %', f;
        END IF;
    END LOOP;
    -- 七个账号一个都没有被停(本刀不碰账号)
    IF (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) <> 0 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|an account is disabled';
    END IF;

    -- ⑤ 真的读:以 admin@ 把新主语在线上的每一条记录读一遍(被拒 = 坏了);费用(Q37 多了成员)、员工、采购单各读几条,证登记表换过之后照旧。
    PERFORM set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true);
    v_n := 0;
    FOR t IN SELECT 'leave_request' AS s, id::text AS id FROM leave_requests
             UNION ALL SELECT 'leave_grant', id::text FROM leave_grants
             UNION ALL SELECT 'leave_types', 'all'
             UNION ALL SELECT 'public_holidays', 'all'
             UNION ALL SELECT 'medical_claim', id::text FROM medical_claims
             UNION ALL SELECT 'overtime_batch', id::text FROM overtime_batches
             UNION ALL SELECT 'attendance_period', id::text FROM attendance_periods
             UNION ALL (SELECT 'expense', id::text FROM expenses ORDER BY created_at LIMIT 3)
             UNION ALL (SELECT 'employee', id::text FROM employees ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'purchase_order', id::text FROM purchase_orders ORDER BY created_at LIMIT 1) LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D2_PROOF|% % refused for admin@: %', t.s, t.id, SQLERRM;
        END;
        -- 每一条有它的建立(记录开始之前的那一行,或之后的 INSERT);假别与公共假期两本集合都有建立的时刻,不会是空的
        IF v_rows = 0 THEN
            RAISE EXCEPTION 'AT1D2_PROOF|% % has an empty trail for admin@', t.s, t.id;
        END IF;
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'AT1D2 read % records as admin@, none refused', v_n;
    -- M8:本人读得到自己的请假与医疗报销(/me 那两块),以本人的身份
    v_m := 0;
    FOR t IN SELECT 'my_leave_request' AS s, l.id::text AS id, e.user_id AS u FROM leave_requests l JOIN employees e ON e.id = l.employee_id WHERE e.user_id IS NOT NULL
             UNION ALL SELECT 'my_medical_claim', m.id::text, e.user_id FROM medical_claims m JOIN employees e ON e.id = m.employee_id WHERE e.user_id IS NOT NULL LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', t.u), true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D2_PROOF|% % refused for its own employee: %', t.s, t.id, SQLERRM;
        END;
        v_m := v_m + 1;
    END LOOP;
    RAISE NOTICE 'AT1D2 read % own records as their employee, none refused', v_m;
    PERFORM set_config('request.jwt.claims', '', true);

    -- Q36:两行登记改成了详情页
    IF (SELECT count(*) FROM document_types WHERE key IN ('medical_claim', 'attendance_period') AND link_mode = 'detail') <> 2 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|document_types not pointing at the detail pages';
    END IF;

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1d2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1D2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1d2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1d2_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1d2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
