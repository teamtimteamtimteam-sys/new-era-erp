-- ════════════════════════════════════════════════════════════════════════════
-- C-1 / Step 1(2026-09-04):cco 角色 · 六个人的员工档案 · 测试数据清理
-- ════════════════════════════════════════════════════════════════════════════
-- 【这是数据脚本,不是迁移】roles / role_permissions / employees 都是运行期配置
-- 或业务数据,check_mirrors 不逐行比对它们(见 db/tables/roles.sql 的抬头)。
-- 本脚本【不碰】permissions —— 那张表是迁移专属的,db/scripts/ 永远不许写它。
--
-- 【Tim 的裁定,逐条落在下面】见 docs/accounts-roles-and-permissions.md 的问答体。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════
-- ① cco —— 本刀【唯一】新建的角色(Sandra Yap:CCO 兼人力资源负责人)
-- ══════════════════════════════════════════════════════════════════════════
-- 【为什么只新建一个】另外五个人都落在既有角色上,而那些角色本来就是照这些
--   工作对象设计的:gm(看得见整个生意但不能改权限)、admin、operations、
--   finance、warehouse。**不为"每人一个"而造角色。**
-- 【cco 不是 sales ∪ hr】Tim 把它裁得更宽:sales + hr + 【整个设置模块】编辑,
--   其余每一个模块只读。
INSERT INTO public.roles (code, name_en, name_zh, description_en, description_zh, is_system, sort_order)
VALUES ('cco', 'Commercial & People', '商务与人力',
        'Customers, sales and everything about people, plus system administration: accounts, roles and permissions. Reads every other module without changing it.',
        '客户、销售与人的全部事务,外加系统管理:账号、角色与权限。其余每一个模块【只读】。',
        false, 22);

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
    -- ── 管理:整个设置模块 ──────────────────────────────────────────────
    -- ★ action.manage_permissions 就是 /settings/roles 那扇门 —— 也就是
    --   「决定每个角色能做什么」那块屏。持有它的人可以给自己授予系统里的
    --   任何权限,也可以改动包括 admin 在内的任何角色。Tim 知情并【刻意】接受;
    --   收窄的办法(把它拆成账号码与矩阵码)是【被推迟的】,不是被忽略的。
    'action.manage_permissions',
    'action.bulk_import',
    'data.view_deleted',          -- /settings/deleted 那一格是 R,靠这个码
    -- ── 编辑:销售 ──────────────────────────────────────────────────────
    'module.sales.edit',   'module.sales.view',
    -- ── 编辑:人力资源 + 它的三个数据码 ─────────────────────────────────
    'module.hr.edit',      'module.hr.view',
    'data.view_pay', 'data.view_identity', 'data.view_reviews',
    -- ── 编辑:任务(每一个角色都有)────────────────────────────────────
    'module.tasks.edit',   'module.tasks.view',
    -- ── ⚠ 编辑:物料 + 进料 —— 【这两条是被 /settings/dictionaries 逼出来的】
    --   矩阵里 Sandra 在字典那一格是 E,而那块屏的编辑权【就是】
    --   module.materials.edit 与 module.inbound.edit(见 dictionaries/registry.ts)。
    --   Q7 裁定本刀不铸新码,所以给 E 就只能给这两个【模块级】的码 ——
    --   于是它顺带给了她【编辑物料主数据与进料批次】的能力,而那超出了"设置"。
    --   ★ 这是 Tim 两条裁定之间的一处真冲突(VIEW 里点名了 inbound,
    --     而矩阵里字典是 E),本刀按【更具体的那一条】(矩阵)执行并报告。
    'module.materials.edit', 'module.materials.view',
    'module.inbound.edit',   'module.inbound.view',
    -- ── 只读:其余每一个模块 ────────────────────────────────────────────
    'module.customers.view', 'module.finance.view', 'module.inventory.view',
    'module.logistics.view', 'module.output.view', 'module.pricing.view',
    'module.processing.view', 'module.purchasing.view', 'module.stocktakes.view',
    'module.suppliers.view',
    -- ── 商务的两个数据码 ────────────────────────────────────────────────
    'data.view_prices', 'data.view_sales'
    -- ★【刻意不给 data.view_banking】它是"开在发票上的公司银行明细"。
    --   Tim 描述 cco 会看见的是「成本与利润、薪酬、身份信息、价格」—— 不含银行。
    --   所以 cco 比 gm 宽在 view_pay / view_identity / view_deleted 三条上,
    --   而 gm 比 cco 宽在 view_banking 一条上。**两者不是包含关系。**
) WHERE r.code = 'cco';

