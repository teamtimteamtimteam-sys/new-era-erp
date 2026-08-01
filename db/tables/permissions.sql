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

-- 目录种子:没有这些行,权限系统无从谈起,故属于首建脚本的一部分。
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('module.suppliers',  'module', 'Suppliers',   '供应商',   'Supplier master data',                  '供应商主数据',           10),
    ('module.customers',  'module', 'Customers',   '客户',     'Customer master data',                  '客户主数据',             20),
    ('module.materials',  'module', 'Materials',   '物料',     'Material dictionary',                   '物料字典',               30),
    ('module.pricing',    'module', 'Pricing',     '定价',     'Pricing formulas, calculator, metal prices', '定价公式、计价器与金属行情', 40),
    ('module.purchasing', 'module', 'Purchasing',  '采购',     'Purchase orders and payment schedules', '采购单与付款计划',       50),
    ('module.inbound',    'module', 'Inbound',     '进料',     'Inbound batches and receiving',         '进料批次与收货',         60),
    ('module.output',     'module', 'Output',      '产出',     'Output batches and sales',              '产出批次与销售',         70),
    ('module.processing', 'module', 'Processing',  '加工',     'Processing runs and traceability',      '加工单与追溯',           80),
    ('module.inventory',  'module', 'Inventory',   '库存',     'Inventory and material balance',        '库存与物料平衡',         90),
    ('module.stocktakes', 'module', 'Stocktakes',  '盘点',     'Physical counts and adjustments',       '实物盘点与调整',        100),
    ('module.finance',    'module', 'Finance',     '财务',     'Ledger, receivables, payables, payments','总账、应收、应付与收付款', 110),
    ('module.hr',         'module', 'HR',          '人力资源', 'Employees, payroll and training',       '员工、薪资与培训',      120),
    ('module.tasks',      'module', 'Tasks',       '任务',     'Task board',                            '任务板',                130),
    ('data.view_prices',  'data',   'View prices & costs', '查看价格与成本',
        'Unit prices, pricing formulas, costs and margins',   '单价、计价公式、成本与利润',            200),
    ('data.view_pay',     'data',   'View pay',            '查看薪酬',
        'Salary, CPF and payroll figures',                    '工资、公积金与薪资明细',                210),
    ('data.view_identity','data',   'View identity data',  '查看身份信息',
        'Identity numbers and work pass numbers',             '身份证件号与工作准证号',                220);

-- HR-3b 追加。目录扩充天然是"迁移级"的动作(见文件头),所以后续切次加的码
-- 也要落回这份首建种子里,否则从镜像重建出来的库会缺行,role_permissions 的外键
-- 直接挂掉。
-- ⚠️ 已知缺口:data.view_banking(perm3)与 data.view_sales(perm3b)两条【尚未】
--    补回本文件 —— check_mirrors 不比对数据,所以它一直是绿的。见 HR-3b 的报告。
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_reviews', 'data', 'View performance review content', '查看绩效评估正文',
        'Ratings, written conclusions, self-assessments and goal results in performance reviews',
        '绩效评估中的评级、书面结论、自评与目标结果', 250);
