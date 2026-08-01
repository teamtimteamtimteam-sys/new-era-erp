-- db/migrations/2026-08-01-perm2a-module-enforcement.sql
-- Permissions cut 2a: module-level access becomes REAL at the database layer.
--
-- ════════════════════════════════════════════════════════════════════════════
-- 本切是整个项目风险最高的一次迁移:改错了,活着的会计系统会把所有人关在门外。
-- 因此三件事必须同时成立 ——
--   (1) 策略【严格且字面】:一张表属于一个模块,读要 view,写要 edit,没有 OR 逃生口。
--       能被审计的策略集必须是读起来一目了然的策略集。
--   (2) 【跨模块的写入不靠放宽策略解决,靠函数】:合法地写别的模块的函数变成
--       SECURITY DEFINER —— 一道受控的闸门,而不是一张通行证。
--   (3) 锁死可恢复:见文件末尾的 psql 恢复流程(已验证 postgres 角色 BYPASSRLS)。
--
-- 【为什么不给 warehouse 发一个 action.post_journal】:那等于允许持有它的人直接调用
-- post_journal_entry 伪造任意会计分录 —— 对具有法律意义的记录而言,那正是数据库层
-- 强制执行本来要堵上的洞。闸门必须是【函数】,不是【权限码】。
-- ════════════════════════════════════════════════════════════════════════════
--
-- Pieces:
--   B1. module.<m> 一分为二:module.<m>.view / module.<m>.edit(auditor 只拿 view)
--   B2. 表 → 模块映射(下表即权威参考,共 61 张表)
--   B3. 每张表四条按权限的策略,替换原来的 "authenticated full access"
--   B4. 跨模块函数改为受控闸门(触发器 / RPC 两种处理各不相同)
--   B5. 锁死恢复流程
--
-- 【edit 不蕴含 view】:策略里 SELECT 查 view、INSERT 查 edit,两者互不推导。
-- 只授 edit 不授 view 是一种【配置错误】,界面应当阻止;数据库这边的诚实结果是
-- "写得进去、读不出来",fixture 里有一条用例专门证明这一点。

-- ════════════════════ B2. 表 → 模块映射(权威参考)════════════════════
--
-- 参考类(任何登录用户可读,写入归属某个模块)—— 逐张说明理由:
--   accounts                 读 any authenticated / 写 module.finance.edit          — post_journal_entry 由每个模块的动作间接调用,记账时必须查得到科目
--   company_profile          读 any authenticated / 写 module.finance.edit          — 开票抬头与单据页眉,打印路径横跨财务与采购
--   currencies               读 any authenticated / 写 module.finance.edit          — 币种字典,采购/销售/财务界面都要渲染它
--   metal_prices             读 any authenticated / 写 module.pricing.edit          — 市场行情(LME 一类),不是本公司成本;成本在 pricing_formulas 里,那张表仍受 pricing 管
--   permissions              读 any authenticated / 写 (不可写)                        — 目录本身;界面要渲染权限名。解析器是 SECURITY DEFINER,不依赖这条策略
--   role_permissions         读 any authenticated / 写 action.manage_permissions    — 权限管理界面要渲染角色的授权
--   roles                    读 any authenticated / 写 action.manage_permissions    — 界面要渲染角色名
--   user_roles               读 any authenticated / 写 action.manage_permissions    — 界面要显示谁持有什么角色
--
-- 模块类:
--   module.suppliers    supplier_attachments, supplier_compliance, suppliers
--   module.customers    customer_attachments, customers
--   module.materials    material_attachments, materials
--   module.pricing      pricing_formula_metals, pricing_formulas
--   module.purchasing   payment_term_template_lines, payment_term_templates, purchase_order_lines, purchase_order_payment_terms, purchase_orders
--   module.inbound      assay_result_metals, assay_results, inbound_batch_metals, inbound_batches, price_history
--   module.output       output_batch_metals, output_batches
--   module.processing   processing_cost_entries, processing_inputs, processing_outputs, processing_runs
--   module.inventory    inventory_movements, storage_locations
--   module.stocktakes   stocktake_lines, stocktakes
--   module.finance      bank_import_profiles, bank_line_matches, bank_statement_lines, bank_statements, expenses, finance_attachments, finance_settings, fx_rates, invoice_lines, invoices, journal_entries, journal_lines, payment_allocations, payments, period_closes, prepayment_applications, sales_records
--   module.hr           departments, employees, employment_history, payroll_lines, payroll_periods, training_records
--   module.tasks        tasks
--
-- 仅追加 / 不可变的表【保持原有形状】(只加权限条件,不新增动词):
--   employment_history       S+I
--   expenses                 S+I
--   inventory_movements      S+I
--   invoice_lines            S+I+U
--   invoices                 S+I+U
--   journal_entries          S+I
--   journal_lines            S+I
--   payment_allocations      S+I
--   payments                 S+I
--   period_closes            S+I+U
--   prepayment_applications  S+I
--   price_history            S+I
--   sales_records            S+I+U
--
-- ════════════════════ B4. 函数 → 所需权限(权威参考)════════════════════
--
-- (a) 触发器函数 → SECURITY DEFINER,【不做权限检查】。
--     它们只会作为一次【RLS 已经放行的基表写入】的后果而触发 —— 闸门是基表本身,
--     在这里重复检查只会变成日后漂移的噪音。
--     其中两条【出于正确性而非权限】必须是 DEFINER:check_ledger_invariant 与
--     check_journal_balance 是 DEFERRED 约束触发器,在 COMMIT 时触发,那时已经不在
--     任何 DEFINER 上下文里;若按调用者身份运行,它们会对【被 RLS 隐藏的行】求和,
--     于是 0 = 0 —— 不平的分录会静悄悄地通过。这是错误答案,不是权限报错。
--       emit_batch_receipt_movement
--       emit_batch_writeoff_movement
--       advance_po_on_receipt
--       guard_inbound_po_line_match
--       guard_inbound_po_receivable
--       fin_journal_cost_entry
--       check_ledger_invariant
--       check_journal_balance
--
-- (b) RPC 入口 → SECURITY DEFINER + 顶部 require_permission()。
--     DEFINER 意味着不检查的话【任何登录用户都能调用】。每个函数检查的是
--     【它所执行的那个动作】的权限,不是它顺带碰到的那些表的权限。
--     失败一律 RAISE 'PERMISSION_DENIED|<code>',界面拿一个码去做本地化。
--
--     function                         required permission
--       allocate_processing_costs        module.processing.edit
--       apply_assay_result               module.inbound.edit
--       apply_payment_term_template      module.purchasing.edit
--       apply_prepayment                 module.finance.edit
--       cancel_purchase_order            module.purchasing.edit
--       cancel_stocktake                 module.stocktakes.edit
--       close_period                     module.finance.edit
--       close_purchase_order             module.purchasing.edit
--       commit_processing_run            module.processing.edit
--       create_invoice                   module.finance.edit
--       create_purchase_order            module.purchasing.edit
--       ignore_bank_line                 module.finance.edit
--       import_bank_statement            module.finance.edit
--       match_bank_line                  module.finance.edit
--       post_payroll_period              module.hr.edit
--       post_stocktake                   module.stocktakes.edit
--       reconcile_statement              module.finance.edit
--       record_assay_result              module.inbound.edit
--       record_expense                   module.finance.edit
--       record_output_sale               module.output.edit
--       record_payment                   module.finance.edit
--       reopen_period                    module.finance.edit
--       reopen_purchase_order            module.purchasing.edit
--       reprice_inbound_batch            module.inbound.edit
--       reverse_expense                  module.finance.edit
--       reverse_journal_entry            module.finance.edit
--       reverse_payment                  module.finance.edit
--       rollback_processing_run          module.processing.edit
--       set_inbound_unit_price           module.inbound.edit
--       unapply_assay_result             module.inbound.edit
--       unignore_bank_line               module.finance.edit
--       unmatch_bank_line                module.finance.edit
--       unpost_payroll_period            module.hr.edit
--       unreconcile_statement            module.finance.edit
--       upsert_metal_prices              module.pricing.edit
--       upsert_payroll_period            module.hr.edit
--       void_invoice                     module.finance.edit
--
-- (c) post_journal_entry 保持 SECURITY INVOKER —— 本切的承重细节。
--     财务用户直接调用:过 RLS。仓储用户直接调用:被拒。从 DEFINER 函数里面调用:
--     以属主身份运行,放行。一个函数,三种都正确的结果,不需要任何特例。
--
-- 【偏离说明】reverse_journal_entry 没有跟着 post_journal_entry 留在 INVOKER。
--     它要 UPDATE journal_entries(status/reversed_by)并对同一行 SELECT ... FOR UPDATE,
--     而 journal_entries 保持仅追加形状(只有 SELECT + INSERT 策略,没有 UPDATE 策略)。
--     行锁会套用 UPDATE 策略,而这里一条都没有 —— 作为 INVOKER 它会对【所有人】失败,
--     财务和管理员也不例外。它本身就是一个 RPC 入口,因此按 (b) 处理。
--     顺带堵掉一个现存的洞:它今天是 DEFINER 且【没有任何检查】。
--
-- ════════════════════ B5. 锁死恢复流程(两分钟)════════════════════
--
-- 【已验证】postgres 角色 rolbypassrls = true(service_role 亦然;authenticated 为 false)。
-- 因此以 postgres 直连时 RLS 完全不生效,任何策略配错都救得回来。
--
--   $ psql "postgres://postgres.wvywpohbwkiinmipmuku:<DB_PASSWORD>@\
--           aws-1-ap-southeast-1.pooler.supabase.com:5432/postgres"
--
--   -- 1) 看看自己到底有什么(把 <uid> 换成 auth.users 里的 id)
--   SELECT r.code, rp.permission_code
--   FROM user_roles ur JOIN roles r ON r.id = ur.role_id
--   LEFT JOIN role_permissions rp ON rp.role_id = r.id
--   WHERE ur.user_id = '<uid>' AND ur.revoked_at IS NULL;
--
--   -- 2) 把管理员补回去
--   INSERT INTO user_roles (user_id, role_id)
--   SELECT '<uid>', id FROM roles WHERE code = 'admin'
--   ON CONFLICT DO NOTHING;
--
--   -- 3) 最后手段:整张表先摘掉强制执行,救完再开回来
--   ALTER TABLE public.<table> DISABLE ROW LEVEL SECURITY;
--   -- ... 修复 ...
--   ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY;
--
-- 【不要】往策略里加 "OR admin_bypass_active()" 之类的兜底:那会把一个坏掉的
-- 解析器悄悄掩盖过去,让系统看上去是好的。恢复靠上面这条带外通道,不靠策略。
--
-- NOTE: applied to project wvywpohbwkiinmipmuku via the Management API.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ============================================================================
-- B1. module.<m> 一分为二
-- ============================================================================
-- 今天一个模块只有一个码,于是"能进"与"能改"是同一件事 —— auditor 这个角色
-- 因此根本无法表达(能进就意味着能改)。拆成 .view / .edit 之后才说得清楚。

-- 先把【拆分前】的模块授权留一份快照,否则下面两条 INSERT 会把刚插进去的
-- .view 行当成"旧码"再拆一次。
CREATE TEMP TABLE _old_module_grants ON COMMIT DROP AS
SELECT rp.role_id, rp.permission_code, r.code AS role_code
FROM role_permissions rp
JOIN permissions p ON p.code = rp.permission_code
JOIN roles r ON r.id = rp.role_id
WHERE p.category = 'module';

-- 新码:每个模块两条。名称与描述沿用原条目,后缀区分。
WITH base AS (
    SELECT * FROM permissions WHERE category = 'module'
)
INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order)
SELECT code || '.view', category, name_en || ' (view)', name_zh || '(查看)',
       COALESCE(description_en, name_en) || ' — read only',
       COALESCE(description_zh, name_zh) || ' —— 只读',
       sort_order
FROM base
UNION ALL
SELECT code || '.edit', category, name_en || ' (edit)', name_zh || '(编辑)',
       COALESCE(description_en, name_en) || ' — create, change, remove',
       COALESCE(description_zh, name_zh) || ' —— 新建、修改、删除',
       sort_order + 1
FROM base;

-- 授权迁移:原来持有 module.<m> 的角色两个码都拿到 ——
-- 【auditor 例外,只拿 .view】。auditor 的只读【由授权表达】,不再靠"策略少放行"来假装。
INSERT INTO role_permissions (role_id, permission_code)
SELECT role_id, permission_code || '.view' FROM _old_module_grants;

INSERT INTO role_permissions (role_id, permission_code)
SELECT role_id, permission_code || '.edit' FROM _old_module_grants
WHERE role_code <> 'auditor';

-- 旧的单码退休(先撤授权,role_permissions 的 FK 是 ON DELETE RESTRICT)
DELETE FROM role_permissions
WHERE permission_code IN (SELECT permission_code FROM _old_module_grants);

DELETE FROM permissions
WHERE category = 'module' AND code NOT LIKE '%.view' AND code NOT LIKE '%.edit';

-- 动作类权限:目录里第一条 'action'。
-- 【只有它一个】—— 跨模块写入靠函数闸门解决,不靠再发一批 action 码。
INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.manage_permissions', 'action', 'Manage roles & permissions', '管理角色与权限', 'Create roles and change who holds what', '新建角色、调整授权', 300);

-- 只发给管理员:改权限本身是管理员的事。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'action.manage_permissions' FROM roles r WHERE r.code = 'admin';

-- ============================================================================
-- B3. 策略:每张表按权限重建
-- ============================================================================
-- 命名一律 "<table> <verb> by permission",于是下一次审计是机械的:
--   SELECT polname FROM pg_policy ... WHERE polname NOT LIKE '%by permission';
-- 【不可变触发器一律不碰】—— 它们与权限正交,必须继续照常触发。

-- ---- accounts (reference: read by any authenticated)
DROP POLICY "authenticated full access on accounts" ON public.accounts;
CREATE POLICY "accounts select by permission"
    ON public.accounts AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "accounts insert by permission"
    ON public.accounts AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "accounts update by permission"
    ON public.accounts AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "accounts delete by permission"
    ON public.accounts AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- assay_result_metals (inbound)
