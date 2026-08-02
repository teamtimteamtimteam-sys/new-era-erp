-- db/tables/role_permissions.sql
-- 角色 × 权限。【授权是数据】—— 重新分配权限就是这张表上的 INSERT/DELETE,
-- 永远不需要改代码或做迁移。
-- ON DELETE CASCADE(角色侧):删角色连带清掉它的授权;
-- ON DELETE RESTRICT(权限侧):还被引用的权限删不掉,目录不会被抽空。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm1-permission-skeleton.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.role_permissions (
    role_id         uuid NOT NULL REFERENCES public.roles (id) ON DELETE CASCADE,
    permission_code text NOT NULL REFERENCES public.permissions (code) ON DELETE RESTRICT,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    PRIMARY KEY (role_id, permission_code)
);

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "role_permissions select by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "role_permissions insert by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'::text));

CREATE POLICY "role_permissions update by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions'::text)) WITH CHECK (has_permission('action.manage_permissions'::text));

CREATE POLICY "role_permissions delete by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'::text));

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 本段是"全新安装的默认值",不是线上快照】
-- 授权是数据:界面上改一次就与本文件不同了,【那是系统在正常工作,不是漂移】。
-- check_mirrors.py 【不】把本表与线上比对。它只保证一件事:本文件引用的每一个
-- permission_code 都存在于 db/tables/permissions.sql 的种子里 —— 也就是镜像这一套
-- 自己首尾相顾。仅凭这一条,当年 data.view_banking / data.view_sales 那个 bug
-- 就会当场被抓住,而且完全不需要连线上。
--
-- 线上当前的分工见 db/scripts/2026-08-02-role-set-reshape.sql(九个工作角色 +
-- 保留但零权限的 employee 行)。那份脚本是【线上状态】的来源,本文件是【起点】的来源,
-- 两者本来就不该相等。
--
-- ⚠️ OPS-1 更新:perm2a 把 module.<m> 一分为二之后,本文件里那些未拆分的码
--    (module.finance / module.hr …)已经不存在于目录里了,照镜像重建会直接违反外键。
--    下面改用拆分后的码;auditor 只给 .view —— 拆分之前"只读"是靠策略实现的,
--    拆分之后它可以、也应该在授权里就说清楚。
-- ═══════════════════════════════════════════════════════════════════════════

-- admin:全部 —— 定义上如此,不然它就不是管理员。
-- 【CROSS JOIN 是有意的】目录加了新码,全新安装的管理员自动就有,不会漏。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p WHERE r.code = 'admin';

-- finance:所有模块的查看与编辑 + 看价格成本 —— 财务要对账就得穿透到每个模块的数字
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'finance' AND (p.category = 'module' OR p.code = 'data.view_prices');

-- operations:物料流转的各模块,【但不给 data.view_prices】——
-- 调度与加工不需要知道这批料多少钱,少一个人看得见成本就少一处泄露
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'operations' AND p.code IN (
    'module.suppliers.view','module.suppliers.edit','module.materials.view','module.materials.edit',
    'module.purchasing.view','module.purchasing.edit','module.inbound.view','module.inbound.edit',
    'module.output.view','module.output.edit','module.processing.view','module.processing.edit',
    'module.inventory.view','module.inventory.edit','module.stocktakes.view','module.stocktakes.edit');

-- warehouse:只有现场真正会碰的四个模块,不给任何数据类权限 ——
-- 过磅收货的人不需要看见价格,也不需要看见别人的身份信息
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'warehouse' AND p.code IN (
    'module.inbound.view','module.inbound.edit','module.output.view','module.output.edit',
    'module.inventory.view','module.inventory.edit','module.stocktakes.view','module.stocktakes.edit');

-- hr:人力资源模块 + 薪酬 + 身份信息 —— 这两类数据正是 HR 的工作对象,
-- 也正是别人不该看见的东西
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'hr' AND p.code IN (
    'module.hr.view','module.hr.edit','data.view_pay','data.view_identity');

-- auditor:所有模块【只给 .view】+ 看价格成本 —— 审计看不见成本就没法审。
-- 【拆分之后,只读写在授权里】而不再只靠"策略恰好只放行 SELECT"。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'auditor'
  AND ((p.category = 'module' AND p.code LIKE '%.view') OR p.code = 'data.view_prices');

-- employee:【一个模块权限都不给】—— 员工自助不是"给他半个模块",而是"只看得见
-- 与本人相关的行",靠 current_user_employee() 做行级限定。
-- 给模块权限反而会把整张表打开。
