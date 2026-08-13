-- db/tables/permissions.sql
-- 权限目录:系统里"可以被控制的东西"的清单。
--
-- 【"角色与授权皆数据"的唯一例外就在这张表】。本表【不开放】INSERT/UPDATE/DELETE
-- 策略,只给 SELECT。原因不是保守:新增一条权限【本身就不可能是纯数据】—— 一个
-- 权限码只有在有代码去检查它的时候才有意义(得先有策略或页面引用它)。所以扩充
-- 目录天然是"迁移级"的动作,代码与目录一起走。
-- 真正需要 Tim 反复调整的是【角色】(roles)与【授权】(role_permissions),
-- 那两张表是完全可编辑的数据。
--
-- 无软删、无审计列:这是目录不是台账。删掉一条仍被角色引用的权限应当是不可能的 ——
-- role_permissions 的 FK(ON DELETE RESTRICT)负责挡住。
-- category:'module' 控制模块可见性;'data' 横切各模块控制"看得见哪一层数字";
-- 'action' 留给过账、关账、薪资过账这类动作级权限 —— 到时候【只是加行】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm1-permission-skeleton.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.permissions (
    code           text PRIMARY KEY,  -- 稳定标识,如 'module.finance' / 'data.view_prices'
    category       text NOT NULL CHECK (category IN ('module','data','action')),
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    description_en text,
    description_zh text,
    sort_order     integer NOT NULL DEFAULT 0
);

ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "permissions select by permission"
    ON public.permissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 【安装种子 / INSTALL SEED】没有这些行,权限系统无从谈起。
