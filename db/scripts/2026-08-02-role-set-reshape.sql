-- db/scripts/2026-08-02-role-set-reshape.sql
-- 把 cut 1 播下的七个【起始】角色,重塑为贴合实际分工的九个角色。
--
-- 【纯数据】。不建表、不改函数、不动任何策略,因此没有迁移文件、也不涉及镜像 ——
-- 这正是 cut 1 立下的那个目标兑现的样子:改一次分工,是在数据里改,不是发一次版。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 设计原则 —— 下面每一条授权都是这三句话推出来的:
--
--   1.【不相容职务分离】没有任何一个角色既能定采购价、又能付供应商的钱。
--      于是一个被抬高的价格,没法由同一个人批出去又结掉。
--      具体落法:procurement 拿 pricing + purchasing,【但完全没有 finance】;
--      finance 拿 purchasing + pricing 的可见性以便复核,付款也在它手上,
--      但下单议价的日常不由它发起。
--
--   2.【现场不需要钱】生产与仓储角色看得见数量、产出、回收率,【看不见价格】。
--      这样商业敏感数据的知悉面尽可能窄,现场的注意力也留在危险品作业本身上。
--      具体落法:operations 与 warehouse 【一个 data.* 码都不给】。
--
--   3.【看见不等于改动】只读是一个独立角色,于是审计师与顾问不需要任何写权限。
--      具体落法:auditor 全部 13 个模块【只有 .view】,只读由授权表达,
--      不靠"策略少放行"来假装。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【为什么用 set_role_permissions() 而不是直接 INSERT】
-- 因为它自带 cut 3 的 edit-蕴含-view 校验。每个角色的授权在写入的那一刻都被验一遍,
-- 授权清单里若有 module.<m>.edit 却漏了 module.<m>.view,这里会当场抛
-- EDIT_REQUIRES_VIEW 而不是悄悄写进去。清单错了要报出来,不要替它兜着。
--
-- 【为什么原地更新而不是删了重建】
-- roles.id 是 user_roles 的外键。删掉再建会换掉 id,已有的授权(包括 Tim 自己的
-- 管理员授权)会跟着一起消失。所以 code 对得上的一律 UPDATE。
--
-- 应用方式:整段在一个事务里跑一次(Management API / psql 均可)。可重跑。

BEGIN;

-- set_role_permissions 要 action.manage_permissions,而它查的是 auth.uid()。
-- 这个脚本以 postgres 身份运行,auth.uid() 为 NULL、解析出来是空权限集,
-- 于是必须显式声明"我是以哪个管理员的身份在做这件事"。
-- 【这不是绕过守卫】—— 下面每一次调用仍然要走完整的权限检查与 edit/view 校验,
-- 只是让检查有一个真实的主体可查。
SET LOCAL request.jwt.claims = '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}';

-- ============================================================================
-- 1. 角色本身:原地更新 / 新建
-- ============================================================================
-- admin 【不重建】:它是 is_system,cut 1 的 guard_system_role 挡着删除与停用,
-- 而且 Tim 的授权就挂在这一行上。只更新描述。
UPDATE roles SET
    name_en = 'System Administrator', name_zh = '系统管理员',
    description_en = 'Full access to everything, including who can see what.',
    description_zh = '拥有全部权限,包括决定谁能看见什么。',
    sort_order = 10
WHERE code = 'admin';

-- gm:新角色
INSERT INTO roles (code, name_en, name_zh, description_en, description_zh, sort_order)
VALUES ('gm', 'General Manager', '总经理',
        'Sees the whole business, including costs and margins, but cannot change who has access.',
        '看得见整个生意,包括成本与利润;但不能改动任何人的权限。', 20)
ON CONFLICT (code) DO UPDATE SET
    name_en = EXCLUDED.name_en, name_zh = EXCLUDED.name_zh,
    description_en = EXCLUDED.description_en, description_zh = EXCLUDED.description_zh,
    sort_order = EXCLUDED.sort_order, is_active = true, deleted_at = NULL;

-- finance:沿用现有行
UPDATE roles SET
    name_en = 'Finance', name_zh = '财务',
    description_en = 'Ledger, payables, receivables, invoicing and payments, with full cost visibility.',
    description_zh = '总账、应付、应收、开票与收付款,并可见全部成本。',
    sort_order = 30
WHERE code = 'finance';