DROP POLICY "authenticated full access on assay_result_metals" ON public.assay_result_metals;
CREATE POLICY "assay_result_metals select by permission"
    ON public.assay_result_metals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'));
CREATE POLICY "assay_result_metals insert by permission"
    ON public.assay_result_metals AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "assay_result_metals update by permission"
    ON public.assay_result_metals AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit')) WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "assay_result_metals delete by permission"
    ON public.assay_result_metals AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'));

-- ---- assay_results (inbound)
DROP POLICY "authenticated full access on assay_results" ON public.assay_results;
CREATE POLICY "assay_results select by permission"
    ON public.assay_results AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'));
CREATE POLICY "assay_results insert by permission"
    ON public.assay_results AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "assay_results update by permission"
    ON public.assay_results AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit')) WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "assay_results delete by permission"
    ON public.assay_results AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'));

-- ---- bank_import_profiles (finance)
DROP POLICY "authenticated full access on bank_import_profiles" ON public.bank_import_profiles;
CREATE POLICY "bank_import_profiles select by permission"
    ON public.bank_import_profiles AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "bank_import_profiles insert by permission"
    ON public.bank_import_profiles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_import_profiles update by permission"
    ON public.bank_import_profiles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_import_profiles delete by permission"
    ON public.bank_import_profiles AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- bank_line_matches (finance)
DROP POLICY "authenticated full access on bank_line_matches" ON public.bank_line_matches;
CREATE POLICY "bank_line_matches select by permission"
    ON public.bank_line_matches AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "bank_line_matches insert by permission"
    ON public.bank_line_matches AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_line_matches update by permission"
    ON public.bank_line_matches AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_line_matches delete by permission"
    ON public.bank_line_matches AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- bank_statement_lines (finance)
DROP POLICY "authenticated full access on bank_statement_lines" ON public.bank_statement_lines;
CREATE POLICY "bank_statement_lines select by permission"
    ON public.bank_statement_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "bank_statement_lines insert by permission"
    ON public.bank_statement_lines AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_statement_lines update by permission"
    ON public.bank_statement_lines AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_statement_lines delete by permission"
    ON public.bank_statement_lines AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- bank_statements (finance)
DROP POLICY "authenticated full access on bank_statements" ON public.bank_statements;
CREATE POLICY "bank_statements select by permission"
    ON public.bank_statements AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "bank_statements insert by permission"
    ON public.bank_statements AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_statements update by permission"
    ON public.bank_statements AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "bank_statements delete by permission"
    ON public.bank_statements AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- company_profile (reference: read by any authenticated)
DROP POLICY "authenticated full access on company_profile" ON public.company_profile;
CREATE POLICY "company_profile select by permission"
    ON public.company_profile AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "company_profile insert by permission"
    ON public.company_profile AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "company_profile update by permission"
    ON public.company_profile AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "company_profile delete by permission"
    ON public.company_profile AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- currencies (reference: read by any authenticated)
DROP POLICY "authenticated full access on currencies" ON public.currencies;
CREATE POLICY "currencies select by permission"
    ON public.currencies AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "currencies insert by permission"
    ON public.currencies AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "currencies update by permission"
    ON public.currencies AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "currencies delete by permission"
    ON public.currencies AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- customer_attachments (customers)
DROP POLICY "authenticated full access on customer_attachments" ON public.customer_attachments;
CREATE POLICY "customer_attachments select by permission"
    ON public.customer_attachments AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.customers.view'));
CREATE POLICY "customer_attachments insert by permission"
    ON public.customer_attachments AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.customers.edit'));
CREATE POLICY "customer_attachments update by permission"
    ON public.customer_attachments AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.customers.edit')) WITH CHECK (has_permission('module.customers.edit'));
CREATE POLICY "customer_attachments delete by permission"
    ON public.customer_attachments AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.customers.edit'));

-- ---- customers (customers)
DROP POLICY "authenticated full access on customers" ON public.customers;
CREATE POLICY "customers select by permission"
    ON public.customers AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.customers.view'));
CREATE POLICY "customers insert by permission"
    ON public.customers AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.customers.edit'));
CREATE POLICY "customers update by permission"
    ON public.customers AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.customers.edit')) WITH CHECK (has_permission('module.customers.edit'));
CREATE POLICY "customers delete by permission"
    ON public.customers AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.customers.edit'));

-- ---- departments (hr)
DROP POLICY "authenticated full access on departments" ON public.departments;
CREATE POLICY "departments select by permission"
    ON public.departments AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "departments insert by permission"
    ON public.departments AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "departments update by permission"
    ON public.departments AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "departments delete by permission"
    ON public.departments AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ---- employees (hr)
DROP POLICY "authenticated full access on employees" ON public.employees;
CREATE POLICY "employees select by permission"
    ON public.employees AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "employees insert by permission"
    ON public.employees AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "employees update by permission"
    ON public.employees AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "employees delete by permission"
    ON public.employees AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ---- employment_history (hr)
DROP POLICY "authenticated insert on employment_history" ON public.employment_history;
DROP POLICY "authenticated select on employment_history" ON public.employment_history;
CREATE POLICY "employment_history select by permission"
    ON public.employment_history AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "employment_history insert by permission"
    ON public.employment_history AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));

-- ---- expenses (finance)
DROP POLICY "authenticated insert on expenses" ON public.expenses;
DROP POLICY "authenticated select on expenses" ON public.expenses;
CREATE POLICY "expenses select by permission"
    ON public.expenses AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "expenses insert by permission"
    ON public.expenses AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));

-- ---- finance_attachments (finance)
DROP POLICY "authenticated full access on finance_attachments" ON public.finance_attachments;
CREATE POLICY "finance_attachments select by permission"
    ON public.finance_attachments AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "finance_attachments insert by permission"
    ON public.finance_attachments AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "finance_attachments update by permission"
    ON public.finance_attachments AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "finance_attachments delete by permission"
    ON public.finance_attachments AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- finance_settings (finance)
DROP POLICY "authenticated full access on finance_settings" ON public.finance_settings;
CREATE POLICY "finance_settings select by permission"
    ON public.finance_settings AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "finance_settings insert by permission"
    ON public.finance_settings AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "finance_settings update by permission"
    ON public.finance_settings AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "finance_settings delete by permission"
    ON public.finance_settings AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- fx_rates (finance)
DROP POLICY "authenticated full access on fx_rates" ON public.fx_rates;
CREATE POLICY "fx_rates select by permission"
    ON public.fx_rates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "fx_rates insert by permission"
    ON public.fx_rates AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "fx_rates update by permission"
    ON public.fx_rates AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "fx_rates delete by permission"
    ON public.fx_rates AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'));

-- ---- inbound_batch_metals (inbound)
DROP POLICY "authenticated full access on inbound_batch_metals" ON public.inbound_batch_metals;
CREATE POLICY "inbound_batch_metals select by permission"
    ON public.inbound_batch_metals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'));
CREATE POLICY "inbound_batch_metals insert by permission"
    ON public.inbound_batch_metals AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "inbound_batch_metals update by permission"
    ON public.inbound_batch_metals AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit')) WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "inbound_batch_metals delete by permission"
    ON public.inbound_batch_metals AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'));

-- ---- inbound_batches (inbound)
DROP POLICY "authenticated full access on inbound_batches" ON public.inbound_batches;
CREATE POLICY "inbound_batches select by permission"
    ON public.inbound_batches AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'));
CREATE POLICY "inbound_batches insert by permission"
    ON public.inbound_batches AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "inbound_batches update by permission"
    ON public.inbound_batches AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit')) WITH CHECK (has_permission('module.inbound.edit'));
CREATE POLICY "inbound_batches delete by permission"
    ON public.inbound_batches AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'));

-- ---- inventory_movements (inventory)
DROP POLICY "authenticated insert on inventory_movements" ON public.inventory_movements;
DROP POLICY "authenticated select on inventory_movements" ON public.inventory_movements;
CREATE POLICY "inventory_movements select by permission"
    ON public.inventory_movements AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'));
CREATE POLICY "inventory_movements insert by permission"
    ON public.inventory_movements AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inventory.edit'));

-- ---- invoice_lines (finance)
DROP POLICY "authenticated insert on invoice_lines" ON public.invoice_lines;
DROP POLICY "authenticated select on invoice_lines" ON public.invoice_lines;
DROP POLICY "authenticated update on invoice_lines" ON public.invoice_lines;
CREATE POLICY "invoice_lines select by permission"
    ON public.invoice_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "invoice_lines insert by permission"
    ON public.invoice_lines AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "invoice_lines update by permission"
    ON public.invoice_lines AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));

-- ---- invoices (finance)
DROP POLICY "authenticated insert on invoices" ON public.invoices;
DROP POLICY "authenticated select on invoices" ON public.invoices;
DROP POLICY "authenticated void on invoices" ON public.invoices;
CREATE POLICY "invoices select by permission"
    ON public.invoices AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "invoices insert by permission"
    ON public.invoices AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "invoices update by permission"
    ON public.invoices AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));

-- ---- journal_entries (finance)
DROP POLICY "authenticated insert on journal_entries" ON public.journal_entries;
DROP POLICY "authenticated select on journal_entries" ON public.journal_entries;
CREATE POLICY "journal_entries select by permission"
    ON public.journal_entries AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "journal_entries insert by permission"
    ON public.journal_entries AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));

-- ---- journal_lines (finance)
DROP POLICY "authenticated insert on journal_lines" ON public.journal_lines;
DROP POLICY "authenticated select on journal_lines" ON public.journal_lines;
CREATE POLICY "journal_lines select by permission"
    ON public.journal_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "journal_lines insert by permission"
    ON public.journal_lines AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));

-- ---- material_attachments (materials)
DROP POLICY "authenticated full access on material_attachments" ON public.material_attachments;
CREATE POLICY "material_attachments select by permission"
    ON public.material_attachments AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view'));
CREATE POLICY "material_attachments insert by permission"
    ON public.material_attachments AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'));
CREATE POLICY "material_attachments update by permission"
    ON public.material_attachments AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit')) WITH CHECK (has_permission('module.materials.edit'));
CREATE POLICY "material_attachments delete by permission"
    ON public.material_attachments AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.materials.edit'));

-- ---- materials (materials)
DROP POLICY "authenticated full access on materials" ON public.materials;
CREATE POLICY "materials select by permission"
    ON public.materials AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view'));
CREATE POLICY "materials insert by permission"
    ON public.materials AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'));
CREATE POLICY "materials update by permission"
    ON public.materials AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit')) WITH CHECK (has_permission('module.materials.edit'));
CREATE POLICY "materials delete by permission"
    ON public.materials AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.materials.edit'));

-- ---- metal_prices (reference: read by any authenticated)
DROP POLICY "authenticated full access on metal_prices" ON public.metal_prices;
CREATE POLICY "metal_prices select by permission"
    ON public.metal_prices AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "metal_prices insert by permission"
    ON public.metal_prices AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.pricing.edit'));
CREATE POLICY "metal_prices update by permission"
    ON public.metal_prices AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit')) WITH CHECK (has_permission('module.pricing.edit'));
CREATE POLICY "metal_prices delete by permission"
    ON public.metal_prices AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.pricing.edit'));

-- ---- output_batch_metals (output)
DROP POLICY "authenticated full access on output_batch_metals" ON public.output_batch_metals;
CREATE POLICY "output_batch_metals select by permission"
    ON public.output_batch_metals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'));
CREATE POLICY "output_batch_metals insert by permission"
    ON public.output_batch_metals AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.output.edit'));
CREATE POLICY "output_batch_metals update by permission"
    ON public.output_batch_metals AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.output.edit')) WITH CHECK (has_permission('module.output.edit'));
CREATE POLICY "output_batch_metals delete by permission"
    ON public.output_batch_metals AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.output.edit'));

-- ---- output_batches (output)
DROP POLICY "authenticated full access on output_batches" ON public.output_batches;
CREATE POLICY "output_batches select by permission"
    ON public.output_batches AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'));
CREATE POLICY "output_batches insert by permission"
    ON public.output_batches AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.output.edit'));
CREATE POLICY "output_batches update by permission"
    ON public.output_batches AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.output.edit')) WITH CHECK (has_permission('module.output.edit'));
CREATE POLICY "output_batches delete by permission"
    ON public.output_batches AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.output.edit'));

-- ---- payment_allocations (finance)
DROP POLICY "authenticated insert on payment_allocations" ON public.payment_allocations;
DROP POLICY "authenticated select on payment_allocations" ON public.payment_allocations;
CREATE POLICY "payment_allocations select by permission"
    ON public.payment_allocations AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "payment_allocations insert by permission"
    ON public.payment_allocations AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));

-- ---- payment_term_template_lines (purchasing)
DROP POLICY "authenticated full access on payment_term_template_lines" ON public.payment_term_template_lines;
CREATE POLICY "payment_term_template_lines select by permission"
    ON public.payment_term_template_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'));
CREATE POLICY "payment_term_template_lines insert by permission"
    ON public.payment_term_template_lines AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "payment_term_template_lines update by permission"
    ON public.payment_term_template_lines AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit')) WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "payment_term_template_lines delete by permission"
    ON public.payment_term_template_lines AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'));

-- ---- payment_term_templates (purchasing)
DROP POLICY "authenticated full access on payment_term_templates" ON public.payment_term_templates;
CREATE POLICY "payment_term_templates select by permission"
    ON public.payment_term_templates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'));
CREATE POLICY "payment_term_templates insert by permission"
    ON public.payment_term_templates AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "payment_term_templates update by permission"
    ON public.payment_term_templates AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit')) WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "payment_term_templates delete by permission"
    ON public.payment_term_templates AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'));

-- ---- payments (finance)
DROP POLICY "authenticated insert on payments" ON public.payments;
DROP POLICY "authenticated select on payments" ON public.payments;
CREATE POLICY "payments select by permission"
    ON public.payments AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "payments insert by permission"
    ON public.payments AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));

