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

-- admin:【只做系统管理】—— ★ ROLE-1(Tim 的角色与审批矩阵,2026-09-23 · Q8)。
--   此前这里写着「admin(35):全部 —— 定义上如此,不然它就不是管理员」。Tim 裁定相反:
--   系统管理员账号只管权限、账号、角色码、账号↔员工关联、审批开关与策略、批量导入、
--   员工匿名化;【一个业务码都不持】,也【不读任何业务数据】。
--   Tim 的一切业务阅读与决定走他的 CFO 账号(tim@),不走 admin@。
--   ☞ 这不是减法里顺手的一步:admin@ 持全部业务码,才让"系统管理员建单、CFO 批"
--     在四眼上被当成自批拒掉(同一个人两个账号)—— 拿掉它们,那一整类尴尬就不存在了。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'action.manage_permissions', 'action.bulk_import', 'action.anonymise_employee'
) WHERE r.code = 'admin';

-- gm:看得见整个生意,包括成本与利润;【但不操作任何东西】。
-- ★★ APR-ROUTE-1 Batch B(Tim 裁定,2026-09-23):gm 变成【只读】。
--   Tim 的 MD(Vince)持 gm,他的工作是读,不是操作。于是 gm 上【每一个】
--   会写或会做决定的码都拿掉 —— 全部 *.edit(14 个)与 action.*(线上本来就 0 个);
--   保留全部 module.*.view、data.view_* 与 data.view_self_approvals。
--   ☞ 这一条【取代】C-1(2026-09-04)Q3 那句「gm 一个字不动」—— 那一句答的是
--     "要不要给 gm【加】码",不是"要不要从 gm【拿掉】码"。
--   ☞ 2026-09-03 NAV-CLEANUP-1 记过"MD 被另行裁定为只读",而那一条此前只落在
--     一个页面上(不给 gm data.view_deleted)—— 所以线上的 gm 从来没有对上它。
--   ★ 【不要为了补偿而给 gm 加任何东西】—— cco 刻意比 gm 宽(C-1 Q2/Q3),
--     不要"修"那个不对称。
--   ⚠ 一个真实的后果,照直写:tasks 表的插入要 module.tasks.edit、没有"自己的
--     任务"那一支,所以 Vince 从此连【个人任务】都建不了。自有任务的例外登记为
--     一刀可能的后续(docs/forward-queue.md),待 Tim 定。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_banking', 'data.view_prices', 'data.view_purchase_prices', 'data.view_reviews', 'data.view_sales',
        'module.customers.view', 'module.finance.view', 'module.hr.view',
        'module.inbound.view', 'module.inventory.view', 'module.materials.view',
        'module.output.view', 'module.pricing.view', 'module.processing.view',
        'module.purchasing.view', 'module.stocktakes.view', 'module.suppliers.view',
        'module.tasks.view', 'module.sales.view', 'module.logistics.view',
        -- APR-ROUTE-1(R2 · Q4):自批报表。Tim 的 MD 是 Vince,他持 gm。
        'data.view_self_approvals') WHERE r.code = 'gm';

-- finance:总账、应付应收、开票收付款 + 全部成本可见。
-- ★ ROLE-1(Tim 的矩阵,2026-09-23):此前这里写着「【不含 HR】—— 薪酬与员工档案不是财务的工作对象」。
--   Tim 裁定相反:除 KPI 与绩效评估(归 cco)以外的全部人事与薪资工作归财务 ——
--   工资期、算薪、考勤、员工档案(月薪除外)、请假与医疗申报的决定。
--   于是加 module.hr.edit / module.hr.view / data.view_identity(身份信息从此只归财务,Q6;
--   ★ PAY-REQ-1(Tim 2026-09-23)把这句收窄了:cfo 也持 data.view_identity —— 只读,
--   Tim 裁定 cfo 持有每一个 view 码。【录入与改动】身份信息仍只归财务)/
--   data.view_pay / action.decide_hr_requests。(线上的 finance 另持 action.bulk_import,ROLE-1 在线上拿掉 —— 批量导入只归 admin;本文件里它本来就没有。)
-- ★ ROLE-1 Batch 2b(Tim,Batch 2 grilling Q13):金属行情归财务,定价公式只归 cco ——
--   module.pricing.edit 换成 action.metal_prices(行情、指数、指数交易日历、报价阈值)。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'module.hr.edit', 'module.hr.view', 'data.view_identity', 'data.view_pay',
        'action.decide_hr_requests', 'action.metal_prices',
        -- ★ ROLE-1 Batch 4a(Tim 2026-09-25,grilling Q1):收货定价与改价归财务。
        'action.price_receipts',
        -- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q4):盘点过账归财务;要读得到盘点单才过得了。
        'action.stocktake_post', 'module.stocktakes.view',
        -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling):下达工单归财务;建单人永远不能下达(按人认)。
        'action.wo_release',
        'data.view_banking', 'data.view_prices', 'data.view_purchase_prices', 'data.view_sales', 'module.customers.edit',
        'module.customers.view', 'module.finance.edit', 'module.finance.view',
        'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit',
        'module.inventory.view', 'module.materials.edit', 'module.materials.view',
        'module.output.edit', 'module.output.view',
        'module.pricing.view', 'module.purchasing.edit', 'module.purchasing.view',
        'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit',
        'module.tasks.view', 'module.logistics.view'
) WHERE r.code = 'finance';