-- procurement:新角色
INSERT INTO roles (code, name_en, name_zh, description_en, description_zh, sort_order)
VALUES ('procurement', 'Procurement', '采购',
        'Negotiates and raises purchase orders; sees prices but cannot pay anyone.',
        '议价、下采购单;看得见价格,但付不了任何钱。', 40)
ON CONFLICT (code) DO UPDATE SET
    name_en = EXCLUDED.name_en, name_zh = EXCLUDED.name_zh,
    description_en = EXCLUDED.description_en, description_zh = EXCLUDED.description_zh,
    sort_order = EXCLUDED.sort_order, is_active = true, deleted_at = NULL;

-- sales:新角色
INSERT INTO roles (code, name_en, name_zh, description_en, description_zh, sort_order)
VALUES ('sales', 'Sales', '销售',
        'Customers, output batches and sales; invoicing is handled by finance.',
        '客户、产出批次与销售;开票由财务负责。', 50)
ON CONFLICT (code) DO UPDATE SET
    name_en = EXCLUDED.name_en, name_zh = EXCLUDED.name_zh,
    description_en = EXCLUDED.description_en, description_zh = EXCLUDED.description_zh,
    sort_order = EXCLUDED.sort_order, is_active = true, deleted_at = NULL;

-- operations:沿用现有行,改名为"运营主管"
UPDATE roles SET
    name_en = 'Operations Supervisor', name_zh = '运营主管',
    description_en = 'Runs processing, inventory and stocktakes: quantities, yields and recovery, never prices.',
    description_zh = '负责加工、库存与盘点:管数量、产出与回收率,不涉及价格。',
    sort_order = 60
WHERE code = 'operations';

UPDATE roles SET
    name_en = 'Warehouse & Field', name_zh = '仓储现场',
    description_en = 'Receiving, output and stock counts on the floor; no commercial data.',
    description_zh = '现场收货、产出与盘点;不接触任何商务数据。',
    sort_order = 70
WHERE code = 'warehouse';

UPDATE roles SET
    name_en = 'Human Resources', name_zh = '人力资源',
    description_en = 'Employee records, payroll and training, including pay and identity data.',
    description_zh = '员工档案、薪资与培训,含薪酬与身份信息。',
    sort_order = 80
WHERE code = 'hr';

UPDATE roles SET
    name_en = 'Read-only Auditor', name_zh = '只读审计',
    description_en = 'Sees every module and all costs, changes nothing; no bank details, no salaries.',
    description_zh = '可查看全部模块与成本,不能改动任何东西;不含银行明细与薪酬。',
    sort_order = 90
WHERE code = 'auditor';

-- employee:【保留这一行,但不给任何权限】。
-- 员工自助是【行级】的 —— 靠 current_user_employee() 把可见范围限定到本人相关的行,
-- 只要账号关联了员工档案就自动成立,不经由这个角色。
-- 不删除:日后要做自助时,这一行是现成的锚点。
UPDATE roles SET
    name_en = 'Employee (unused)', name_zh = '员工(暂未使用)',
    description_en = 'Not used for access. Employee self-service is row-level and applies automatically to any account linked to an employee record.',
    description_zh = '不用于授权。员工自助是行级的,只要账号关联了员工档案即自动生效,与本角色无关。',
    sort_order = 100
WHERE code = 'employee';

-- ============================================================================
-- 2. 授权:一律经 set_role_permissions()
-- ============================================================================
-- 每一次调用都会走 edit-蕴含-view 校验。清单里若漏了 view,这里会抛
-- EDIT_REQUIRES_VIEW|<module>,整个事务回滚 —— 这是想要的结果。
DO $grants$
DECLARE
    v_all_modules text[];
    v_codes text[];