-- 引导自检:edit 必须伴随同模块的 view(set_role_permissions 的 EDIT_REQUIRES_VIEW
-- 是 RPC 路径上的守卫,直接 INSERT 绕得过去 —— 所以这里自己验一遍)。
DO $chk$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(rp.permission_code, ', ') INTO v_bad
    FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
    WHERE r.code = 'cco' AND rp.permission_code LIKE '%.edit'
      AND NOT EXISTS (SELECT 1 FROM role_permissions v
                      WHERE v.role_id = rp.role_id
                        AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'CCO_EDIT_REQUIRES_VIEW|%', v_bad;
    END IF;
END $chk$;

-- ══════════════════════════════════════════════════════════════════════════
-- ② Q14 —— chef1949@126.com:一个不属于任何人的测试邮箱
-- ══════════════════════════════════════════════════════════════════════════
-- 【授权先删,账号后删 —— 顺序不能反】user_roles.user_id 【没有】指向 auth.users
--   的外键。先删账号就会原地留下一条【幽灵授权】,那正是 GHOST-GRANTS
--   三次复发的形状(66 → 21 → 8 条)。
DELETE FROM public.user_roles
 WHERE user_id = '02fb6530-97c7-439a-a38d-620fcc1c6829';

-- ★★【EMP-2026-0001(Choo Er Teh)【没有】被删除 —— 这是一处刻意的停手】★★
--   Tim 的裁定带着一条前置条件:「先查引用;有东西引用它就 STOP 并报告,
--   不要强删,也不要级联」。实测它【被引用】:employment_history 2 行 ·
--   payroll_lines 1 行 · task_history 4 行 · task_participants 2 行 ·
--   training_records 1 行 = 5 张表 10 行。所以这里只【解绑账号】,保留档案本身。
--   ☞ 后果:Choo Er 复用这一行(她的姓名/部门/岗位/入职日期都在上面),
--     而不是另建一行 —— 另建会得到两个"Choo Er Teh",而旧的那个还被引用着。
UPDATE public.employees SET user_id = NULL
 WHERE code = 'EMP-2026-0001';

-- ══════════════════════════════════════════════════════════════════════════
-- ③ Q15 —— 五个封禁的走查账号与它们的员工行
-- ══════════════════════════════════════════════════════════════════════════
DELETE FROM public.user_roles WHERE user_id IN (
    '4e096532-4da6-40e3-a546-a65a681cd04e',  -- walk-qt-1786805272946
    '7600ce54-7398-46c5-9290-5af4de9d2d5f',  -- l2bl-1787185137325
    '345f2a68-588f-4d7f-aca2-f71507ac9119',  -- l2bl-1787185158806
    '10d92ae6-a0fd-441e-86a5-a65233a17aeb',  -- l2bl-1787185184530
    'aeb78402-cc60-450c-8e1e-ae64e89126ff'); -- l2bl-1787185288817

-- 三行无人引用 → 删。
DELETE FROM public.employees
 WHERE code IN ('ZZ-2BL-138972', 'ZZ-2BL-160682', 'ZZ-2BL-291186');

-- ★ ZZ-2BL-186301 【留着】—— equipment_maintenance 有 1 行指着它
--   (description = 'Test',2026-08-23 建)。删它需要连带删那行维修记录,
--   而那是一次【级联】—— Tim 对 EMP-2026-0001 立的规矩是同一条:不强删、不级联。
--   这里只解绑账号,让它的 auth 账号删得掉。
UPDATE public.employees SET user_id = NULL WHERE code = 'ZZ-2BL-186301';

-- ══════════════════════════════════════════════════════════════════════════
-- ④ 四份新的员工档案(Choo Er 复用 0001,Tim 保留 0002)
-- ══════════════════════════════════════════════════════════════════════════
-- ⚠【HR 字段是占位值,不是事实】hire_date / employment_type / work_category /
--   residency_status 本刀【无从得知】,而 hire_date 会进假期累积的计算。
--   下面每一行的 notes 都把这句话写在数据里,而不只写在文档里。
--   code 由 assign_employee_code() 触发器自动分配,不手写。
INSERT INTO public.employees
    (legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, notes)
VALUES
    ('Vince Goh',        'Vince',    'full_time', 'office',    DATE '2026-09-04', 'active',
     'C-1 2026-09-04:为发放账号而建。⚠ hire_date / employment_type / work_category / residency_status 是【占位值】,不是事实 —— hire_date 会进假期累积计算,启用假期与薪资之前必须由 HR 更正。'),
    ('Sandra Yap',       'Sandra',   'full_time', 'office',    DATE '2026-09-04', 'active',
     'C-1 2026-09-04:为发放账号而建。⚠ HR 字段是占位值,见 Vince Goh 那一行的说明。'),
    ('Cheng Siong Phua', 'Phua',     'full_time', 'office',    DATE '2026-09-04', 'active',
     'C-1 2026-09-04:为发放账号而建。⚠ HR 字段是占位值,见 Vince Goh 那一行的说明。'),
    ('Fu Sheng Wong',    'Fu Sheng', 'full_time', 'shopfloor', DATE '2026-09-04', 'active',
     'C-1 2026-09-04:为发放账号而建。⚠ HR 字段是占位值 —— 尤其 work_category 取了 shopfloor(仓储现场负责人),它影响考勤与加班规则,请确认。');

-- ══════════════════════════════════════════════════════════════════════════
-- ⑤ 汇报线 —— 【只记绩效评估那一条】,第二条上级不进系统
-- ══════════════════════════════════════════════════════════════════════════
-- 实测:manager_id 在全库【只出现在 master_import_apply 一支函数里】,
-- 权限、可见性与审批路由一律与它无关(审批读的是 finance_settings 的角色码)。
-- 所以双上级在本系统里【没有表示,也不需要表示】。
UPDATE public.employees e SET manager_id = v.mgr FROM (
    SELECT (SELECT id FROM employees WHERE legal_name = 'Vince Goh') AS mgr,
           unnest(ARRAY['Tim', 'Sandra Yap', 'Cheng Siong Phua']) AS who
    UNION ALL
    SELECT (SELECT id FROM employees WHERE legal_name = 'Tim'), 'Choo Er Teh'
    UNION ALL
    SELECT (SELECT id FROM employees WHERE legal_name = 'Cheng Siong Phua'), 'Fu Sheng Wong'
) v WHERE e.legal_name = v.who AND e.deleted_at IS NULL;

COMMIT;