-- procurement(14):议价、下采购单,看得见价格。【完全没有 finance】—— 定价的人不能同时把钱付出去(不相容职务分离)。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_prices', 'data.view_purchase_prices', 'module.inbound.edit', 'module.inbound.view',
        'module.inventory.view', 'module.materials.edit', 'module.materials.view',
        'module.pricing.edit', 'module.pricing.view', 'module.purchasing.edit',
        'module.purchasing.view', 'module.suppliers.edit', 'module.suppliers.view',
        'module.tasks.edit', 'module.tasks.view', 'module.logistics.view'
) WHERE r.code = 'procurement';

-- sales(13):客户、产出批次与销售。【开票归财务】,所以没有 finance。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_prices', 'data.view_purchase_prices', 'data.view_sales', 'module.customers.edit', 'module.customers.view',
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
        'module.tasks.view', 'module.logistics.view',
        -- ── COD-1:签发销毁证书 ────────────────────────────────────────────
        -- 【它没有破上面那句「不给任何数据类权限」】—— 这不是一条 data.* 权限,
        -- 而且它够得着的东西是【逐格挑出来的】:供应商的名字(随单据走的展示
        -- 标签)与这票货背后的加工事实,经 cod_certificate_data 一支函数交付。
        -- suppliers 与 company_compliance 对仓储现场【仍然是零行】——
        -- fixture 195 的 J2 / J3 两臂就是钉这一句的:名字拿得到,表读不到。
        -- 【为什么是仓储现场】过磅收货的人就是知道这票货处理完了的人;
        -- 而证书住在进料批页上,他本来就持有 module.inbound.view。
        'action.issue_cod',
        -- ── ROLE-1 Batch 2a(Tim,Batch 2a grilling Q5 · 矩阵 §6「供应商建档:cco · 仓库 · 财务」)──
        -- 仓储现场建供应商档案。★ 这一行【推翻】了上面 COD-1 那句「suppliers 对仓储现场仍然是零行」——
        -- 那句话说的是 COD-1 的时候;从这一刀起仓库读得到供应商表。证书那条路不变,
        -- 仍经 cod_certificate_data(fixture 195 的 J2 改为从复制出来的角色里拿掉这两个码,
        -- 以继续钉住"证书不需要读供应商表"这一句)。
        'module.suppliers.view', 'module.suppliers.edit',
        -- ── ROLE-1 Batch 4a(Tim 的 Q9 线,2026-09-25)──────────────────────────────
        -- ★ 这一行【推翻】了上面那句「不给任何数据类权限」:仓库看得见【采购那一侧】的价格
        -- (采购单、收货单价与改价历史、公式与条款承诺、应付账龄),好开它的采购单。
        -- 销售、发票、应收、到岸成本、存货计值、加工成本与毛利仍按 data.view_prices,仓库不拿。
        -- 看得见不等于定得了价:收货定价要 action.price_receipts(只归财务)。
        'data.view_purchase_prices',
        -- ── ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q4)──────────────────────────────
        -- 开盘点单与录数归仓库;过账归财务(action.stocktake_post),录过数的人永远不能过账。
        'action.stocktake_count',
        -- ── ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q1 · Q6–Q9;Batch 3b grilling Q2)─────────
        -- 收货建单、建工单(与改 / 取消 / 关闭)、提交加工、回滚加工、注销批次、加工损耗与交接班归仓库。
        -- 下达工单归财务(action.wo_release)。仓库读得到加工模块(module.processing.view);
        -- 物料只经 material_lookup 查名,不拿 module.materials.view(Q8)。
        'action.receive_goods', 'action.wo_create', 'action.processing_commit', 'action.processing_rollback',
        'action.batch_write_off', 'action.processing_aftercare', 'module.processing.view',
        -- ── APR-5b(Tim 2026-09-25,APR-5 grilling Q7):发货归仓库,在 CFO 放行之后 ────────────────
        -- 发货队列不带价格(shipping_queue_rows);仓库【不】拿 module.sales.view。
        'action.ship_goods'
) WHERE r.code = 'warehouse';

-- hr(7):人力资源 + 薪酬 + 身份信息 + 绩效正文。这四类正是 HR 的工作对象,也正是别人不该看见的。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_identity', 'data.view_pay', 'data.view_reviews', 'module.hr.edit',
        'module.hr.view', 'module.tasks.edit', 'module.tasks.view'
) WHERE r.code = 'hr';

-- auditor(16):全部模块【只给 .view】+ 价格 + 销售。【不给 data.view_reviews】—— 绩效是一个人对另一个人的评价,不是可审计的账;也不给薪酬与银行明细。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_prices', 'data.view_purchase_prices', 'data.view_sales', 'module.customers.view', 'module.finance.view',
        'module.hr.view', 'module.inbound.view', 'module.inventory.view',
        'module.materials.view', 'module.output.view', 'module.pricing.view',
        'module.processing.view', 'module.purchasing.view', 'module.stocktakes.view',
        'module.suppliers.view', 'module.tasks.view',
        'module.sales.view',
        'module.logistics.view',
        -- ★ NAV-CLEANUP-1 ①:被删记录。auditor 与 admin 是【仅有的】两个持有者;
        --   gm 刻意不给 —— 理由在那支迁移的抬头(一份过期文档仍把 gm 写成 MD)。
        'data.view_deleted',
        -- APR-ROUTE-1(R2 · Q4):自批报表 —— 审计性质,正是审计角色要看的那一类。
        'data.view_self_approvals') WHERE r.code = 'auditor';

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

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.role_permissions
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.manage_permissions');