-- ---- payroll_lines (hr)
DROP POLICY "authenticated full access on payroll_lines" ON public.payroll_lines;
CREATE POLICY "payroll_lines select by permission"
    ON public.payroll_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "payroll_lines insert by permission"
    ON public.payroll_lines AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "payroll_lines update by permission"
    ON public.payroll_lines AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "payroll_lines delete by permission"
    ON public.payroll_lines AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ---- payroll_periods (hr)
DROP POLICY "authenticated full access on payroll_periods" ON public.payroll_periods;
CREATE POLICY "payroll_periods select by permission"
    ON public.payroll_periods AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "payroll_periods insert by permission"
    ON public.payroll_periods AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "payroll_periods update by permission"
    ON public.payroll_periods AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "payroll_periods delete by permission"
    ON public.payroll_periods AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ---- period_closes (finance)
DROP POLICY "authenticated insert on period_closes" ON public.period_closes;
DROP POLICY "authenticated select on period_closes" ON public.period_closes;
DROP POLICY "authenticated update on period_closes" ON public.period_closes;
CREATE POLICY "period_closes select by permission"
    ON public.period_closes AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "period_closes insert by permission"
    ON public.period_closes AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "period_closes update by permission"
    ON public.period_closes AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));

-- ---- permissions (reference: read by any authenticated)
DROP POLICY "authenticated select on permissions" ON public.permissions;
CREATE POLICY "permissions select by permission"
    ON public.permissions AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

-- ---- prepayment_applications (finance)
DROP POLICY "authenticated insert on prepayment_applications" ON public.prepayment_applications;
DROP POLICY "authenticated select on prepayment_applications" ON public.prepayment_applications;
CREATE POLICY "prepayment_applications select by permission"
    ON public.prepayment_applications AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "prepayment_applications insert by permission"
    ON public.prepayment_applications AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));

-- ---- price_history (inbound)
DROP POLICY "authenticated insert on price_history" ON public.price_history;
DROP POLICY "authenticated select on price_history" ON public.price_history;
CREATE POLICY "price_history select by permission"
    ON public.price_history AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'));
CREATE POLICY "price_history insert by permission"
    ON public.price_history AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'));

-- ---- pricing_formula_metals (pricing)
DROP POLICY "authenticated full access on pricing_formula_metals" ON public.pricing_formula_metals;
CREATE POLICY "pricing_formula_metals select by permission"
    ON public.pricing_formula_metals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'));
CREATE POLICY "pricing_formula_metals insert by permission"
    ON public.pricing_formula_metals AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.pricing.edit'));
CREATE POLICY "pricing_formula_metals update by permission"
    ON public.pricing_formula_metals AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit')) WITH CHECK (has_permission('module.pricing.edit'));
CREATE POLICY "pricing_formula_metals delete by permission"
    ON public.pricing_formula_metals AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.pricing.edit'));

-- ---- pricing_formulas (pricing)
DROP POLICY "authenticated full access on pricing_formulas" ON public.pricing_formulas;
CREATE POLICY "pricing_formulas select by permission"
    ON public.pricing_formulas AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'));
CREATE POLICY "pricing_formulas insert by permission"
    ON public.pricing_formulas AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.pricing.edit'));
CREATE POLICY "pricing_formulas update by permission"
    ON public.pricing_formulas AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit')) WITH CHECK (has_permission('module.pricing.edit'));
CREATE POLICY "pricing_formulas delete by permission"
    ON public.pricing_formulas AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.pricing.edit'));

-- ---- processing_cost_entries (processing)
DROP POLICY "authenticated full access on processing_cost_entries" ON public.processing_cost_entries;
CREATE POLICY "processing_cost_entries select by permission"
    ON public.processing_cost_entries AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'));
CREATE POLICY "processing_cost_entries insert by permission"
    ON public.processing_cost_entries AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_cost_entries update by permission"
    ON public.processing_cost_entries AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit')) WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_cost_entries delete by permission"
    ON public.processing_cost_entries AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'));

-- ---- processing_inputs (processing)
DROP POLICY "authenticated full access on processing_inputs" ON public.processing_inputs;
CREATE POLICY "processing_inputs select by permission"
    ON public.processing_inputs AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'));
CREATE POLICY "processing_inputs insert by permission"
    ON public.processing_inputs AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_inputs update by permission"
    ON public.processing_inputs AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit')) WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_inputs delete by permission"
    ON public.processing_inputs AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'));

-- ---- processing_outputs (processing)
DROP POLICY "authenticated full access on processing_outputs" ON public.processing_outputs;
CREATE POLICY "processing_outputs select by permission"
    ON public.processing_outputs AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'));
CREATE POLICY "processing_outputs insert by permission"
    ON public.processing_outputs AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_outputs update by permission"
    ON public.processing_outputs AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit')) WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_outputs delete by permission"
    ON public.processing_outputs AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'));

-- ---- processing_runs (processing)
DROP POLICY "authenticated full access on processing_runs" ON public.processing_runs;
CREATE POLICY "processing_runs select by permission"
    ON public.processing_runs AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'));
CREATE POLICY "processing_runs insert by permission"
    ON public.processing_runs AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_runs update by permission"
    ON public.processing_runs AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit')) WITH CHECK (has_permission('module.processing.edit'));
CREATE POLICY "processing_runs delete by permission"
    ON public.processing_runs AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'));

-- ---- purchase_order_lines (purchasing)
DROP POLICY "authenticated full access on purchase_order_lines" ON public.purchase_order_lines;
CREATE POLICY "purchase_order_lines select by permission"
    ON public.purchase_order_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'));
CREATE POLICY "purchase_order_lines insert by permission"
    ON public.purchase_order_lines AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "purchase_order_lines update by permission"
    ON public.purchase_order_lines AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit')) WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "purchase_order_lines delete by permission"
    ON public.purchase_order_lines AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'));

-- ---- purchase_order_payment_terms (purchasing)
DROP POLICY "authenticated full access on purchase_order_payment_terms" ON public.purchase_order_payment_terms;
CREATE POLICY "purchase_order_payment_terms select by permission"
    ON public.purchase_order_payment_terms AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'));
CREATE POLICY "purchase_order_payment_terms insert by permission"
    ON public.purchase_order_payment_terms AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "purchase_order_payment_terms update by permission"
    ON public.purchase_order_payment_terms AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit')) WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "purchase_order_payment_terms delete by permission"
    ON public.purchase_order_payment_terms AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'));

-- ---- purchase_orders (purchasing)
DROP POLICY "authenticated full access on purchase_orders" ON public.purchase_orders;
CREATE POLICY "purchase_orders select by permission"
    ON public.purchase_orders AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'));
CREATE POLICY "purchase_orders insert by permission"
    ON public.purchase_orders AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "purchase_orders update by permission"
    ON public.purchase_orders AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit')) WITH CHECK (has_permission('module.purchasing.edit'));
CREATE POLICY "purchase_orders delete by permission"
    ON public.purchase_orders AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'));

-- ---- role_permissions (reference: read by any authenticated)
DROP POLICY "authenticated full access on role_permissions" ON public.role_permissions;
CREATE POLICY "role_permissions select by permission"
    ON public.role_permissions AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "role_permissions insert by permission"
    ON public.role_permissions AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "role_permissions update by permission"
    ON public.role_permissions AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions')) WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "role_permissions delete by permission"
    ON public.role_permissions AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'));

-- ---- roles (reference: read by any authenticated)
DROP POLICY "authenticated full access on roles" ON public.roles;
CREATE POLICY "roles select by permission"
    ON public.roles AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "roles insert by permission"
    ON public.roles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "roles update by permission"
    ON public.roles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions')) WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "roles delete by permission"
    ON public.roles AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'));

-- ---- sales_records (finance)
DROP POLICY "authenticated insert on sales_records" ON public.sales_records;
DROP POLICY "authenticated select on sales_records" ON public.sales_records;
DROP POLICY "authenticated update on sales_records" ON public.sales_records;
CREATE POLICY "sales_records select by permission"
    ON public.sales_records AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'));
CREATE POLICY "sales_records insert by permission"
    ON public.sales_records AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'));
CREATE POLICY "sales_records update by permission"
    ON public.sales_records AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit')) WITH CHECK (has_permission('module.finance.edit'));

-- ---- stocktake_lines (stocktakes)
DROP POLICY "authenticated full access on stocktake_lines" ON public.stocktake_lines;
CREATE POLICY "stocktake_lines select by permission"
    ON public.stocktake_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.stocktakes.view'));
CREATE POLICY "stocktake_lines insert by permission"
    ON public.stocktake_lines AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.stocktakes.edit'));
CREATE POLICY "stocktake_lines update by permission"
    ON public.stocktake_lines AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.stocktakes.edit')) WITH CHECK (has_permission('module.stocktakes.edit'));
CREATE POLICY "stocktake_lines delete by permission"
    ON public.stocktake_lines AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.stocktakes.edit'));

-- ---- stocktakes (stocktakes)
DROP POLICY "authenticated full access on stocktakes" ON public.stocktakes;
CREATE POLICY "stocktakes select by permission"
    ON public.stocktakes AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.stocktakes.view'));
CREATE POLICY "stocktakes insert by permission"
    ON public.stocktakes AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.stocktakes.edit'));
CREATE POLICY "stocktakes update by permission"
    ON public.stocktakes AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.stocktakes.edit')) WITH CHECK (has_permission('module.stocktakes.edit'));
CREATE POLICY "stocktakes delete by permission"
    ON public.stocktakes AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.stocktakes.edit'));

-- ---- storage_locations (inventory)
DROP POLICY "authenticated full access on storage_locations" ON public.storage_locations;
CREATE POLICY "storage_locations select by permission"
    ON public.storage_locations AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'));
CREATE POLICY "storage_locations insert by permission"
    ON public.storage_locations AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inventory.edit'));
CREATE POLICY "storage_locations update by permission"
    ON public.storage_locations AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inventory.edit')) WITH CHECK (has_permission('module.inventory.edit'));
CREATE POLICY "storage_locations delete by permission"
    ON public.storage_locations AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inventory.edit'));

-- ---- supplier_attachments (suppliers)
DROP POLICY "authenticated full access on supplier_attachments" ON public.supplier_attachments;
CREATE POLICY "supplier_attachments select by permission"
    ON public.supplier_attachments AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'));
CREATE POLICY "supplier_attachments insert by permission"
    ON public.supplier_attachments AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "supplier_attachments update by permission"
    ON public.supplier_attachments AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit')) WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "supplier_attachments delete by permission"
    ON public.supplier_attachments AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.suppliers.edit'));

-- ---- supplier_compliance (suppliers)
DROP POLICY "authenticated full access on compliance" ON public.supplier_compliance;
CREATE POLICY "supplier_compliance select by permission"
    ON public.supplier_compliance AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'));
CREATE POLICY "supplier_compliance insert by permission"
    ON public.supplier_compliance AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "supplier_compliance update by permission"
    ON public.supplier_compliance AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit')) WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "supplier_compliance delete by permission"
    ON public.supplier_compliance AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.suppliers.edit'));

-- ---- suppliers (suppliers)
DROP POLICY "authenticated full access on suppliers" ON public.suppliers;
CREATE POLICY "suppliers select by permission"
    ON public.suppliers AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'));
CREATE POLICY "suppliers insert by permission"
    ON public.suppliers AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "suppliers update by permission"
    ON public.suppliers AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit')) WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "suppliers delete by permission"
    ON public.suppliers AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.suppliers.edit'));

-- ---- tasks (tasks)
DROP POLICY "authenticated full access on tasks" ON public.tasks;
CREATE POLICY "tasks select by permission"
    ON public.tasks AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.tasks.view'));
CREATE POLICY "tasks insert by permission"
    ON public.tasks AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.tasks.edit'));
CREATE POLICY "tasks update by permission"
    ON public.tasks AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.tasks.edit')) WITH CHECK (has_permission('module.tasks.edit'));
CREATE POLICY "tasks delete by permission"
    ON public.tasks AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.tasks.edit'));

-- ---- training_records (hr)
DROP POLICY "authenticated full access on training_records" ON public.training_records;
CREATE POLICY "training_records select by permission"
    ON public.training_records AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "training_records insert by permission"
    ON public.training_records AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "training_records update by permission"
    ON public.training_records AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "training_records delete by permission"
    ON public.training_records AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ---- user_roles (reference: read by any authenticated)
DROP POLICY "authenticated full access on user_roles" ON public.user_roles;
CREATE POLICY "user_roles select by permission"
    ON public.user_roles AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "user_roles insert by permission"
    ON public.user_roles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "user_roles update by permission"
    ON public.user_roles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions')) WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "user_roles delete by permission"
    ON public.user_roles AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'));

-- ============================================================================
-- B4. 跨模块函数 → 受控闸门
-- ============================================================================

-- 统一的检查入口。失败信息只有一个码,界面拿去本地化。
CREATE OR REPLACE FUNCTION public.require_permission(p_code text)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT has_permission(p_code) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', p_code;
    END IF;
END;
$function$;

-- ---------------------------------------------------------------- (a) 触发器
-- 【不做权限检查】:它们只作为一次已被 RLS 放行的基表写入的后果而触发。
-- 闸门是基表;在这里重复检查是会漂移的噪音。
-- emit_batch_receipt_movement
CREATE OR REPLACE FUNCTION public.emit_batch_receipt_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx text := current_setting('evoltrya.movement_ctx', true);
    v_run uuid;
BEGIN
    IF NEW.remaining_qty IS NULL OR NEW.remaining_qty <= 0 THEN
        RETURN NULL;
    END IF;

    IF TG_TABLE_NAME = 'inbound_batches' THEN
        INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, created_by)
        VALUES (NEW.id, 'receipt', NEW.remaining_qty, NEW.arrival_date, NEW.created_by);
    ELSE  -- output_batches
        IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'processing' THEN
            v_run := split_part(v_ctx, ':', 2)::uuid;
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
            VALUES (NEW.id, 'processing_produce', NEW.remaining_qty, v_run, NEW.output_date, NEW.created_by);
        ELSE
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, business_date, created_by)
            VALUES (NEW.id, 'receipt', NEW.remaining_qty, NEW.output_date, NEW.created_by);
        END IF;
    END IF;

    RETURN NULL;
