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
    ('module.pricing.edit', 'module', 'Pricing (edit)', '定价(编辑)', 'Pricing formulas — create, change, remove. Metal prices moved to their own action code.', '定价公式 —— 新建、修改、删除。金属行情已移到它自己的动作码。', 41),
    ('module.purchasing.view', 'module', 'Purchasing (view)', '采购(查看)', 'Purchase orders and payment schedules — read only', '采购单与付款计划 —— 只读', 50),
    ('module.purchasing.edit', 'module', 'Purchasing (edit)', '采购(编辑)', 'Purchase orders and payment schedules — create, change, remove', '采购单与付款计划 —— 新建、修改、删除', 51),
    ('module.inbound.view', 'module', 'Inbound (view)', '进料(查看)', 'Inbound batches and receiving — read only', '进料批次与收货 —— 只读', 60),
    ('module.inbound.edit', 'module', 'Inbound (edit)', '进料(编辑)', 'Inbound batches and receiving — create, change, remove', '进料批次与收货 —— 新建、修改、删除', 61),
    ('module.output.view', 'module', 'Output (view)', '产出(查看)', 'Output batches and sales — read only', '产出批次与销售 —— 只读', 70),
    ('module.output.edit', 'module', 'Output (edit)', '产出(编辑)', 'Output batches and their lab results — create, change, remove. Direct sale and assay application moved to their own action codes.', '产出批次与它的化验结果 —— 新建、修改、删除。直接销售与化验应用已移到各自的动作码。', 71),
    ('module.processing.view', 'module', 'Processing (view)', '加工(查看)', 'Processing runs and traceability — read only', '加工单与追溯 —— 只读', 80),
    ('module.processing.edit', 'module', 'Processing (edit)', '加工(编辑)', 'Processing runs and traceability — create, change, remove', '加工单与追溯 —— 新建、修改、删除', 81),
    ('module.inventory.view', 'module', 'Inventory (view)', '库存(查看)', 'Inventory and material balance — read only', '库存与物料平衡 —— 只读', 90),
    ('module.inventory.edit', 'module', 'Inventory (edit)', '库存(编辑)', 'Inventory and material balance — create, change, remove', '库存与物料平衡 —— 新建、修改、删除', 91),
    ('module.stocktakes.view', 'module', 'Stocktakes (view)', '盘点(查看)', 'Physical counts and adjustments — read only', '实物盘点与调整 —— 只读', 100),
    ('module.stocktakes.edit', 'module', 'Stocktakes (edit)', '盘点(编辑)', 'Cancel an open stocktake. Opening and counting are "Open stocktakes and count"; posting is "Post stocktakes".', '取消一张未过账的盘点单。开单与录数是「开盘点单与录数」;过账是「盘点过账」。', 101),
    ('module.finance.view', 'module', 'Finance (view)', '财务(查看)', 'Ledger, receivables, payables, payments — read only', '总账、应收、应付与收付款 —— 只读', 110),
    ('module.finance.edit', 'module', 'Finance (edit)', '财务(编辑)', 'Ledger, receivables, payables, payments — create, change, remove', '总账、应收、应付与收付款 —— 新建、修改、删除', 111),
    ('module.hr.view', 'module', 'HR (view)', '人力资源(查看)', 'Employees, payroll and training — read only', '员工、薪资与培训 —— 只读', 120),
    ('module.hr.edit', 'module', 'HR (edit)', '人力资源(编辑)', 'Employees, payroll, attendance, leave and training — create, change, remove. Not performance reviews or KPI (ROLE-1).', '员工、薪资、考勤、假期与培训 —— 新建、修改、删除。不含绩效评估与 KPI(ROLE-1)。', 121),
    ('module.tasks.view', 'module', 'Tasks (view)', '任务(查看)', 'Task board — read only', '任务板 —— 只读', 130),
    ('module.tasks.edit', 'module', 'Tasks (edit)', '任务(编辑)', 'Task board — create, change, remove', '任务板 —— 新建、修改、删除', 131),
    -- TASK-1a:一把【点名的】钥匙,默认没有任何角色持有(role_permissions 里查不到它)。
    -- 描述照直说它是什么 —— 「读别人的私人任务」,不是"任务模块的管理权限":
    -- 私人任务上那个「私人」的标签,只在没有人持有这条权限时才是诚实的,
    -- 所以一旦有人被授予它,读到这份清单的人必须一眼看出那意味着什么。
    ('module.tasks.view_all', 'module', 'Tasks (read others'' personal)', '任务(查看他人私人任务)', 'Reads OTHER PEOPLE''S PERSONAL tasks. Not general admin access.', '读【别人的私人任务】。这不是"任务模块的管理权限",就是这一件事。', 132),
    -- SO-1-fu:销售是一个真模块(自己的单据、角色、操作面)。订单先于财务 ——
    -- 财务拥有的是事后那条链(sales_records / invoices / AR)。
    ('module.sales.view', 'module', 'Sales orders (view)', '销售订单(查看)', 'Sales orders — read only', '销售订单 —— 只读', 132),
    ('module.sales.edit', 'module', 'Sales orders (edit)', '销售订单(编辑)', 'Sales orders — create, confirm, cancel, issue', '销售订单 —— 新建、确认、作废、签发', 133),
    -- NAV-REG-1 / R2:物流终于有自己的码。在这之前它借 module.purchasing.view,
    -- 而实测的受害者是 operations / warehouse / sales —— 搬货的人看不见物流。
    -- 【没有配套的 .edit】八张物流表的写策略仍然是 module.purchasing.edit,
    -- 而持有它的四个角色全都被授予了本码,所以不存在"改得动、读不回"的倒挂;
    -- 铸一个没有任何策略引用的码,就是铸一个死码。
    ('module.logistics.view', 'module', 'Logistics (view)', '物流(查看)', 'Forwarders, lanes, rate quotes, containers and shipping documents — read only', '货代、航段、报价、集装箱与随船单据 —— 只读', 140),
    -- ★ ROLE-1 Batch 4a(Tim 的 Q9 线,2026-09-25):价格码一分为二。data.view_prices 从此管【销售与成本】
    --   那一侧;采购那一侧(采购单、质保金、付款条款、公式与条款承诺、计价器、收货单价与改价历史、
    --   应付账龄)归 data.view_purchase_prices。今天持前者的每一个角色一并拿到后者;仓库只拿后者。
    ('data.view_prices', 'data', 'View sales prices & costs', '查看销售价格与成本', 'Sales prices, invoices, receivables, landed cost, inventory valuation, processing cost and margin. Purchase-side prices are under View purchase prices.', '销售价格、发票、应收、到岸成本、存货计值、加工成本与毛利。采购那一侧的价格归「查看采购价格」。', 200),
    ('data.view_purchase_prices', 'data', 'View purchase prices', '查看采购价格', 'Purchase orders and their lines, retentions and payment terms, purchase pricing formulas and committed terms, the calculator, receipt unit prices and price history, and payables ageing. Seeing a receipt price does not allow setting it.', '采购单与采购行、质保金与付款条款、采购计价公式与已承诺条款、计价器、收货单价与改价历史、应付账龄。看得见收货价不等于定得了价。', 205),
    ('data.view_pay', 'data', 'View pay', '查看薪酬', 'Salary, CPF and payroll figures', '工资、公积金与薪资明细', 210),
    ('data.view_identity', 'data', 'View identity data', '查看身份信息', 'Identity numbers and work pass numbers', '身份证件号与工作准证号', 220),
    ('data.view_banking', 'data', 'View company bank details', '查看公司银行明细', 'Company bank account name, number, SWIFT and bank address as printed on invoices', '开在发票上的公司银行户名、账号、SWIFT 与开户行地址', 230),
    ('data.view_sales', 'data', 'View sales records', '查看销售记录', 'Quantity, unit price, amount, customer and date of sales made from output batches', '产出批次的销售数量、单价、金额、客户与日期', 240),
    -- ★ NAV-CLEANUP-1 ①(2026-09-03):被删记录【自己的】码。★
    -- 铸它是因为「auditor 进、gm 不进」在旧词汇里【表达不出来】:allows() 单调,
    -- 而 gm 的权限集真包含 auditor 的 —— 证明写在那支迁移的抬头。
    -- **只授 admin 与 auditor。审计性质,不是日常权限。**
    ('data.view_deleted', 'data', 'View deleted records', '查看已删除记录', 'The deleted-records register: what was removed, by whom and why, across every module. Audit-natured — not a day-to-day permission.', '被删记录台账:跨模块地看"什么被删了、谁删的、为什么"。审计性质 —— 不是一条日常权限。', 260),
    ('data.view_reviews', 'data', 'View performance review content', '查看绩效评估正文', 'Ratings, written conclusions, self-assessments and goal results in performance reviews', '绩效评估中的评级、书面结论、自评与目标结果', 250),
    -- ★ APR-ROUTE-1(Tim 的 R2 · Q4):自批报表自己的码。只授 admin · gm · auditor。
    --   不借 module.finance.view / module.hr.view —— 被这张表报告的人(二级审批角色
    --   的持有人)自己就持有那两个,而 Tim 要的读者是另外那几位。
    ('data.view_self_approvals', 'data', 'View self-approved decisions', '查看自批记录', 'Every expense claim or medical claim decided by the person it is about — the one exception to "nobody decides their own", open to the top approval level only and flagged every time', '每一张由单据主角本人决定的报销单或医疗申报 —— "没有人批自己的单"的唯一例外,只对最高审批级别开放,每一次都被标记', 270),
    ('action.manage_permissions', 'action', 'Manage roles & permissions', '管理角色与权限', 'Create roles and change who holds what', '新建角色、调整授权', 300),
    -- IMPORT-1:批量导入自己一个码。**不复用 action.manage_permissions** ——
    -- 那会重演 DICT-ADMIN 之前的缺陷(一个物料编辑员永远够不到物料那张屏),
    -- 而它也不等于"能编辑一家供应商":它是唯一一个一次能插入数百行的动作。
    ('action.bulk_import', 'action', 'Bulk import master data', '批量导入主数据', 'Load materials, counterparties, employees, departments and storage locations from a CSV file. This is the only action that can insert hundreds of rows at once.', '从 CSV 文件批量装入物料、往来户、员工、部门与库位。这是唯一一个一次能插入数百行的动作。', 910),
    -- COD-1:签发销毁证书。**是一个【动作】,不是一个模块、也不是一类数据** ——
    -- 签发的人本来就站在收货那张页面上,他缺的不是「进得去哪个模块」,而是
    -- 「可不可以把这张纸寄出去」。能力够得着的正好是证书需要的:供应商的
    -- 【名字】与这票货背后的加工事实,一格都不多(见 cod_certificate_data)。
    ('action.issue_cod', 'action', 'Issue certificate of destruction', '签发销毁证书', 'Issue a certificate of destruction to the supplier who delivered the material.', '向送料方签发销毁证书', 920),
    -- ★ ROLE-1(Tim 的角色与审批矩阵,2026-09-23 · docs/role-matrix.md):一个码管一整族动作,
    --   矩阵要把同一族里的几件事交给不同的人,于是拆出下面五个【点名的】动作码。
    --   每一个的描述都照直说它放行的是哪几件事 —— 读授权清单的人要一眼看出给出去的是什么。
    ('action.finance_reopen', 'action', 'Reopen closed months; close and reopen financial years', '重开已关的月;年结与重开年度', 'Reopen a closed month, close a financial year, reopen a closed financial year. Month-end close itself stays with Finance (edit).', '重开一个已关的月、年结、重开一个已结的年度。月结本身仍归「财务(编辑)」。', 930),
    ('action.approve_review', 'action', 'Approve performance reviews', '批准绩效评估', 'Approve a submitted performance review — which can change the person''s monthly salary. When the holder of this code is the review''s submitter or subject, the review is approved under "Performance reviews & KPI" instead.', '批准一张已提交的绩效评估 —— 它可以改变那个人的月薪。持有本码的人是这张评估的提交人或主角时,改由「绩效评估与 KPI」批准。', 940),
    ('action.decide_hr_requests', 'action', 'Decide leave requests and medical claims', '决定请假与医疗申报', 'Approve or reject leave requests and medical claims. Nobody decides their own, except the top approval level, whose own decisions are flagged.', '批准或驳回请假与医疗申报。没有人决定自己的单 —— 最高一级审批例外,每一次都被标记。', 950),
    ('action.hr_reviews', 'action', 'Performance reviews & KPI', '绩效评估与 KPI', 'Run the KPI and performance-review work: cycles, goals, scoring, reviewers, conclusions and the salary proposal. Does not include any other HR or payroll work.', '做 KPI 与绩效评估这一块:周期、目标、打分、评估人、结论与调薪建议。不含任何其他人事或薪资工作。', 960),
    ('action.anonymise_employee', 'action', 'Anonymise an employee record', '匿名化员工档案', 'Irreversibly anonymise a separated employee''s personal data. System administration only.', '不可逆地抹去一名离职员工的个人数据。仅限系统管理。', 970),
    -- ★ ROLE-1 · Batch 2a(Tim 的矩阵 §6 / §10 / §12,Batch 2 grilling Q8–Q11):三件【只归 CFO】的事。
    --   CFO 不持任何 .edit 码,所以每一件都是一个点名的动作码 + 一支 SECURITY DEFINER 的写入口。
    ('action.finance_settings', 'action', 'Finance settings, chart of accounts, currencies and company details', '财务设置、科目表、币种与公司资料', 'Change the chart of accounts, currencies, the company profile (including bank details and logo), GST registration and the other finance settings. The period lock stays with Finance (edit); the approvals switch and policy stay with system administration.', '修改科目表、币种、公司资料(含银行资料与标志)、GST 登记与其余财务设置。锁期仍归「财务(编辑)」;审批开关与策略仍归系统管理。', 980),
    ('action.customer_credit', 'action', 'Set customer credit limits and holds', '设定客户信用额度与冻结', 'Set or clear a customer''s credit limit and put a customer on or off credit hold. Every other customer field stays with Customers (edit).', '设定或清除客户的信用额度,冻结或解冻客户。客户的其余各项仍归「客户(编辑)」。', 990),
    ('action.supplier_approve', 'action', 'Approve, reject, blacklist and restore suppliers', '批准、驳回、拉黑与恢复供应商', 'Approve or reject a supplier submitted for review, blacklist a supplier, and restore a blacklisted one (move it to archived). Nobody approves a supplier they created. Every other status move stays with Suppliers (edit).', '批准或驳回一家送审的供应商,拉黑一家供应商,把一家被拉黑的恢复(移到归档)。没有人批准自己建的供应商。其余状态变动仍归「供应商(编辑)」。', 1000),
    ('action.contract_terms', 'action', 'Contracts and their terms', '合同与合同条款', 'Create contracts and write their terms: grade specifications, pricing, refining charges, penalties, settlement, volume commitments and insurance. Linking a purchase or sales document to a contract stays with the code that raises the document.', '新建合同并写它的条款:品位规格、计价、精炼费、罚则、结算、数量承诺与保险。把一张采购或销售单据挂到合同上,仍归开那张单据的码。', 1010),
    ('action.metal_prices', 'action', 'Metal prices, indices and the quote threshold', '金属行情、指数与报价阈值', 'Enter and correct daily metal prices, maintain price indices and the index market calendar, and set the stale-quote threshold. Pricing formulas stay with Pricing (edit).', '录入与更正每日金属行情,维护价格指数与指数交易日历,设定报价过期阈值。定价公式仍归「定价(编辑)」。', 1020),
    ('action.direct_sale', 'action', 'Sell directly from an output batch', '从产出批次直接销售', 'Record a sale straight from an output batch, outside a sales order. It posts revenue and cost of goods. Sales orders and shipping stay with Sales (edit).', '不经销售订单,直接从一个产出批次记一笔销售;它过收入与销货成本。销售订单与发货仍归「销售(编辑)」。', 1030),
    ('action.apply_assay', 'action', 'Apply and unapply assay results', '应用与撤销应用化验结果', 'Apply a recorded lab result to an inbound or output batch, undo that application, and see what applying would do. Applying an inbound assay reprices the batch and posts to the supplier payable. Recording a lab result stays with Inbound (edit) and Output (edit).', '把一份已记录的化验结果应用到进料或产出批次上、撤销这次应用,并预览应用会带来什么。应用进料化验会给批次重新定价,并过到供应商应付。记录化验结果仍归「进料(编辑)」与「产出(编辑)」。', 1040),
    -- ★ ROLE-1 Batch 4a(Tim 2026-09-25,grilling Q1):收货定价与改价归财务。库里同时问看不看得见采购价。
    ('action.price_receipts', 'action', 'Price and reprice goods receipts', '收货定价与改价', 'Set or change a goods receipt''s unit price — on the receipt, when creating it, or from committed terms. Every change posts to the supplier payable. Requires View purchase prices as well. Applying an assay stays with Apply assay results.', '给收货单定价或改价 —— 在收货单上、建单时,或按已承诺条款。每一次都过到供应商应付。同时要有「查看采购价格」。应用化验仍归「应用化验结果」。', 1050),
    -- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2–Q4):盘点录数归仓库、过账归财务;
    --   录过数的人与开单人永远不能过账(按人认)。取消盘点仍归 module.stocktakes.edit。
    ('action.stocktake_count', 'action', 'Open stocktakes and count', '开盘点单与录数', 'Open a stocktake and record counted quantities on it. Every count and recount is kept with the person who made it; nobody who counted a stocktake, or opened it, may post it. Cancelling a stocktake stays with Stocktakes (edit).', '开一张盘点单并在上面录实点数。每一次录数与重录都连同录数的人一起留下;数过一张盘点单或开过它的人,永远不能过账它。取消盘点仍归「盘点(编辑)」。', 1060),
    ('action.stocktake_post', 'action', 'Post stocktakes', '盘点过账', 'Post a counted stocktake: the differences go into stock and to the ledger (stock gain or loss). Nobody posts a stocktake they opened or counted on.', '把一张数完的盘点单过账:差异进库存、过总账(盘盈或盘亏)。没有人能过账自己开的或数过的盘点单。', 1070),
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q1 · Q6–Q9;Batch 3b grilling Q2):
    --   收货建单、工单、加工提交、回滚、注销批次与加工善后各有自己的码;工单建与下达分开,建单人永远不能下达(按人认)。
    ('action.receive_goods', 'action', 'Create goods receipts', '建收货单', 'Create a goods receipt at the desk, or receive against a purchase order on the floor. Pricing a receipt stays with Price and reprice goods receipts; editing a receipt stays with Inbound (edit).', '在收货台建一张收货单,或在现场按采购单收货。给收货定价仍归「收货定价与改价」;修改收货单仍归「进料(编辑)」。', 1080),
    ('action.batch_write_off', 'action', 'Write off batches', '注销批次', 'Write off an inbound or an output batch, with a reason; the stock leaves the books. Until a write-off request exists, whoever holds this code does it alone.', '注销一个进料或产出批次,要写理由;这批货从账上离开。在注销申请落地之前,持这个码的人一个人做完。', 1090),
    ('action.wo_create', 'action', 'Create work orders', '建工单', 'Create a work order, and amend, cancel or close one (Processing (edit) may also amend, cancel and close). Releasing it is Release work orders; nobody releases a work order they created.', '建一张工单,以及修改、取消、关闭工单(「加工(编辑)」也可以改、取消、关闭)。下达是「下达工单」;没有人能下达自己建的工单。', 1100),
    ('action.wo_release', 'action', 'Release work orders', '下达工单', 'Release a draft work order so that processing runs can be committed against it. Nobody releases a work order they created (judged per person, across their accounts).', '下达一张草稿工单,之后才能照它提交加工。没有人能下达自己建的工单(按人认,跨账号)。', 1110),
    ('action.processing_commit', 'action', 'Commit processing runs', '提交加工', 'Commit a processing run: the inputs leave stock and the outputs are created, against a released work order or on their own. Allocating processing cost stays with Finance (edit).', '提交一次加工:投料出库、产出入库,照一张已下达的工单或单独一次。分摊加工成本仍归「财务(编辑)」。', 1120),
    ('action.processing_rollback', 'action', 'Roll back processing runs', '回滚加工', 'Reverse a committed processing run, with a reason: the inputs return to stock and the outputs are removed. Until a rollback request exists, whoever holds this code does it alone.', '回滚一次已提交的加工,要写理由:投料回库、产出撤掉。在回滚申请落地之前,持这个码的人一个人做完。', 1130),
    ('action.processing_aftercare', 'action', 'Record run losses and shift handovers', '记录加工损耗与交接班', 'Record the loss categories of a processing run, and submit or acknowledge a shift handover. Processing cost entries stay with Processing (edit).', '记录一次加工的损耗分类,以及提交、确认交接班。加工费用条目仍归「加工(编辑)」。', 1140);
