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
-- 【引导默认值 / BOOTSTRAP —— 全新安装的起点,不是线上快照】
-- 授权是数据:界面上改一次就与本文件不同了,【那是系统在正常工作,不是漂移】。
-- check_mirrors.py 【不】把本表与线上比对,本切也没有把它改成比对 —— 修的是起点。
--
-- 这份授权来自 db/scripts/2026-08-02-role-set-reshape.sql 定下的九角色分工,
-- 加上此后各切追加的数据类码(data.view_banking / view_sales / view_reviews)。
-- 【它此前一直停在 cut 1 的旧设计上】:finance 兼着 HR 与加工、operations 兼着采购,
-- 而 gm / procurement / sales 根本不存在。照镜像重建出来的库拿的就是那份旧设计。
--
-- 【每条授权都是这三句话推出来的】
--   1. 不相容职务分离:没有任何一个角色既能定采购价、又能付供应商的钱。
--   2. 看得见成本的人越少越好:现场与运营不给 data.view_prices。
--   3. 只读就写在授权里:auditor 只拿 .view,不靠"策略恰好只放行 SELECT"来假装只读。
--
-- 【edit 蕴含 view 这条不变式】set_role_permissions 会用 EDIT_REQUIRES_VIEW 挡住违反它的
-- 组合,但那是 RPC 路径;引导默认值是直接 INSERT,绕不到那道检查。所以下面在种完之后
-- 【自己验一遍】—— 一份连自己的规则都不满足的起点,比没有起点更糟。
-- ═══════════════════════════════════════════════════════════════════════════

-- admin(34):全部 —— 定义上如此,不然它就不是管理员。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'action.bulk_import', 'action.manage_permissions', 'data.view_banking', 'data.view_identity', 'data.view_pay',
        'data.view_prices', 'data.view_reviews', 'data.view_sales', 'module.customers.edit',
        'module.customers.view', 'module.finance.edit', 'module.finance.view', 'module.hr.edit',
        'module.hr.view', 'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit',
        'module.inventory.view', 'module.materials.edit', 'module.materials.view',
        'module.output.edit', 'module.output.view', 'module.pricing.edit',
        'module.pricing.view', 'module.processing.edit', 'module.processing.view',
        'module.purchasing.edit', 'module.purchasing.view', 'module.stocktakes.edit',
        'module.stocktakes.view', 'module.suppliers.edit', 'module.suppliers.view',
        'module.tasks.edit', 'module.tasks.view',
        'module.sales.edit', 'module.sales.view',
        'module.logistics.view') WHERE r.code = 'admin';

-- gm(30):看得见整个生意,包括成本与利润;【但不能改权限】—— 没有 action.manage_permissions。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_banking', 'data.view_prices', 'data.view_reviews', 'data.view_sales',
        'module.customers.edit', 'module.customers.view', 'module.finance.edit',
        'module.finance.view', 'module.hr.edit', 'module.hr.view', 'module.inbound.edit',
        'module.inbound.view', 'module.inventory.edit', 'module.inventory.view',
        'module.materials.edit', 'module.materials.view', 'module.output.edit',
        'module.output.view', 'module.pricing.edit', 'module.pricing.view',
        'module.processing.edit', 'module.processing.view', 'module.purchasing.edit',
        'module.purchasing.view', 'module.stocktakes.edit', 'module.stocktakes.view',
        'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit',
        'module.tasks.view',
        'module.sales.edit', 'module.sales.view',
        'module.logistics.view') WHERE r.code = 'gm';

-- finance(23):总账、应付应收、开票收付款 + 全部成本可见。【不含 HR】—— 薪酬与员工档案不是财务的工作对象。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_banking', 'data.view_prices', 'data.view_sales', 'module.customers.edit',
        'module.customers.view', 'module.finance.edit', 'module.finance.view',
        'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit',
        'module.inventory.view', 'module.materials.edit', 'module.materials.view',
        'module.output.edit', 'module.output.view', 'module.pricing.edit',
        'module.pricing.view', 'module.purchasing.edit', 'module.purchasing.view',
        'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit',
        'module.tasks.view', 'module.logistics.view'
) WHERE r.code = 'finance';