END;
$function$
;

-- emit_batch_writeoff_movement
CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
BEGIN
    IF OLD.remaining_qty > 0 THEN
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, created_by)
            VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, created_by)
                VALUES (OLD.id, 'reversal_void', -OLD.remaining_qty, v_run, NEW.updated_by);
            ELSE
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, created_by)
                VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
            END IF;
        END IF;

        -- cut 2a:注销即入账(仅已计值批次,借 5200 / 贷 1200|1220)。
        -- processing 回滚(reversal_void)不入账:本 cut 不记加工产出/消耗分录,
        -- void 的产出从未入过 1220,无可冲销。未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                v_value := OLD.unit_price;
                v_acct := '1200';
            ELSE
                SELECT po.unit_cost_usd INTO v_value
                FROM public.processing_outputs po
                WHERE po.output_batch_id = OLD.id
                LIMIT 1;
                v_acct := '1220';
            END IF;
            IF v_value IS NOT NULL THEN
                v_amt := round(OLD.remaining_qty * v_value, 2);
                IF v_amt <> 0 THEN
                    PERFORM post_journal_entry(
                        CURRENT_DATE,
                        'Write-off ' || OLD.code,
                        'writeoff', OLD.id,
                        jsonb_build_array(
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$
;

-- advance_po_on_receipt
CREATE OR REPLACE FUNCTION public.advance_po_on_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.purchase_order_id IS NOT NULL THEN
        UPDATE purchase_orders
        SET status = 'receiving', updated_by = auth.uid()
        WHERE id = NEW.purchase_order_id AND status = 'confirmed';
    END IF;
    RETURN NULL;
END;
$function$
;

-- guard_inbound_po_line_match
CREATE OR REPLACE FUNCTION public.guard_inbound_po_line_match()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line_po uuid;
BEGIN
    IF NEW.purchase_order_line_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT purchase_order_id INTO v_line_po
    FROM purchase_order_lines WHERE id = NEW.purchase_order_line_id;
    -- 给了明细行却没给 PO,或明细行不属于所给的 PO —— 两种都是挂错单
    IF v_line_po IS NULL OR NEW.purchase_order_id IS DISTINCT FROM v_line_po THEN
        RAISE EXCEPTION 'PO_LINE_MISMATCH|%', NEW.code;
    END IF;
    RETURN NEW;
END;
$function$
;

-- guard_inbound_po_receivable
CREATE OR REPLACE FUNCTION public.guard_inbound_po_receivable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po record;
BEGIN
    IF NEW.purchase_order_id IS NULL THEN
        RETURN NEW;
    END IF;
    -- UPDATE 时只在换单时把关(同单上改行号之类不重复检查)
    IF TG_OP = 'UPDATE' AND NEW.purchase_order_id IS NOT DISTINCT FROM OLD.purchase_order_id THEN
        RETURN NEW;
    END IF;
    SELECT code, status INTO v_po FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF FOUND AND v_po.status IN ('cancelled', 'closed') THEN
        RAISE EXCEPTION 'PO_NOT_RECEIVABLE|%|%', v_po.code, v_po.status;
    END IF;
    RETURN NEW;
END;
$function$
;

-- fin_journal_cost_entry
CREATE OR REPLACE FUNCTION public.fin_journal_cost_entry()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run_code text;
    v_lines    jsonb;
BEGIN
    SELECT code INTO v_run_code FROM processing_runs WHERE id = NEW.run_id;

    IF TG_OP = 'INSERT' THEN
        IF NEW.deleted_at IS NOT NULL OR NEW.amount_usd = 0 THEN
            RETURN NULL;
        END IF;
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Cost ' || v_run_code || ' ' || NEW.cost_type,
            'processing_cost', NEW.id,
            fin_cost_lines(NEW.cost_type, NEW.amount_usd, false));
        RETURN NULL;
    END IF;

    -- UPDATE:软删 → 冲销现额(优先,忽略同笔 UPDATE 里的其它变化)
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        IF OLD.amount_usd <> 0 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost removed ' || v_run_code,
                'processing_cost', NEW.id,
                fin_cost_lines(OLD.cost_type, OLD.amount_usd, true));
        END IF;
        RETURN NULL;
    END IF;
    IF NEW.deleted_at IS NOT NULL THEN
        RETURN NULL;  -- 已软删行的其它变更不入账
    END IF;

    -- 金额/类型变化 → 一张调整分录:冲旧 + 记新(至多 4 行,自平)
    IF NEW.amount_usd IS DISTINCT FROM OLD.amount_usd
       OR NEW.cost_type IS DISTINCT FROM OLD.cost_type THEN
        v_lines := '[]'::jsonb;
        IF OLD.amount_usd <> 0 THEN
            v_lines := v_lines || fin_cost_lines(OLD.cost_type, OLD.amount_usd, true);
        END IF;
        IF NEW.amount_usd <> 0 THEN
            v_lines := v_lines || fin_cost_lines(NEW.cost_type, NEW.amount_usd, false);
        END IF;
        IF jsonb_array_length(v_lines) >= 2 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost adj ' || v_run_code,
                'processing_cost', NEW.id,
                v_lines);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$
;

-- check_ledger_invariant
CREATE OR REPLACE FUNCTION public.check_ledger_invariant()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inbound uuid;
    v_output  uuid;
    v_code    text;
    v_remaining numeric;
    v_sum     numeric;
BEGIN
    IF TG_TABLE_NAME = 'inbound_batches' THEN
        v_inbound := NEW.id;
    ELSIF TG_TABLE_NAME = 'output_batches' THEN
        v_output := NEW.id;
    ELSE  -- inventory_movements
        v_inbound := NEW.inbound_batch_id;
        v_output  := NEW.output_batch_id;
    END IF;

    IF v_inbound IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.inbound_batches WHERE id = v_inbound;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE inbound_batch_id = v_inbound;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    IF v_output IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.output_batches WHERE id = v_output;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE output_batch_id = v_output;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    RETURN NULL;
END;
$function$
;

-- check_journal_balance
CREATE OR REPLACE FUNCTION public.check_journal_balance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_count  integer;
    v_debit  numeric;
    v_credit numeric;
    v_code   text;
BEGIN
    SELECT count(*), COALESCE(sum(l.debit), 0), COALESCE(sum(l.credit), 0)
    INTO v_count, v_debit, v_credit
    FROM journal_lines l
    WHERE l.entry_id = NEW.entry_id;

    IF v_count < 2 OR v_debit <> v_credit THEN
        SELECT code INTO v_code FROM journal_entries WHERE id = NEW.entry_id;
        RAISE EXCEPTION 'JOURNAL_UNBALANCED|%|%|%', COALESCE(v_code, '?'), v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$function$
;

-- ---------------------------------------------------------------- (b) RPC 入口
-- DEFINER 让它们绕过 RLS 去做跨模块的写入,因此【必须】在顶部自己把门。
-- allocate_processing_costs → module.processing.edit
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost = Σ input legs quantity_consumed × inbound.unit_price (NULL price = 0).
    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(ib.unit_price, 0)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_usd), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_usd = f.allocated,
            unit_cost_usd = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_usd
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_usd', allocated,
                   'unit_cost_usd', unit_cost_usd)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    v_snapshot := jsonb_build_object(
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        'skipped_metals', v_skipped_metals
    );

    UPDATE processing_runs
    SET material_cost_usd   = round(v_material, 2),
        process_cost_usd    = round(v_process, 2),
        total_cost_usd      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 10a. cut 2a:资本化分录。重分摊 = 先冲销旧资本化分录再重挂(净效果即差额,
    --      且材料/费用构成变化时各科目仍精确;两张均记 CURRENT_DATE)。
    --      借方 1220 取各对方行四舍五入后的合计,保证分录自平
    --      (round(总) ≠ Σround(部分) 的边角防护;capitalized_cost_usd 存该合计)。
    IF v_run.capitalization_entry_id IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_run.capitalization_entry_id) = 'posted' THEN
        -- 已被人工冲销过的旧资本化分录不再重复冲(status <> 'posted' 直接跳过)
        PERFORM reverse_journal_entry(v_run.capitalization_entry_id, CURRENT_DATE, 'Re-allocation ' || v_run.code);
    END IF;

    v_cap_lines := '[]'::jsonb;
    v_cap_total := 0;
    IF round(v_material, 2) <> 0 THEN
        v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', 'USD', 'amount_ccy', round(v_material, 2));
        v_cap_total := v_cap_total + round(v_material, 2);
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_usd), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
        ORDER BY cost_type
    LOOP
        IF v_ct.amt > 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_ct.amt);
            v_cap_total := v_cap_total + v_ct.amt;
        ELSIF v_ct.amt < 0 THEN
            -- 负净额(冲减类成本):翻到借方,保持各行 amount_ccy > 0
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', 'USD', 'amount_ccy', -v_ct.amt);
            v_cap_total := v_cap_total + v_ct.amt;
        END IF;
    END LOOP;

    v_cap_entry_id := NULL;
    IF v_cap_total <> 0 THEN
        v_cap_lines := jsonb_build_array(
            jsonb_build_object('account_code', '1220',
                               'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                               'currency', 'USD', 'amount_ccy', abs(v_cap_total))
        ) || v_cap_lines;
        v_cap_je := post_journal_entry(
            CURRENT_DATE,
            'Capitalize ' || v_run.code,
            'allocation', p_run_id,
            v_cap_lines);
        v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
    END IF;

    UPDATE processing_runs
    SET capitalized_cost_usd = v_cap_total,
        capitalization_entry_id = v_cap_entry_id
    WHERE id = p_run_id;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_usd,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_usd
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_usd, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_usd', round(v_material, 2),
        'process_cost_usd', round(v_process, 2),
        'total_cost_usd', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$
;

-- apply_assay_result → module.inbound.edit
CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 公式解析:入参 → 批次 → 采购单明细行 → 无
    v_formula := COALESCE(
        p_pricing_formula_id,
        v_batch.pricing_formula_id,
        (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
          WHERE pol.id = v_batch.purchase_order_line_id)
    );

    IF v_formula IS NOT NULL THEN
        -- 3. 与计价器同一 DB 函数算价,再走与手工计价【同一条】重计价路径
        --    (reprice_inbound_batch)—— 价差分录、price_history、1200/5000 拆账
        --    三件事只存在一份实现。参考日默认化验日:结算价随行情,行情看化验那天。
        v_calc := calculate_metal_price(v_formula, v_metals, v_batch.quantity,
                                        COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
        SELECT code INTO v_fcode FROM pricing_formulas WHERE id = v_formula;

        IF v_unit > 0 THEN
            v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                           'Assay ' || v_assay.code || ' applied');
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 无公式可解:含量照常落地、化验照常标记已执行,价格不动 ——
        --    手工计价的采购本来就由人定价,这不是错误。
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次的定价状态:只有真的重了价才谈得上 final
    v_status := CASE WHEN v_priced AND v_assay.is_final THEN 'final'
                     ELSE v_batch.pricing_status END;
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        pricing_status = v_status,
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'priced', v_priced,
        'formula_code', v_fcode,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'note', v_note
    );
END;
$function$
;

-- apply_payment_term_template → module.purchasing.edit
CREATE OR REPLACE FUNCTION public.apply_payment_term_template(p_purchase_order_id uuid, p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_tpl   record;
    v_count integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, order_date, status INTO v_po
    FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT id, name INTO v_tpl
    FROM payment_term_templates
    WHERE id = p_template_id AND deleted_at IS NULL AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEMPLATE_NOT_FOUND|%', COALESCE(p_template_id::text, '?');
    END IF;

    -- 【替换】而不是追加:套模板的语义是"这张 PO 的计划就是模板说的那样"
    DELETE FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              fixed_amount_usd, trigger_event, due_date, notes)
    SELECT p_purchase_order_id, l.seq, l.label, l.percentage, l.fixed_amount_usd, l.trigger_event,
           -- 模板存的是相对下单日的天数偏移(模板不可能知道具体日期)
           CASE WHEN l.trigger_event = 'fixed_date'
                THEN v_po.order_date + COALESCE(l.days_offset, 0)
                ELSE NULL END,
           l.notes
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id
    ORDER BY l.seq;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object('purchase_order_id', p_purchase_order_id, 'term_count', v_count);
END;
$function$
;

-- apply_prepayment → module.finance.edit
CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_batch     record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_available numeric;
    v_value     numeric;
    v_settled   numeric;
    v_open      numeric;
    v_app_id    uuid := gen_random_uuid();
    v_je        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT po.id, po.code, po.supplier_id, po.status
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT ib.id, ib.code, ib.supplier_id, ib.quantity, ib.unit_price
    INTO v_batch
    FROM inbound_batches ib
    WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF v_batch.unit_price IS NULL THEN
        RAISE EXCEPTION 'INBOUND_UNPRICED|%', v_batch.code;
    END IF;
    IF v_batch.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
        RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_batch.code;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- 可用预付 = 已付到该 PO 的预付(仅 posted 收付款) − 已冲抵的部分
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    SELECT COALESCE(SUM(ppa.amount_usd), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF p_amount > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, p_amount;
    END IF;

    -- 批次敞口 = 当前批次价值 − 收付款核销 − 已冲抵的预付
    v_value := round(v_batch.quantity * v_batch.unit_price, 2);
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.inbound_batch_id = p_inbound_batch_id;
    v_settled := v_settled + COALESCE(
        (SELECT SUM(ppa.amount_usd) FROM prepayment_applications ppa
          WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
    v_open := round(v_value - v_settled, 2);
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- 分录:预付转为对该批次应付的清偿(钱早就出去了,这里只是科目之间的搬运)
    v_je := post_journal_entry(
        CURRENT_DATE,
        'Prepayment applied ' || v_po.code || ' → ' || v_batch.code,
        'prepayment', v_app_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', p_amount, 'fx_rate', 1),
            jsonb_build_object('account_code', '1300', 'side', 'credit', 'currency', 'USD', 'amount_ccy', p_amount, 'fx_rate', 1)));

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, amount_usd,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'amount_usd', p_amount,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - p_amount, 2)
    );