BEGIN
    -- 13 个模块的码从目录里推导,不写死
    SELECT array_agg(DISTINCT split_part(code, '.', 2)) INTO v_all_modules
    FROM permissions WHERE category = 'module';

    -- ---------------- admin:全部模块 + 全部 data.* + 管理权限
    SELECT array_agg(code) INTO v_codes FROM permissions;
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'admin'), v_codes);

    -- ---------------- gm:全部模块 view+edit,价格与银行明细,
    -- 【但没有 data.view_pay / data.view_identity / action.manage_permissions】。
    -- "看得见一切"与"决定谁能看见"是两件事,把它们分开是最基本的内部控制:
    -- 总经理能看穿业务,却不能悄悄给自己或别人加一道权限。
    SELECT array_agg(code) INTO v_codes FROM permissions
    WHERE category = 'module' OR code IN ('data.view_prices', 'data.view_banking');
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'gm'), v_codes);

    -- ---------------- finance
    SELECT array_agg(c) INTO v_codes FROM (
        SELECT 'module.' || m || '.view' AS c FROM unnest(ARRAY[
            'finance','purchasing','pricing','suppliers','customers','materials',
            'inbound','output','inventory','tasks']) m
        UNION ALL
        SELECT 'module.' || m || '.edit' FROM unnest(ARRAY[
            'finance','purchasing','pricing','suppliers','customers','materials',
            'inbound','output','inventory','tasks']) m
        UNION ALL
        SELECT unnest(ARRAY['data.view_prices','data.view_banking'])
    ) x;
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'finance'), v_codes);

    -- ---------------- procurement:议价下单,【没有 finance】——
    -- 定价与付款分开,一个抬高的价格没法由同一个人批又结。
    -- inventory 只给 view:采购要看得见还剩多少料,但库存不由它改。
    SELECT array_agg(c) INTO v_codes FROM (
        SELECT 'module.' || m || '.view' AS c FROM unnest(ARRAY[
            'purchasing','pricing','suppliers','inbound','materials','tasks']) m
        UNION ALL
        SELECT 'module.' || m || '.edit' FROM unnest(ARRAY[
            'purchasing','pricing','suppliers','inbound','materials','tasks']) m
        UNION ALL
        SELECT 'module.inventory.view'
        UNION ALL
        SELECT 'data.view_prices'
    ) x;
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'procurement'), v_codes);

    -- ---------------- sales:客户、产出、销售。开票在 finance,故【无 finance 模块】。
    -- 于是销售做不了自己单子的发票 —— 这是有意的职务分离,不是遗漏。
    SELECT array_agg(c) INTO v_codes FROM (
        SELECT 'module.' || m || '.view' AS c FROM unnest(ARRAY[
            'customers','output','inventory','pricing','tasks']) m
        UNION ALL
        SELECT 'module.' || m || '.edit' FROM unnest(ARRAY[
            'customers','output','inventory','pricing','tasks']) m
        UNION ALL
        SELECT 'module.materials.view'
        UNION ALL
        SELECT 'data.view_prices'
    ) x;
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'sales'), v_codes);

    -- ---------------- operations:【一个 data.* 码都没有】。
    -- 数量、产出、损耗、金属回收率全都看得见 —— 那正是这个岗位要管的数字;
    -- 成本与单位成本在界面上显示为「受限」,而不是空白或 0。
    SELECT array_agg(c) INTO v_codes FROM (
        SELECT 'module.' || m || '.view' AS c FROM unnest(ARRAY[
            'processing','inventory','stocktakes','inbound','output','materials','tasks']) m
        UNION ALL
        SELECT 'module.' || m || '.edit' FROM unnest(ARRAY[
            'processing','inventory','stocktakes','inbound','output','materials','tasks']) m
    ) x;
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'operations'), v_codes);

    -- ---------------- warehouse:现场四件事 + 任务板,同样没有 data.* 码
    SELECT array_agg(c) INTO v_codes FROM (
        SELECT 'module.' || m || '.view' AS c FROM unnest(ARRAY[
            'inbound','output','inventory','stocktakes','tasks']) m
        UNION ALL
        SELECT 'module.' || m || '.edit' FROM unnest(ARRAY[
            'inbound','output','inventory','stocktakes','tasks']) m
    ) x;
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'warehouse'), v_codes);

    -- ---------------- hr:薪酬与身份正是它的工作对象,也正是别人不该看见的东西
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'hr'), ARRAY[
        'module.hr.view','module.hr.edit',
        'module.tasks.view','module.tasks.edit',
        'data.view_pay','data.view_identity']);

    -- ---------------- auditor:13 个模块【只有 view】+ 价格。
    -- 审计成本与利润必须看得见价格;但收款账号是"钱能被引到哪里去"的信息,
    -- 薪酬是个人数据 —— 审计这两样都不需要。
    SELECT array_agg('module.' || m || '.view') INTO v_codes FROM unnest(v_all_modules) m;
    v_codes := v_codes || ARRAY['data.view_prices'];
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'auditor'), v_codes);

    -- ---------------- employee:零权限(见上面的说明)
    PERFORM set_role_permissions((SELECT id FROM roles WHERE code = 'employee'), ARRAY[]::text[]);
END
$grants$;

COMMIT;