-- procurement(14):议价、下采购单,看得见价格。【完全没有 finance】—— 定价的人不能同时把钱付出去(不相容职务分离)。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_prices', 'module.inbound.edit', 'module.inbound.view',
        'module.inventory.view', 'module.materials.edit', 'module.materials.view',
        'module.pricing.edit', 'module.pricing.view', 'module.purchasing.edit',
        'module.purchasing.view', 'module.suppliers.edit', 'module.suppliers.view',
        'module.tasks.edit', 'module.tasks.view', 'module.logistics.view'
) WHERE r.code = 'procurement';

-- sales(13):客户、产出批次与销售。【开票归财务】,所以没有 finance。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_prices', 'data.view_sales', 'module.customers.edit', 'module.customers.view',
        'module.inventory.edit', 'module.inventory.view', 'module.materials.view',
        'module.output.edit', 'module.output.view', 'module.pricing.edit',
        'module.pricing.view', 'module.tasks.edit', 'module.tasks.view',
        'module.sales.edit', 'module.sales.view',
        'module.logistics.view') WHERE r.code = 'sales';

-- operations(14):加工、库存、盘点:管数量、产出与回收率。【不给 data.view_prices】—— 少一个人看得见成本就少一处泄露。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit',
        'module.inventory.view', 'module.materials.edit', 'module.materials.view',
        'module.output.edit', 'module.output.view', 'module.processing.edit',
        'module.processing.view', 'module.stocktakes.edit', 'module.stocktakes.view',
        'module.tasks.edit', 'module.tasks.view', 'module.logistics.view'
) WHERE r.code = 'operations';

-- warehouse(10):现场收货、产出、盘点。【不给任何数据类权限】—— 过磅的人不需要看见价格,也不需要看见别人的身份信息。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit',
        'module.inventory.view', 'module.output.edit', 'module.output.view',
        'module.stocktakes.edit', 'module.stocktakes.view', 'module.tasks.edit',
        'module.tasks.view', 'module.logistics.view'
) WHERE r.code = 'warehouse';

-- hr(7):人力资源 + 薪酬 + 身份信息 + 绩效正文。这四类正是 HR 的工作对象,也正是别人不该看见的。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_identity', 'data.view_pay', 'data.view_reviews', 'module.hr.edit',
        'module.hr.view', 'module.tasks.edit', 'module.tasks.view'
) WHERE r.code = 'hr';

-- auditor(15):全部模块【只给 .view】+ 价格 + 销售。【不给 data.view_reviews】—— 绩效是一个人对另一个人的评价,不是可审计的账;也不给薪酬与银行明细。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_prices', 'data.view_sales', 'module.customers.view', 'module.finance.view',
        'module.hr.view', 'module.inbound.view', 'module.inventory.view',
        'module.materials.view', 'module.output.view', 'module.pricing.view',
        'module.processing.view', 'module.purchasing.view', 'module.stocktakes.view',
        'module.suppliers.view', 'module.tasks.view',
        'module.sales.view',
        'module.logistics.view') WHERE r.code = 'auditor';

-- ═══════════════════════════════════════════════════════════════════════════
-- NAV-REG-1 / R2:module.logistics.view 授给了上面 8 个角色中的每一个。
-- 【本文件里【没有】cfo 这个角色,而线上有(且它有一个真实用户)】—— 这份文件
-- 自称是"全新安装的起点",不是线上的快照,而这正是那句话的证据。线上的授予由
-- db/migrations/2026-09-01-navreg1-logistics-gets-its-own-code.sql 做,那一刀授了
-- 9 个角色(这里的 8 个 + cfo),并在事务里断言了 9 这个数。
-- 【判据:今天进得去物流的人,明天也要进得去】授予名单 = 今天持
-- module.purchasing.view 的每一个角色(借来的那道门)+ Tim 点名的
-- operations / warehouse / sales。对三个角色是扩大,对任何人都不是缩小。
-- ═══════════════════════════════════════════════════════════════════════════

-- employee:【一个模块权限都不给】—— 员工自助是行级的,靠 current_user_employee()
-- 限定到本人相关的行。给模块权限反而会把整张表打开。

-- 引导默认值的自检:edit 必须伴随同模块的 view。
DO $bootstrap_check$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(r.code || ' -> ' || rp.permission_code, ', ')
    INTO v_bad
    FROM role_permissions rp
    JOIN roles r ON r.id = rp.role_id
    WHERE rp.permission_code LIKE '%.edit'
      AND NOT EXISTS (SELECT 1 FROM role_permissions v
                      WHERE v.role_id = rp.role_id
                        AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'BOOTSTRAP_EDIT_REQUIRES_VIEW|%', v_bad;
    END IF;
END;
$bootstrap_check$;