-- 本表【逐行跟踪线上】,check_mirrors.py 逐行比对 —— 少一行、多一行、内容不符都判失败。
--
-- 【本表是迁移专属的】db/scripts/ 下的数据脚本【永远不许写它】。理由就在文件头:
-- 一个权限码只有在有代码去检查它的时候才有意义,所以扩充目录天生是迁移级动作。
-- 这条规矩让 db/scripts/README.md 那句"脚本不涉及镜像"继续成立:脚本碰不到任何
-- 被镜像逐行跟踪的表,于是脚本确实永远不需要更新镜像。
--
-- ⚠️ 这里正是 OPS-1 的案发现场:perm3 加的 data.view_banking 与 perm3b 加的
--    data.view_sales 当年只写进了迁移,没写回本文件;perm2a 把 module.<m> 一分为二
--    时,本文件也停留在旧的 13 个未拆分码上。check_mirrors 只比结构不比数据,
--    于是它一路是绿的。现在补齐,并且从此比对种子行。
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('module.suppliers.view', 'module', 'Suppliers (view)', '供应商(查看)', 'Supplier master data — read only', '供应商主数据 —— 只读', 10),
    ('module.suppliers.edit', 'module', 'Suppliers (edit)', '供应商(编辑)', 'Supplier master data — create, change, remove', '供应商主数据 —— 新建、修改、删除', 11),
    ('module.customers.view', 'module', 'Customers (view)', '客户(查看)', 'Customer master data — read only', '客户主数据 —— 只读', 20),
    ('module.customers.edit', 'module', 'Customers (edit)', '客户(编辑)', 'Customer master data — create, change, remove', '客户主数据 —— 新建、修改、删除', 21),
    ('module.materials.view', 'module', 'Materials (view)', '物料(查看)', 'Material dictionary — read only', '物料字典 —— 只读', 30),
    ('module.materials.edit', 'module', 'Materials (edit)', '物料(编辑)', 'Material dictionary — create, change, remove', '物料字典 —— 新建、修改、删除', 31),
    ('module.pricing.view', 'module', 'Pricing (view)', '定价(查看)', 'Pricing formulas, calculator, metal prices — read only', '定价公式、计价器与金属行情 —— 只读', 40),
    ('module.pricing.edit', 'module', 'Pricing (edit)', '定价(编辑)', 'Pricing formulas, calculator, metal prices — create, change, remove', '定价公式、计价器与金属行情 —— 新建、修改、删除', 41),
    ('module.purchasing.view', 'module', 'Purchasing (view)', '采购(查看)', 'Purchase orders and payment schedules — read only', '采购单与付款计划 —— 只读', 50),
    ('module.purchasing.edit', 'module', 'Purchasing (edit)', '采购(编辑)', 'Purchase orders and payment schedules — create, change, remove', '采购单与付款计划 —— 新建、修改、删除', 51),
    ('module.inbound.view', 'module', 'Inbound (view)', '进料(查看)', 'Inbound batches and receiving — read only', '进料批次与收货 —— 只读', 60),
    ('module.inbound.edit', 'module', 'Inbound (edit)', '进料(编辑)', 'Inbound batches and receiving — create, change, remove', '进料批次与收货 —— 新建、修改、删除', 61),
    ('module.output.view', 'module', 'Output (view)', '产出(查看)', 'Output batches and sales — read only', '产出批次与销售 —— 只读', 70),
    ('module.output.edit', 'module', 'Output (edit)', '产出(编辑)', 'Output batches and sales — create, change, remove', '产出批次与销售 —— 新建、修改、删除', 71),
    ('module.processing.view', 'module', 'Processing (view)', '加工(查看)', 'Processing runs and traceability — read only', '加工单与追溯 —— 只读', 80),
    ('module.processing.edit', 'module', 'Processing (edit)', '加工(编辑)', 'Processing runs and traceability — create, change, remove', '加工单与追溯 —— 新建、修改、删除', 81),
    ('module.inventory.view', 'module', 'Inventory (view)', '库存(查看)', 'Inventory and material balance — read only', '库存与物料平衡 —— 只读', 90),
    ('module.inventory.edit', 'module', 'Inventory (edit)', '库存(编辑)', 'Inventory and material balance — create, change, remove', '库存与物料平衡 —— 新建、修改、删除', 91),
    ('module.stocktakes.view', 'module', 'Stocktakes (view)', '盘点(查看)', 'Physical counts and adjustments — read only', '实物盘点与调整 —— 只读', 100),
    ('module.stocktakes.edit', 'module', 'Stocktakes (edit)', '盘点(编辑)', 'Physical counts and adjustments — create, change, remove', '实物盘点与调整 —— 新建、修改、删除', 101),
    ('module.finance.view', 'module', 'Finance (view)', '财务(查看)', 'Ledger, receivables, payables, payments — read only', '总账、应收、应付与收付款 —— 只读', 110),
    ('module.finance.edit', 'module', 'Finance (edit)', '财务(编辑)', 'Ledger, receivables, payables, payments — create, change, remove', '总账、应收、应付与收付款 —— 新建、修改、删除', 111),
    ('module.hr.view', 'module', 'HR (view)', '人力资源(查看)', 'Employees, payroll and training — read only', '员工、薪资与培训 —— 只读', 120),
    ('module.hr.edit', 'module', 'HR (edit)', '人力资源(编辑)', 'Employees, payroll and training — create, change, remove', '员工、薪资与培训 —— 新建、修改、删除', 121),
    ('module.tasks.view', 'module', 'Tasks (view)', '任务(查看)', 'Task board — read only', '任务板 —— 只读', 130),
    ('module.tasks.edit', 'module', 'Tasks (edit)', '任务(编辑)', 'Task board — create, change, remove', '任务板 —— 新建、修改、删除', 131),
    -- SO-1-fu:销售是一个真模块(自己的单据、角色、操作面)。订单先于财务 ——
    -- 财务拥有的是事后那条链(sales_records / invoices / AR)。
    ('module.sales.view', 'module', 'Sales orders (view)', '销售订单(查看)', 'Sales orders — read only', '销售订单 —— 只读', 132),
    ('module.sales.edit', 'module', 'Sales orders (edit)', '销售订单(编辑)', 'Sales orders — create, confirm, cancel, issue', '销售订单 —— 新建、确认、作废、签发', 133),
    ('data.view_prices', 'data', 'View prices & costs', '查看价格与成本', 'Unit prices, pricing formulas, costs and margins', '单价、计价公式、成本与利润', 200),
    ('data.view_pay', 'data', 'View pay', '查看薪酬', 'Salary, CPF and payroll figures', '工资、公积金与薪资明细', 210),
    ('data.view_identity', 'data', 'View identity data', '查看身份信息', 'Identity numbers and work pass numbers', '身份证件号与工作准证号', 220),
    ('data.view_banking', 'data', 'View company bank details', '查看公司银行明细', 'Company bank account name, number, SWIFT and bank address as printed on invoices', '开在发票上的公司银行户名、账号、SWIFT 与开户行地址', 230),
    ('data.view_sales', 'data', 'View sales records', '查看销售记录', 'Quantity, unit price, amount, customer and date of sales made from output batches', '产出批次的销售数量、单价、金额、客户与日期', 240),
    ('data.view_reviews', 'data', 'View performance review content', '查看绩效评估正文', 'Ratings, written conclusions, self-assessments and goal results in performance reviews', '绩效评估中的评级、书面结论、自评与目标结果', 250),
    ('action.manage_permissions', 'action', 'Manage roles & permissions', '管理角色与权限', 'Create roles and change who holds what', '新建角色、调整授权', 300);