END;
$function$
;

-- cancel_purchase_order → module.purchasing.edit
CREATE OR REPLACE FUNCTION public.cancel_purchase_order(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_po      record;
    v_batches integer;
    v_applied numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, status INTO v_po
    FROM purchase_orders WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT count(*) INTO v_batches
    FROM inbound_batches WHERE purchase_order_id = p_id AND deleted_at IS NULL;
    IF v_batches > 0 THEN
        RAISE EXCEPTION 'PO_HAS_RECEIPTS|%', v_batches;
    END IF;

    SELECT COALESCE(SUM(amount_usd), 0) INTO v_applied
    FROM prepayment_applications WHERE purchase_order_id = p_id;
    IF v_applied > 0 THEN
        RAISE EXCEPTION 'PO_HAS_APPLIED_PREPAYMENTS|%', v_applied;
    END IF;

    UPDATE purchase_orders
    SET status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason, updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object('purchase_order_id', p_id, 'code', v_po.code, 'status', 'cancelled');
END;
$function$
;

-- cancel_stocktake → module.stocktakes.edit
CREATE OR REPLACE FUNCTION public.cancel_stocktake(p_stocktake_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_status  text;
    v_deleted timestamptz;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT status, deleted_at INTO v_status, v_deleted
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_status;
    END IF;

    UPDATE stocktakes
    SET status = 'cancelled', updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;
END;
$function$
;

-- close_period → module.finance.edit
CREATE OR REPLACE FUNCTION public.close_period(p_period_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked   date;
    v_count    integer;
    v_debits   numeric;
    v_credits  numeric;
    v_new_lock date;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 必须是月末日
    IF p_period_end IS NULL
       OR p_period_end <> (date_trunc('month', p_period_end) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'NOT_MONTH_END|%', COALESCE(p_period_end::text, '?');
    END IF;

    -- 串行化 + 不可重关已锁期间
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id FOR UPDATE;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'ALREADY_CLOSED|%', v_locked;
    END IF;

    -- 截至 period_end 的全部分录:张数 + Σ借/Σ贷(关账即校验点)
    SELECT COUNT(DISTINCT jl.entry_id),
           round(COALESCE(SUM(jl.debit), 0), 2),
           round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_count, v_debits, v_credits
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= p_period_end;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%|%', v_debits, v_credits;
    END IF;

    v_new_lock := p_period_end + 1;

    INSERT INTO period_closes (period_end, notes, entries_count, total_debits, total_credits)
    VALUES (p_period_end, p_notes, v_count, v_debits, v_credits);

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock,
        'entries_count', v_count,
        'total_debits', v_debits,
        'total_credits', v_credits
    );
END;
$function$
;

-- close_purchase_order → module.purchasing.edit
CREATE OR REPLACE FUNCTION public.close_purchase_order(p_purchase_order_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_unapplied numeric;
    v_received  numeric;
    v_ordered   numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, status, notes INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    IF v_po.status = 'closed' THEN
        RAISE EXCEPTION 'PO_ALREADY_CLOSED|%', v_po.code;
    END IF;

    -- 未抵扣预付 = 已付到该单的预付(posted 收付款)− 已抵扣到批次的部分。
    -- 大于 0 时必须写说明:这是【真金白银】躺在 1300 预付款项里,而这张单永远不会
    -- 再吸收它了 —— 退款、转到别的单、核销,系统今天都还没建模,所以允许关单,
    -- 但必须留下一句写下来的解释,不许无声搁浅。
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;
    SELECT COALESCE(SUM(ppa.amount_usd), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;
    v_unapplied := round(v_prepaid - v_applied, 2);

    IF v_unapplied > 0 AND (p_notes IS NULL OR btrim(p_notes) = '') THEN
        RAISE EXCEPTION 'CLOSE_NOTES_REQUIRED|%', v_unapplied;
    END IF;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL;
    SELECT COALESCE(SUM(pol.quantity), 0) INTO v_ordered
    FROM purchase_order_lines pol
    WHERE pol.purchase_order_id = p_purchase_order_id;

    UPDATE purchase_orders
    SET status = 'closed',
        closed_at = now(),
        -- 追加而不覆盖:关单说明带时间戳进 notes,原有内容原样保留
        notes = CASE
            WHEN p_notes IS NULL OR btrim(p_notes) = '' THEN notes
            ELSE COALESCE(notes || E'\n', '')
                 || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' closed] ' || btrim(p_notes)
        END,
        updated_by = v_user
    WHERE id = p_purchase_order_id;

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', 'closed',
        'unapplied_prepayment_usd', v_unapplied,
        'received_qty', v_received,
        'ordered_qty', v_ordered,
        'receipt_pct', CASE WHEN v_ordered = 0 THEN NULL
                            ELSE round(v_received / v_ordered * 100, 2) END
    );
END;
$function$
;

-- commit_processing_run → module.processing.edit
CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date := COALESCE(p_process_date, CURRENT_DATE);
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_consumed     numeric;
    v_remaining    numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
        RAISE EXCEPTION 'NO_OUTPUTS';
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一进料批次不能重复添加
    IF (SELECT count(DISTINCT elem->>'inbound_batch_id')
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        SELECT remaining_qty INTO v_remaining
        FROM inbound_batches
        WHERE id = v_inbound_id AND deleted_at IS NULL
        FOR UPDATE;

        IF v_remaining IS NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
        END IF;
        IF v_consumed > v_remaining THEN
            RAISE EXCEPTION 'CONSUMED_EXCEEDS_REMAINING|%|%', v_consumed, v_remaining;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status, created_by, updated_by
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        COALESCE(p_loss_qty, v_total_input - v_total_output),
        p_notes, 'committed', v_user_id, v_user_id
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        SELECT remaining_qty INTO v_remaining
        FROM inbound_batches WHERE id = v_inbound_id;
        v_new_remaining := v_remaining - v_consumed;

        UPDATE inbound_batches
        SET remaining_qty = v_new_remaining,
            stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
            updated_by = v_user_id,
            updated_at = now()
        WHERE id = v_inbound_id;

        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
        VALUES (v_inbound_id, 'processing_consume', -v_consumed, v_run_id, v_process_date, v_user_id);

        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
        VALUES (v_run_id, v_inbound_id, v_consumed);
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    RETURN v_run_id;
END;
$function$
;

-- create_invoice → module.finance.edit
CREATE OR REPLACE FUNCTION public.create_invoice(p_customer_id uuid, p_sales_record_ids uuid[], p_issue_date date DEFAULT NULL::date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cust        customers%ROWTYPE;
    v_issue       date := COALESCE(p_issue_date, CURRENT_DATE);
    v_terms       integer;
    v_due         date;
    v_invoice_id  uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_code        text;
    v_sale_id     uuid;
    v_seen        uuid[] := ARRAY[]::uuid[];
    v_sale        record;
    v_currency    text;
    v_no          integer := 0;
    v_subtotal    numeric := 0;
    v_gst_on      boolean;
    v_gst_rate    numeric;
    v_tax_rate    numeric := 0;
    v_tax         numeric := 0;
    v_existing    text;
    v_lines       jsonb := '[]'::jsonb;  -- 第一趟收集,第二趟落库
    v_line        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 客户
    SELECT * INTO v_cust FROM customers
    WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    IF p_sales_record_ids IS NULL OR array_length(p_sales_record_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 2. 账期:显式 > 客户设定 > 30 天
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days, 30);
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := v_issue + v_terms;

    -- 3. 无缝编号(按 issue_date 的年份),咨询锁串行化;回滚即释放号码
    v_year := EXTRACT(YEAR FROM v_issue)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM invoices
    WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 4. 第一趟:逐张销售校验(存在 → 归属 → 未被占用 → 币种一致)并累计金额。
    FOREACH v_sale_id IN ARRAY p_sales_record_ids
    LOOP
        IF v_sale_id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_SALE|%',
                COALESCE((SELECT ob.code FROM sales_records sr
                          JOIN output_batches ob ON ob.id = sr.output_batch_id
                          WHERE sr.id = v_sale_id), v_sale_id::text);
        END IF;
        v_seen := v_seen || v_sale_id;

        SELECT sr.id, sr.customer_id, sr.quantity, sr.unit_price, sr.currency,
               sr.amount_usd, ob.code AS batch_code, ob.unit, m.name AS material_name
        INTO v_sale
        FROM sales_records sr
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        LEFT JOIN materials m ON m.id = ob.material_id
        WHERE sr.id = v_sale_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SALE_NOT_FOUND|%', v_sale_id;
        END IF;

        -- sales_records.customer_id 可空 —— 批次可能在客户还没登记时就卖了。
        IF v_sale.customer_id IS NOT NULL AND v_sale.customer_id <> p_customer_id THEN
            RAISE EXCEPTION 'SALE_WRONG_CUSTOMER|%', v_sale.batch_code;
        END IF;

        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_record_id = v_sale_id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'ALREADY_INVOICED|%|%', v_sale.batch_code, v_existing;
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_sale.currency;
        ELSIF v_currency <> v_sale.currency THEN
            RAISE EXCEPTION 'MIXED_CURRENCY|%|%', v_currency, v_sale.currency;
        END IF;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_record_id', v_sale_id,
            'line_no', v_no,
            'description', v_sale.batch_code || COALESCE(' — ' || v_sale.material_name, ''),
            'quantity', v_sale.quantity,
            'unit', v_sale.unit,
            'unit_price', v_sale.unit_price,
            'amount_usd', v_sale.amount_usd);

        v_subtotal := v_subtotal + v_sale.amount_usd;
    END LOOP;

    -- 5. 税:未做 GST 登记时一律 0。【不过任何税金分录】—— 正确确认时点是销售,不是开票。
    SELECT gst_registered, gst_rate_pct INTO v_gst_on, v_gst_rate
    FROM finance_settings LIMIT 1;
    IF COALESCE(v_gst_on, false) THEN
        v_tax_rate := COALESCE(v_gst_rate, 0);
        v_tax := round(v_subtotal * v_tax_rate / 100.0, 2);
    END IF;

    v_subtotal := round(v_subtotal, 2);

    -- 6. 第二趟:金额已定,一次写对发票头,再落明细行。
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_usd, tax_rate_pct, tax_usd, total_usd,
                          notes, terms_text, bill_to_snapshot)
    VALUES (v_invoice_id, v_code, p_customer_id, v_issue, v_due, v_terms,
            v_currency, v_subtotal, v_tax_rate, v_tax, round(v_subtotal + v_tax, 2),
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                -- cut 2b 新增
                'contact_person', v_cust.contact_person,
                'email', v_cust.email,
                'phone', v_cust.phone));

    FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
                                   quantity, unit, unit_price, amount_usd)
        VALUES (v_invoice_id,
                (v_line->>'sales_record_id')::uuid,
                (v_line->>'line_no')::integer,
                v_line->>'description',
                (v_line->>'quantity')::numeric,
                v_line->>'unit',
                (v_line->>'unit_price')::numeric,
                (v_line->>'amount_usd')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', v_issue,
        'due_date', v_due,
        'subtotal_usd', v_subtotal,
        'tax_usd', v_tax,
        'total_usd', round(v_subtotal + v_tax, 2),
        'line_count', v_no,
        'currency', v_currency
    );
END;
$function$
;

-- create_purchase_order → module.purchasing.edit
CREATE OR REPLACE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_order_date date, p_expected_delivery date, p_currency text, p_fx_rate numeric, p_incoterm text, p_terms_text text, p_notes text, p_lines jsonb, p_payment_terms jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_date       date := COALESCE(p_order_date, CURRENT_DATE);
    v_fx         numeric;
    v_po_id      uuid := gen_random_uuid();
    v_code       text;
    v_line       jsonb;
    v_line_no    integer;
    v_qty        numeric;
    v_price      numeric;
    v_amount     numeric;
    v_material   uuid;
    v_formula    uuid;
    v_f          record;
    v_total      numeric := 0;
    v_count      integer := 0;
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer := 0;
    v_pct_total  numeric := 0;
    v_term_count integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_code := next_purchase_order_code(v_date);

    INSERT INTO purchase_orders (id, code, supplier_id, order_date, expected_delivery_date,
                                 currency, fx_rate, estimated_total_usd, status,
                                 approval_status, approved_at, approved_by,
                                 incoterm, terms_text, notes, created_by, updated_by)
    VALUES (v_po_id, v_code, p_supplier_id, v_date, p_expected_delivery,
            p_currency, v_fx, 0, 'confirmed',
            -- 两级审批留到权限切次:这里直接盖章,结构在、流程不在(见 B1 注释)
            'approved', now(), v_user,
            p_incoterm, p_terms_text, p_notes, v_user, v_user);

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;
        v_line_no := COALESCE((v_line->>'line_no')::integer, v_count);
        v_material := (v_line->>'material_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_price := (v_line->>'estimated_unit_price')::numeric;
        v_formula := (v_line->>'pricing_formula_id')::uuid;

        IF v_material IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_material AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(v_material::text, '?');
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_INVALID|%', v_line_no;
        END IF;
        IF v_formula IS NOT NULL THEN
            SELECT id, code, is_active, deleted_at INTO v_f
            FROM pricing_formulas WHERE id = v_formula;
            IF NOT FOUND OR v_f.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_formula;
            END IF;
            IF NOT v_f.is_active THEN
                RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
            END IF;
        END IF;

        -- 没给估价就是 0:PO 是承诺,估算金额可以留白(公式定价的料常常如此)
        v_amount := CASE WHEN v_price IS NULL THEN 0 ELSE round(v_qty * v_price, 2) END;
        v_total := v_total + v_amount;

        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity,
                                          unit, pricing_formula_id, estimated_unit_price,
                                          estimated_amount_usd, expected_assay, notes, created_by)
        VALUES (v_po_id, v_line_no, v_material, v_qty,
                COALESCE(v_line->>'unit', 'kg'), v_formula, v_price,
                v_amount, v_line->'expected_assay', v_line->>'notes', v_user);
    END LOOP;

    UPDATE purchase_orders SET estimated_total_usd = v_total, updated_by = v_user
    WHERE id = v_po_id;

    -- 付款计划是【可选的】:有些采购就是到货即付,没有分期可言。
    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array'
       AND jsonb_array_length(p_payment_terms) > 0 THEN
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);

            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                                      fixed_amount_usd, trigger_event, due_date, notes)
            VALUES (v_po_id, v_seq, v_term->>'label',
                    (v_term->>'percentage')::numeric,
                    (v_term->>'fixed_amount_usd')::numeric,
                    v_term->>'trigger_event',
                    (v_term->>'due_date')::date,
                    v_term->>'notes');
            v_term_count := v_term_count + 1;
        END LOOP;

        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'purchase_order_id', v_po_id,
        'code', v_code,
        'estimated_total_usd', v_total,
        'line_count', v_count,
        'term_count', v_term_count
    );
