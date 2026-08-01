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

-- 起点授权。每条都附一句理由 —— 这份种子要读起来像论证,而不是断言。

-- admin:全部 —— 定义上如此,不然它就不是管理员
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p WHERE r.code = 'admin';

-- finance:所有模块 + 看价格成本 —— 财务要对账就得穿透到每个模块的数字
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'finance' AND (p.category = 'module' OR p.code = 'data.view_prices');

-- operations:物料流转的各模块,【但不给 data.view_prices】——
-- 调度与加工不需要知道这批料多少钱,少一个人看得见成本就少一处泄露
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'operations' AND p.code IN (
    'module.suppliers','module.materials','module.purchasing','module.inbound',
    'module.output','module.processing','module.inventory','module.stocktakes');

-- warehouse:只有现场真正会碰的四个模块,不给任何数据类权限 ——
-- 过磅收货的人不需要看见价格,也不需要看见别人的身份信息
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'warehouse' AND p.code IN (
    'module.inbound','module.output','module.inventory','module.stocktakes');

-- hr:人力资源模块 + 薪酬 + 身份信息 —— 这两类数据正是 HR 的工作对象,
-- 也正是别人不该看见的东西
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'hr' AND p.code IN ('module.hr','data.view_pay','data.view_identity');

-- auditor:所有模块 + 看价格成本 —— 审计看不见成本就没法审;
-- 【只读由执行切次实现】(策略只放行 SELECT),不靠少给权限来假装只读
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'auditor' AND (p.category = 'module' OR p.code = 'data.view_prices');

-- employee:【一个模块权限都不给】—— 员工自助不是"给他半个模块",而是"只看得见
-- 与本人相关的行",要靠 current_user_employee() 做行级限定,到执行切次单独处理。
-- 给模块权限反而会把整张表打开。