END;
$function$
;

-- ignore_bank_line → module.finance.edit
CREATE OR REPLACE FUNCTION public.ignore_bank_line(p_statement_line_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT l.id, l.match_status, s.status AS stmt_status
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'unmatched' THEN
        RAISE EXCEPTION 'LINE_NOT_UNMATCHED|%', v_line.match_status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE bank_statement_lines
    SET match_status = 'ignored', ignore_reason = btrim(p_reason)
    WHERE id = p_statement_line_id;
END;
$function$
;

-- import_bank_statement → module.finance.edit
CREATE OR REPLACE FUNCTION public.import_bank_statement(p_bank_account text, p_period_start date, p_period_end date, p_opening numeric, p_closing numeric, p_file_name text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ccy          text;
    v_statement_id uuid := gen_random_uuid();
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_line         jsonb;
    v_no           integer := 0;
    v_amount       numeric;
    v_date         date;
    v_sum          numeric := 0;
    v_overlaps     integer;
    v_dups         integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    v_ccy := bank_native_currency(p_bank_account);
    IF v_ccy IS NULL THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end < p_period_start THEN
        RAISE EXCEPTION 'PERIOD_INVALID|%|%', COALESCE(p_period_start::text,'?'), COALESCE(p_period_end::text,'?');
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 先整体校验(金额为非零数字、日期在期间内)并求 Σ
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        IF jsonb_typeof(v_line->'amount') <> 'number' OR (v_line->>'amount')::numeric = 0 THEN
            RAISE EXCEPTION 'LINE_AMOUNT_INVALID|%', v_no;
        END IF;
        v_amount := (v_line->>'amount')::numeric;
        v_date := (v_line->>'line_date')::date;
        IF v_date IS NULL OR v_date < p_period_start OR v_date > p_period_end THEN
            RAISE EXCEPTION 'LINE_DATE_OUT_OF_RANGE|%|%', v_no, COALESCE(v_date::text, '?');
        END IF;
        v_sum := v_sum + v_amount;

        -- 疑似重复(同账户其他在册报表上已有同日期+同金额+同摘要的行)—— 只计数
        SELECT v_dups + count(*) INTO v_dups
        FROM bank_statement_lines l
        JOIN bank_statements s ON s.id = l.statement_id
        WHERE s.bank_account_code = p_bank_account
          AND s.deleted_at IS NULL
          AND l.line_date = v_date
          AND l.amount = v_amount
          AND l.description IS NOT DISTINCT FROM (v_line->>'description');
    END LOOP;

    -- 余额恒等式:opening + Σ = closing
    IF round(p_opening + v_sum, 2) IS DISTINCT FROM round(p_closing, 2) THEN
        RAISE EXCEPTION 'STATEMENT_NOT_BALANCED|%|%', round(p_opening + v_sum, 2), round(p_closing, 2);
    END IF;

    -- 期间重叠警告(不拦)
    SELECT count(*) INTO v_overlaps
    FROM bank_statements s
    WHERE s.bank_account_code = p_bank_account
      AND s.deleted_at IS NULL
      AND s.period_start <= p_period_end
      AND s.period_end >= p_period_start;

    -- 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款/开支手法)
    v_year := EXTRACT(YEAR FROM p_period_end)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('bank_stmt_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM bank_statements
    WHERE code LIKE 'BS-' || v_year::text || '-%';
    v_code := 'BS-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO bank_statements (id, code, bank_account_code, currency, period_start, period_end,
                                 opening_balance, closing_balance, file_name)
    VALUES (v_statement_id, v_code, p_bank_account, v_ccy, p_period_start, p_period_end,
            p_opening, p_closing, p_file_name);

    -- 行按数组顺序编号
    v_no := 0;
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        INSERT INTO bank_statement_lines (statement_id, line_no, line_date, description, reference, amount)
        VALUES (v_statement_id, v_no, (v_line->>'line_date')::date,
                v_line->>'description', v_line->>'reference', (v_line->>'amount')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'statement_id', v_statement_id,
        'code', v_code,
        'line_count', v_no,
        'overlapping_statements', v_overlaps,
        'possible_duplicates', v_dups
    );
END;
$function$
;

-- match_bank_line → module.finance.edit
CREATE OR REPLACE FUNCTION public.match_bank_line(p_statement_line_id uuid, p_journal_line_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line   record;
    v_jl_id  uuid;
    v_jl     record;
    v_sum    numeric := 0;
    v_count  integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT l.id, l.amount, l.match_status,
           s.status AS stmt_status, s.bank_account_code, s.currency
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'unmatched' THEN
        RAISE EXCEPTION 'LINE_NOT_UNMATCHED|%', v_line.match_status;
    END IF;

    IF p_journal_line_ids IS NULL OR array_length(p_journal_line_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_JOURNAL_LINES';
    END IF;

    FOREACH v_jl_id IN ARRAY p_journal_line_ids
    LOOP
        SELECT l.id, l.debit, l.credit, l.currency, l.amount_ccy,
               a.code AS account_code, e.status AS entry_status
        INTO v_jl
        FROM journal_lines l
        JOIN accounts a ON a.id = l.account_id
        JOIN journal_entries e ON e.id = l.entry_id
        WHERE l.id = v_jl_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'JL_NOT_FOUND|%', v_jl_id;
        END IF;
        IF v_jl.account_code <> v_line.bank_account_code THEN
            RAISE EXCEPTION 'JL_WRONG_ACCOUNT|%', v_jl_id;
        END IF;
        IF v_jl.currency <> v_line.currency THEN
            RAISE EXCEPTION 'JL_WRONG_CURRENCY|%|%', v_jl_id, v_jl.currency;
        END IF;
        IF EXISTS (SELECT 1 FROM bank_line_matches m WHERE m.journal_line_id = v_jl_id) THEN
            RAISE EXCEPTION 'JL_ALREADY_MATCHED|%', v_jl_id;
        END IF;
        IF v_jl.entry_status <> 'posted' THEN
            RAISE EXCEPTION 'JL_ENTRY_REVERSED|%', v_jl_id;
        END IF;
        -- 方向:入账(+)= 银行借方,出账(−)= 银行贷方
        IF (v_line.amount > 0 AND v_jl.debit <= 0) OR (v_line.amount < 0 AND v_jl.credit <= 0) THEN
            RAISE EXCEPTION 'JL_WRONG_DIRECTION|%', v_jl_id;
        END IF;

        -- 立即插入:同一数组里的重复 id 会被上面的 already-matched 检查看见
        INSERT INTO bank_line_matches (statement_line_id, journal_line_id, matched_amount)
        VALUES (p_statement_line_id, v_jl_id, v_jl.amount_ccy);

        v_sum := v_sum + v_jl.amount_ccy;
        v_count := v_count + 1;
    END LOOP;

    IF round(v_sum, 2) IS DISTINCT FROM round(abs(v_line.amount), 2) THEN
        RAISE EXCEPTION 'MATCH_AMOUNT_MISMATCH|%|%', round(abs(v_line.amount), 2), round(v_sum, 2);
    END IF;

    UPDATE bank_statement_lines SET match_status = 'matched' WHERE id = p_statement_line_id;

    RETURN jsonb_build_object(
        'statement_line_id', p_statement_line_id,
        'matched_count', v_count,
        'matched_total', round(v_sum, 2)
    );
END;
$function$
;

-- post_payroll_period → module.hr.edit
CREATE OR REPLACE FUNCTION public.post_payroll_period(p_payroll_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_p     record;
    v_bank  text;
    v_lines jsonb := '[]'::jsonb;
    v_je    jsonb;
    v_cpf   numeric;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_payroll_period_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 发薪走哪个银行账户由周期币种定;别的币种目前没有对应的银行科目
    v_bank := CASE v_p.currency WHEN 'SGD' THEN '1000' WHEN 'USD' THEN '1010' END;
    IF v_bank IS NULL THEN
        RAISE EXCEPTION 'PAYROLL_CURRENCY_UNSUPPORTED|%', v_p.currency;
    END IF;

    -- 借 6100 工资薪金(服务商口径的 gross)
    IF v_p.gross_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6100', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.gross_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 借 6110 公积金-雇主部分(公司成本,不从员工工资里出)
    IF v_p.employer_cpf_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6110', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.employer_cpf_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2400 公积金应付:雇主 + 员工两侧合计,汇给公积金局之前都欠着
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2400', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_cpf, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2200 应计费用:服务商【代公司扣下】的其它款项,在汇出去之前挂在这里。
    -- 【注意区分】如果某项扣款本质上是"公司成本变少"(而不是替员工代扣代缴),
    -- 那它就不该出现在这里 —— 应该让服务商把它并进 gross 里去。
    IF v_p.other_deductions_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2200', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.other_deductions_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 银行:实发净额
    IF v_p.net_pay_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_bank, 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.net_pay_total, 'fx_rate', v_p.fx_rate);
    END IF;

    -- 期间锁在 post_journal_entry 内生效(PERIOD_LOCKED 原样上抛)
    v_je := post_journal_entry(
        v_p.payment_date,
        'Payroll ' || v_p.code,
        'payroll',
        v_p.id,
        v_lines
    );

    UPDATE payroll_periods
    SET status = 'posted', journal_entry_id = (v_je->>'entry_id')::uuid, updated_by = v_user
    WHERE id = p_payroll_period_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_payroll_period_id,
        'code', v_p.code,
        'journal_code', v_je->>'code',
        'gross_total', v_p.gross_total,
        'employer_cpf_total', v_p.employer_cpf_total,
        'employee_cpf_total', v_p.employee_cpf_total,
        'net_pay_total', v_p.net_pay_total
    );
END;
$function$
;

-- post_stocktake → module.stocktakes.edit
CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT id, code, status, deleted_at INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at, unit_price INTO v_code, v_current, v_deleted, v_value
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_usd
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', 'USD', 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', 'USD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$
;

-- reconcile_statement → module.finance.edit
CREATE OR REPLACE FUNCTION public.reconcile_statement(p_statement_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt        record;
    v_outstanding integer;
    v_matched     integer;
    v_ignored     integer;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_ALREADY_RECONCILED|%', v_stmt.code;
    END IF;

    SELECT count(*) FILTER (WHERE match_status = 'unmatched'),
           count(*) FILTER (WHERE match_status = 'matched'),
           count(*) FILTER (WHERE match_status = 'ignored')
    INTO v_outstanding, v_matched, v_ignored
    FROM bank_statement_lines
    WHERE statement_id = p_statement_id;

    IF v_outstanding > 0 THEN
        RAISE EXCEPTION 'LINES_OUTSTANDING|%', v_outstanding;
    END IF;

    UPDATE bank_statements
    SET status = 'reconciled', reconciled_at = now(), reconciled_by = auth.uid()
    WHERE id = p_statement_id;

    RETURN jsonb_build_object(
        'statement_id', p_statement_id,
        'code', v_stmt.code,
        'matched_lines', v_matched,
        'ignored_lines', v_ignored,
        'closing_balance', v_stmt.closing_balance
    );
END;
$function$
;

-- record_assay_result → module.inbound.edit
CREATE OR REPLACE FUNCTION public.record_assay_result(p_inbound_batch_id uuid, p_assay_date date, p_metals jsonb, p_lab_name text DEFAULT NULL::text, p_certificate_ref text DEFAULT NULL::text, p_sample_ref text DEFAULT NULL::text, p_is_final boolean DEFAULT true, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF NOT EXISTS (
        SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes, created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes, v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count
    );
END;
$function$
;

-- record_expense → module.finance.edit
CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_amount_usd numeric;
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;
    SELECT code, is_active, account_type INTO v_account
    FROM accounts WHERE code = p_account_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(p_account_code, '?');
    END IF;
    IF NOT v_account.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
    END IF;
    IF v_account.account_type <> 'expense' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code;
    END IF;

    -- 2. 金额/币种/汇率(同 record_payment 约定:USD 强制 1,非 USD 必须给汇率)
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;  -- 本位币强制 1,忽略传入值
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;

    IF p_payment_status = 'paid' THEN
        -- paid:银行科目显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
        END IF;
    ELSE
        -- unpaid:必须有在册供应商(它要成为 AP 单据);银行科目必须为空 ——
        -- 传了也直接忽略(挂账时根本没动银行,存下来只会误导)
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        v_bank := NULL;
    END IF;

    -- 4. USD 金额
    v_amount_usd := round(p_amount * v_fx, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。
    --    paid → 贷银行;unpaid → 贷 2000 应付。行走原币。
    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        jsonb_build_array(
            jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
                               'side', 'credit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx))
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_usd, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_usd, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'code', v_code,
        'amount_usd', v_amount_usd,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status
    );
END;
$function$
;

-- record_output_sale → module.output.edit
CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_usd    numeric;
    v_movement_id   uuid;
    v_sale_id       uuid;
    v_sale_date     date := COALESCE(p_sale_date, CURRENT_DATE);
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;  -- 本位币强制 1,忽略传入值
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;
    v_amount_usd := round(p_quantity * p_unit_price * v_fx, 2);

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, v_sale_date, p_notes, v_user)
    RETURNING id INTO v_movement_id;

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_usd, sale_date, notes, movement_id, created_by)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_usd, v_sale_date, p_notes, v_movement_id, v_user)
    RETURNING id INTO v_sale_id;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_usd 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_usd INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_usd', v_amount_usd,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$
;

-- record_payment → module.finance.edit
CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user         uuid := auth.uid();
    v_date         date := COALESCE(p_payment_date, CURRENT_DATE);
    v_fx           numeric;
    v_amount_usd   numeric;
    v_bank         text;
    v_payment_id   uuid := gen_random_uuid();
    v_code         text;
    v_alloc        jsonb;
    v_sale_id      uuid;
    v_batch_id     uuid;
    v_expense_id   uuid;
    v_po_id        uuid;
    v_alloc_usd    numeric;
    v_doc          record;
    v_doc_value    numeric;
    v_settled      numeric;
    v_open         numeric;
    v_alloc_total  numeric := 0;
    v_je           jsonb;
    -- 拆账与两遍处理用
    v_key          text;
    v_running      jsonb := '{}'::jsonb;   -- 目标 id → 本笔内已累计核销额
    v_prior        numeric;
    v_valid        jsonb := '[]'::jsonb;   -- ①校验通过的核销行,②之后据此落库
    v_po_usd       numeric := 0;           -- 本笔中指向 PO 的预付合计(USD)
    v_ap_usd       numeric;
    v_po_ccy       numeric;
    v_ap_ccy       numeric;
    v_cap          numeric;
    v_delta        numeric;
    v_found        boolean;
    v_lines        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 基础校验
    IF p_direction IS NULL OR p_direction NOT IN ('in','out') THEN
        RAISE EXCEPTION 'DIRECTION_INVALID|%', COALESCE(p_direction, '?');
    END IF;

    IF p_direction = 'in' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM customers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    ELSE
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM suppliers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;  -- 本位币强制 1,忽略传入值
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 银行科目:显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
    IF p_bank_account IS NOT NULL THEN
        IF p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
        END IF;
        v_bank := p_bank_account;
    ELSE
        v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
    END IF;

    -- 2. USD 金额
    v_amount_usd := round(p_amount * v_fx, 2);

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    -- ========================================================================
    -- ① 核销行:逐条校验,不落库。顺序:存在 → 归属 → 计价 → 敞口。
    --    'in' 只认 sales_record_id;'out' 认 inbound_batch_id / expense_id /
    --    purchase_order_id(预付)。
    -- ========================================================================
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id    := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id   := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_po_id      := (v_alloc->>'purchase_order_id')::uuid;
        v_alloc_usd  := (v_alloc->>'amount_usd')::numeric;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL OR v_po_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id, sr.amount_usd AS doc_value
            INTO v_doc
            FROM sales_records sr
            JOIN output_batches ob ON ob.id = sr.output_batch_id
            WHERE sr.id = v_sale_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_sale_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_key := v_sale_id::text;

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.sales_record_id = v_sale_id;

        ELSIF v_po_id IS NOT NULL THEN
            -- 预付款:PO 上【没有敞口上限】—— 定金不是在还债,那一刻还没有债。
            -- 唯一的栏杆是"累计预付不得超过估算总额 × 1.5",防手滑多打一个零。
            SELECT po.id, po.code AS doc_code, po.supplier_id AS party_id,
                   po.estimated_total_usd, po.status AS po_status
            INTO v_doc
            FROM purchase_orders po
            WHERE po.id = v_po_id AND po.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_po_id;
            END IF;
            IF v_doc.po_status = 'cancelled' THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_doc.doc_code;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_key := v_po_id::text;

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.purchase_order_id = v_po_id;

            -- 1.5 倍是【刻意留出的余量】:估算按谈价时的行情算,实际化验和金属价格
            -- 波动都会把真实金额顶高,预付超过估算是正常的;超过一半就不正常了。
            v_cap := round(v_doc.estimated_total_usd * 1.5, 2);
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            IF round(v_settled + v_prior + v_alloc_usd, 2) > v_cap THEN
                RAISE EXCEPTION 'PREPAY_EXCEEDS_ESTIMATE|%|%|%',
                    v_doc.doc_code, round(v_settled + v_prior + v_alloc_usd, 2), v_cap;
            END IF;

            v_po_usd := round(v_po_usd + v_alloc_usd, 2);
            v_doc_value := NULL;  -- 无敞口上限,跳过下面的 ALLOC_EXCEEDS

        ELSIF v_batch_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT ib.id, ib.code AS doc_code, ib.supplier_id AS party_id,
                   ib.unit_price, ib.quantity
            INTO v_doc
            FROM inbound_batches ib
            WHERE ib.id = v_batch_id AND ib.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_batch_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            IF v_doc.unit_price IS NULL THEN
                RAISE EXCEPTION 'ALLOC_UNPRICED|%', v_doc.doc_code;
            END IF;
            -- 应付额永远对着"当前"批次价值(改价即改欠款)
            v_doc_value := round(v_doc.quantity * v_doc.unit_price, 2);
            v_key := v_batch_id::text;

            -- 已结 = 收付款核销 + 预付冲抵(B6 起,预付冲抵也在还这张单的应付)
            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_usd) FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = v_batch_id), 0);

        ELSE
            IF v_sale_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- 挂账开支:必须是 unpaid + posted(不存在/已付/已冲销 → ALLOC_INVALID)
            SELECT e.id, e.code AS doc_code, e.supplier_id AS party_id, e.amount_usd AS doc_value
            INTO v_doc
            FROM expenses e
            WHERE e.id = v_expense_id AND e.payment_status = 'unpaid' AND e.status = 'posted';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_expense_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
        END IF;

        -- 敞口校验(预付除外:v_doc_value 为 NULL)。v_running 让同一目标在同一笔里
        -- 出现两次时,后一条能看见前一条 —— 原实现靠"边插边查"拿到的就是这个语义。
        IF v_doc_value IS NOT NULL THEN
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            v_open := round(v_doc_value - v_settled - v_prior, 2);
            IF v_alloc_usd > v_open THEN
                RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
            END IF;
        END IF;

        v_running := v_running || jsonb_build_object(
            v_key, COALESCE((v_running->>v_key)::numeric, 0) + v_alloc_usd);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object(
            'sales_record_id', v_sale_id, 'inbound_batch_id', v_batch_id,
            'expense_id', v_expense_id, 'purchase_order_id', v_po_id,
            'amount_usd', v_alloc_usd));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    IF v_alloc_total > v_amount_usd THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%', v_alloc_total, v_amount_usd;
    END IF;

    -- ========================================================================
    -- ② 分录。'out' 且本笔含 PO 预付时【拆两条借方】:
    --      借 1300 预付款项  = 指向 PO 的部分
    --      借 2000 应付账款  = 其余(含未核销部分 —— 与改动前对全额借 2000 一致)
    --      贷 银行          = 全额
    --    金额:核销额是 USD,分录行按原币记,故 po_ccy = round(po_usd / fx, 2),
    --    ap_ccy = p_amount − po_ccy(【相减而非各自取整】,保证两条借方的原币恰好
    --    合计等于贷方)。USD 侧由 post_journal_entry 用 round(ccy × fx, 2) 反算,
    --    非本位币下双重取整可能差 1 分,故下面在 ±0.02 内挑一个能让 USD 恰好配平的
    --    拆分点(USD 付款 fx=1,偏移恒为 0)。
    -- ========================================================================
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN 'RCPT' ELSE 'PMT' END, v_date);

    IF p_direction = 'in' THEN
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', v_bank, 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '1100', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
    ELSIF v_po_usd = 0 THEN
        -- 无预付:与改动前逐字一致
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
    ELSE
        v_ap_usd := round(v_amount_usd - v_po_usd, 2);
        IF v_ap_usd <= 0 THEN
            -- 整笔都是预付:只有一条借方,不能出现 0 元行(post_journal_entry 会拒)
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1300', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
                jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
        ELSE
            v_po_ccy := round(v_po_usd / v_fx, 2);
            v_found := false;
            FOREACH v_delta IN ARRAY ARRAY[0, 0.01, -0.01, 0.02, -0.02]::numeric[]
            LOOP
                IF v_po_ccy + v_delta > 0 AND p_amount - (v_po_ccy + v_delta) > 0
                   AND round((v_po_ccy + v_delta) * v_fx, 2)
                       + round((p_amount - v_po_ccy - v_delta) * v_fx, 2) = v_amount_usd THEN
                    v_po_ccy := v_po_ccy + v_delta;
                    v_found := true;
                    EXIT;
                END IF;
            END LOOP;
            IF NOT v_found THEN
                RAISE EXCEPTION 'PREPAY_SPLIT_UNBALANCED|%|%|%', v_amount_usd, v_po_usd, v_fx;
            END IF;
            v_ap_ccy := p_amount - v_po_ccy;
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1300', 'side', 'debit',  'currency', p_currency, 'amount_ccy', v_po_ccy, 'fx_rate', v_fx, 'line_memo', 'Prepayment'),
                jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', p_currency, 'amount_ccy', v_ap_ccy, 'fx_rate', v_fx),
                jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
        END IF;
    END IF;

    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id, v_lines);

    -- ③ 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_usd, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END,
            CASE WHEN p_direction = 'in' THEN p_counterparty_id END,
            CASE WHEN p_direction = 'out' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_usd, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- ④ 核销行落库(①已全部校验过,这里只写)
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_valid)
    LOOP
        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id,
                                         expense_id, purchase_order_id, allocated_usd)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'amount_usd')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'amount_usd', v_amount_usd,
        'journal_code', v_je->>'code',
        'allocated_total', v_alloc_total,
        'unallocated', round(v_amount_usd - v_alloc_total, 2),
        'prepaid_total', v_po_usd
    );
END;
$function$
;

-- reopen_period → module.finance.edit
CREATE OR REPLACE FUNCTION public.reopen_period(p_period_end date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_close_id uuid;
    v_new_lock date;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 与 close_period 同一把锁,串行化
    PERFORM 1 FROM finance_settings WHERE id FOR UPDATE;

    SELECT id INTO v_close_id
    FROM period_closes
    WHERE period_end = p_period_end AND reopened_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM period_closes WHERE period_end = p_period_end) THEN
            RAISE EXCEPTION 'ALREADY_REOPENED';
        END IF;
        RAISE EXCEPTION 'CLOSE_NOT_FOUND';
    END IF;

    UPDATE period_closes
    SET reopened_at = now(), reopened_by = auth.uid(), reopen_reason = btrim(p_reason)
    WHERE id = v_close_id;

    -- 更早的仍有效关账 → 其 period_end + 1;没有 → 解除锁定
    SELECT MAX(period_end) + 1 INTO v_new_lock
    FROM period_closes
    WHERE reopened_at IS NULL AND period_end < p_period_end;

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock
    );
END;
$function$
;

-- reopen_purchase_order → module.purchasing.edit
CREATE OR REPLACE FUNCTION public.reopen_purchase_order(p_purchase_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_po     record;
    v_status text;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, status INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status <> 'closed' THEN
        RAISE EXCEPTION 'PO_NOT_CLOSED|%', v_po.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 已经收过货的回到 'receiving',一车没收过的回到 'confirmed'
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM inbound_batches ib
        WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL
    ) THEN 'receiving' ELSE 'confirmed' END INTO v_status;

    UPDATE purchase_orders
    SET status = v_status,
        closed_at = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' reopened] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_purchase_order_id;

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', v_status
    );
END;
$function$
;

-- reprice_inbound_batch → module.inbound.edit
CREATE OR REPLACE FUNCTION public.reprice_inbound_batch(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_old       numeric;
    v_deleted   timestamptz;
    v_qty       numeric;
    v_remaining numeric;
    v_code      text;
    v_fx        numeric;
    v_usd       numeric;
    v_split     jsonb;
    v_delta     numeric;
    v_ratio     numeric;
    v_inv       numeric := 0;
    v_cost      numeric := 0;
    v_lines     jsonb;
    v_je        jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    SELECT unit_price, deleted_at, quantity, remaining_qty, code
    INTO v_old, v_deleted, v_qty, v_remaining, v_code
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数,与 unit_cost_usd 精度一致

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx, p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    -- 拆分算术来自 reprice_split —— 与 preview_reprice_inbound_batch 共用同一份。
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);
    v_delta := (v_split->>'delta_usd')::numeric;
    v_ratio := (v_split->>'in_stock_ratio')::numeric;

    IF v_delta <> 0 THEN
        -- 拆账:在库份额进 1200,已消耗份额进 5000;贷方(负差时借方)恒 2000
        v_inv  := (v_split->>'inventory_share_usd')::numeric;
        v_cost := (v_split->>'cost_share_usd')::numeric;

        v_lines := '[]'::jsonb;
        IF abs(v_inv) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'USD', 'amount_ccy', abs(v_inv),
                'line_memo', 'in-stock share');
        END IF;
        IF abs(v_cost) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '5000',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'USD', 'amount_ccy', abs(v_cost),
                'line_memo', 'consumed share');
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2000',
            'side', CASE WHEN v_delta > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'USD', 'amount_ccy', abs(v_delta));

        v_je := post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            v_lines
        );
    END IF;

    RETURN jsonb_build_object(
        -- 旧返回键原样保留(既有调用方靠它们)
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd,
        -- cut 5a 起的完整分解(界面与对账都要能逐项交代)
        'batch_code', v_code,
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'price_delta_usd', v_delta,
        'in_stock_ratio', v_ratio,
        'inventory_share_usd', v_inv,
        'cost_share_usd', v_cost,
        'journal_code', v_je->>'code'
    );
END;
$function$
;

-- reverse_expense → module.finance.edit
CREATE OR REPLACE FUNCTION public.reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        expenses%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry(v_orig.journal_entry_id, CURRENT_DATE, 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_mirror_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_usd, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE, v_orig.account_code,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_usd,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id
    WHERE id = p_expense_id;

    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$
;

-- reverse_journal_entry → module.finance.edit
CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        record;
    v_lines       jsonb;
    v_result      jsonb;
    v_reversal_id uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM journal_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', p_entry_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 行全部翻边(debit↔credit),原币金额/汇率原样 → USD 侧必然精确对冲。
    SELECT jsonb_agg(
        jsonb_build_object(
            'account_code', a.code,
            'side', CASE WHEN l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', l.currency,
            'amount_ccy', l.amount_ccy,
            'fx_rate', l.fx_rate,
            'line_memo', l.line_memo
        ) ORDER BY l.created_at, l.id
    ) INTO v_lines
    FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.entry_id = p_entry_id;

    -- 期间锁由 post_journal_entry 对 p_reversal_date 统一执行
    v_result := post_journal_entry(
        p_reversal_date,
        'REVERSAL: ' || COALESCE(p_memo, v_orig.memo, v_orig.code),
        v_orig.source_type,
        v_orig.id,
        v_lines
    );
    v_reversal_id := (v_result->>'entry_id')::uuid;

    UPDATE journal_entries
    SET status = 'reversed', reversed_by = v_reversal_id
    WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'reversal_id', v_reversal_id,
        'code', v_result->>'code'
    );
END;
$function$
;

-- reverse_payment → module.finance.edit
CREATE OR REPLACE FUNCTION public.reverse_payment(p_payment_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        payments%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry(v_orig.journal_entry_id, CURRENT_DATE, 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN 'RCPT' ELSE 'PMT' END, CURRENT_DATE);
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_usd, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_usd,
            v_orig.bank_account_code, CURRENT_DATE,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE payments
    SET status = 'reversed', reversed_by_payment = v_mirror_id
    WHERE id = p_payment_id;

    RETURN jsonb_build_object(
        'reversal_payment_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$
;

-- rollback_processing_run → module.processing.edit
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. 锁定加工单，校验存在且未删除
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
        FROM inbound_batches
        WHERE id = v_input.inbound_batch_id
        FOR UPDATE;

        IF NOT FOUND THEN
            CONTINUE;  -- 进料批次已被删，跳过
        END IF;

        v_new_remaining := LEAST(
            COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
            v_quantity
        );

        UPDATE inbound_batches
        SET remaining_qty = v_new_remaining,
            stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
            updated_by = v_user_id,
            updated_at = now()
        WHERE id = v_input.inbound_batch_id;

        IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
            INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, created_by)
            VALUES (v_input.inbound_batch_id, 'reversal_restore', v_new_remaining - COALESCE(v_old_remaining, 0), p_run_id, v_user_id);
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    UPDATE output_batches
    SET deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
END;
$function$
;

-- set_inbound_unit_price → module.inbound.edit
CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.inbound.edit');
    RETURN reprice_inbound_batch(p_inbound_batch_id, p_unit_price, p_currency, p_fx_rate, p_notes);
END;
$function$
;

-- unapply_assay_result → module.inbound.edit
CREATE OR REPLACE FUNCTION public.unapply_assay_result(p_assay_result_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_assay  record;
    v_latest uuid;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND OR v_assay.applied_at IS NULL THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 只许撤最近一次:链条中间抽走一环,superseded_by 的叙事就断了。
    -- code 作平局裁决(applied_at 同事务内可能相同,编号无缝单调)。
    SELECT id INTO v_latest FROM assay_results
    WHERE inbound_batch_id = v_assay.inbound_batch_id
      AND applied_at IS NOT NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_latest IS DISTINCT FROM p_assay_result_id THEN
        RAISE EXCEPTION 'NOT_LATEST_ASSAY|%', v_assay.code;
    END IF;

    UPDATE assay_results
    SET applied_at = NULL, applied_by = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unapplied] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 被本次取代的上一份化验,链解开
    UPDATE assay_results SET superseded_by = NULL, updated_by = v_user
    WHERE superseded_by = p_assay_result_id;

    -- 【刻意不回价、不回含量】撤销"已执行"标记只是承认这份结果不再作数;
    -- 价格与含量退回到哪一版,是新化验或手工计价的显式动作 —— 静默回滚一个
    -- 已经过完账、可能已被分摊读走的状态,比留着它更危险。
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_assay.inbound_batch_id,
        'reverted_price', false
    );
END;
$function$
;

-- unignore_bank_line → module.finance.edit
CREATE OR REPLACE FUNCTION public.unignore_bank_line(p_statement_line_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT l.id, l.match_status, s.status AS stmt_status
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'ignored' THEN
        RAISE EXCEPTION 'LINE_NOT_IGNORED|%', v_line.match_status;
    END IF;

    UPDATE bank_statement_lines
    SET match_status = 'unmatched', ignore_reason = NULL
    WHERE id = p_statement_line_id;
END;
$function$
;

-- unmatch_bank_line → module.finance.edit
CREATE OR REPLACE FUNCTION public.unmatch_bank_line(p_statement_line_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT l.id, l.match_status, s.status AS stmt_status
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'matched' THEN
        RAISE EXCEPTION 'LINE_NOT_MATCHED|%', v_line.match_status;
    END IF;

    DELETE FROM bank_line_matches WHERE statement_line_id = p_statement_line_id;
    UPDATE bank_statement_lines SET match_status = 'unmatched' WHERE id = p_statement_line_id;
END;
$function$
;

-- unpost_payroll_period → module.hr.edit
CREATE OR REPLACE FUNCTION public.unpost_payroll_period(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_p    record;
    v_je   jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 冲销分录(冲销日 = 今天);原分录留在账上并被标记为已冲销 —— 不删账
    v_je := reverse_journal_entry(v_p.journal_entry_id, CURRENT_DATE, 'Payroll reversal ' || v_p.code);

    UPDATE payroll_periods
    SET status = 'draft',
        journal_entry_id = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unposted] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_id,
        'code', v_p.code,
        'status', 'draft',
        'reversal_journal_code', v_je->>'code'
    );
END;
$function$
;

-- unreconcile_statement → module.finance.edit
CREATE OR REPLACE FUNCTION public.unreconcile_statement(p_statement_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'reconciled' THEN
        RAISE EXCEPTION 'STATEMENT_NOT_RECONCILED|%', v_stmt.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE bank_statements
    SET status = 'open',
        reconciled_at = NULL,
        reconciled_by = NULL,
        notes = COALESCE(notes || E'\n', '') || 'UNRECONCILED ' || now()::text || ': ' || btrim(p_reason)
    WHERE id = p_statement_id;
END;
$function$
;

-- upsert_metal_prices → module.pricing.edit
CREATE OR REPLACE FUNCTION public.upsert_metal_prices(p_price_date date, p_prices jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_el       jsonb;
    v_metal    text;
    v_raw      text;
    v_price    numeric;
    v_inserted integer := 0;
    v_updated  integer := 0;
    v_skipped  integer := 0;
    v_was_ins  boolean;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;

        -- 空值跳过而不是报错:UI 的每日录入表单常常只填了其中几个金属。
        v_raw := v_el->>'price_usd_per_tonne';
        IF v_raw IS NULL OR btrim(v_raw) = '' THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        v_price := v_raw::numeric;
        IF v_price IS NULL OR v_price <= 0 THEN
            RAISE EXCEPTION 'PRICE_INVALID|%|%', v_metal, v_raw;
        END IF;

        -- (metal, price_date) 唯一。软删的行也占着这个位置 —— 撞上就顺手复活它
        -- (deleted_at = NULL)并写入新价,这两种情形都算 updated。
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, created_by, updated_by)
        VALUES (v_metal, v_price, p_price_date, 'manual', v_user, v_user)
        ON CONFLICT (metal, price_date) DO UPDATE
        SET price_usd_per_tonne = EXCLUDED.price_usd_per_tonne,
            source              = EXCLUDED.source,
            deleted_at          = NULL,
            updated_by          = v_user
        RETURNING (xmax = 0) INTO v_was_ins;

        IF v_was_ins THEN
            v_inserted := v_inserted + 1;
        ELSE
            v_updated := v_updated + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'price_date', p_price_date,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped
    );
END;
$function$
;

-- upsert_payroll_period → module.hr.edit
CREATE OR REPLACE FUNCTION public.upsert_payroll_period(p_period_month date, p_payment_date date, p_currency text, p_fx_rate numeric, p_source_note text, p_notes text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_period   record;
    v_id       uuid;
    v_code     text;
    v_el       jsonb;
    v_emp      record;
    v_seen     uuid[] := ARRAY[]::uuid[];
    v_gross    numeric;
    v_er_cpf   numeric;
    v_ee_cpf   numeric;
    v_other    numeric;
    v_net      numeric;
    v_expected numeric;
    v_count    integer := 0;
    v_t_gross  numeric := 0;
    v_t_er     numeric := 0;
    v_t_ee     numeric := 0;
    v_t_other  numeric := 0;
    v_t_net    numeric := 0;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_period_month IS NULL OR p_period_month <> date_trunc('month', p_period_month)::date THEN
        RAISE EXCEPTION 'PERIOD_MONTH_INVALID|%', COALESCE(p_period_month::text, '?');
    END IF;
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_fx_rate IS NULL OR p_fx_rate <= 0 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', COALESCE(p_fx_rate::text, '?');
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    SELECT * INTO v_period FROM payroll_periods
    WHERE period_month = p_period_month AND deleted_at IS NULL
    FOR UPDATE;

    IF FOUND THEN
        -- 已过账的周期不接受重导:先 unpost 才能改(总账已经认了这批数)
        IF v_period.status = 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_POSTED|%', v_period.code;
        END IF;
        v_id := v_period.id;
        v_code := v_period.code;
        UPDATE payroll_periods
        SET payment_date = p_payment_date, currency = p_currency, fx_rate = p_fx_rate,
            source_note = p_source_note, notes = p_notes, updated_by = v_user
        WHERE id = v_id;
        DELETE FROM payroll_lines WHERE payroll_period_id = v_id;
    ELSE
        v_id := gen_random_uuid();
        v_code := next_payroll_code(p_period_month);
        INSERT INTO payroll_periods (id, code, period_month, payment_date, currency, fx_rate,
                                     source_note, notes, created_by, updated_by)
        VALUES (v_id, v_code, p_period_month, p_payment_date, p_currency, p_fx_rate,
                p_source_note, p_notes, v_user, v_user);
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        SELECT id, code INTO v_emp FROM employees
        WHERE id = (v_el->>'employee_id')::uuid AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(v_el->>'employee_id', '?');
        END IF;
        IF v_emp.id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_EMPLOYEE|%', v_emp.code;
        END IF;
        v_seen := v_seen || v_emp.id;

        v_gross  := (v_el->>'gross_pay')::numeric;
        v_er_cpf := COALESCE((v_el->>'employer_cpf')::numeric, 0);
        v_ee_cpf := COALESCE((v_el->>'employee_cpf')::numeric, 0);
        v_other  := COALESCE((v_el->>'other_deductions')::numeric, 0);
        v_net    := (v_el->>'net_pay')::numeric;

        IF v_gross IS NULL OR v_net IS NULL
           OR v_gross < 0 OR v_er_cpf < 0 OR v_ee_cpf < 0 OR v_other < 0 OR v_net < 0 THEN
            RAISE EXCEPTION 'AMOUNT_INVALID|%', v_emp.code;
        END IF;

        -- 服务商给的行必须自洽。这是本函数【唯一】的算术 —— 不是在算工资,
        -- 是在把录错/解析错的一行挡在总账之外。
        v_expected := round(v_gross - v_ee_cpf - v_other, 2);
        IF v_expected <> round(v_net, 2) THEN
            RAISE EXCEPTION 'LINE_NOT_BALANCED|%|%|%', v_emp.code, v_expected, round(v_net, 2);
        END IF;

        INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, employer_cpf,
                                   employee_cpf, other_deductions, net_pay, notes)
        VALUES (v_id, v_emp.id, v_gross, v_er_cpf, v_ee_cpf, v_other, v_net, v_el->>'notes');

        v_count := v_count + 1;
        v_t_gross := v_t_gross + v_gross;
        v_t_er    := v_t_er + v_er_cpf;
        v_t_ee    := v_t_ee + v_ee_cpf;
        v_t_other := v_t_other + v_other;
        v_t_net   := v_t_net + v_net;
    END LOOP;

    UPDATE payroll_periods
    SET gross_total = round(v_t_gross, 2),
        employer_cpf_total = round(v_t_er, 2),
        employee_cpf_total = round(v_t_ee, 2),
        other_deductions_total = round(v_t_other, 2),
        net_pay_total = round(v_t_net, 2),
        updated_by = v_user
    WHERE id = v_id;

    RETURN jsonb_build_object(
        'payroll_period_id', v_id,
        'code', v_code,
        'line_count', v_count,
        'gross_total', round(v_t_gross, 2),
        'employer_cpf_total', round(v_t_er, 2),
        'employee_cpf_total', round(v_t_ee, 2),
        'other_deductions_total', round(v_t_other, 2),
        'net_pay_total', round(v_t_net, 2)
    );
END;
$function$
;

-- void_invoice → module.finance.edit
CREATE OR REPLACE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INVOICE_ALREADY_VOID|%', v_inv.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 明细行保留供审计;作废标记由 trg_invoices_propagate_void 同步到明细行,
    -- 这些销售随之重新可开票。
    UPDATE invoices
    SET status = 'void',
        void_reason = btrim(p_reason),
        voided_at = now(),
        voided_by = auth.uid()
    WHERE id = p_invoice_id;

    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'status', 'void'
    );
END;
$function$
;

-- ---------------------------------------------------------------- (c) 保持 INVOKER
-- post_journal_entry:RLS 就是它的闸门。财务直接调过、仓储直接调被拒、
-- 从 DEFINER 函数里调则以属主身份放行 —— 一个函数三种正确结果。
-- 它今天已经是 INVOKER,这里不动它,写在这里是为了让这条决定在文件里留痕。

COMMIT;
