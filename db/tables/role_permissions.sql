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
-- ★ NOROLE-SURFACE(2026-10-19,Step 0 Q1–Q5,Tim):读不再是 USING (true) —— 一个没有角色的会话一行都读不到;谓词 = 今天读它的那几页的码之并(没有一个角色丢掉一条路)。
--   ★ Tim 2026-10-19(NOROLE-SURFACE 施工中的 Q21):审计记录也是读者 —— trail_row_visible 对每一行重判它自己这张表的读策略,
--     于是员工页的审计记录(module.hr.view,AUDIT-TRAIL Q21/Q24 的账号镜像)与 /settings/change-history(data.view_change_log)
--     要的码一并写进谓词;否则角色授予那几行对它们一律变成「受限」。
CREATE POLICY "role_permissions select by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['action.manage_permissions'::text, 'data.view_change_log'::text])));

CREATE POLICY "role_permissions insert by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK ((SELECT has_permission('action.manage_permissions'::text)));

CREATE POLICY "role_permissions update by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING ((SELECT has_permission('action.manage_permissions'::text))) WITH CHECK ((SELECT has_permission('action.manage_permissions'::text)));

CREATE POLICY "role_permissions delete by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR DELETE TO authenticated
    USING ((SELECT has_permission('action.manage_permissions'::text)));

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

-- ★★ MES-5b-1(2026-10-08,MES-5b Step 0 Q31,Tim):【引导的 admin 持每一个码】—— 与常设裁定一致(docs/role-matrix.md §13:
--   `admin` 角色持每一个码、拿到每一个新码,Tim 2026-09-24)。此前这里是一份五个码的"只做系统管理"起点(ROLE-1 Q8 的引导版),
--   而 Q8 在线上早已被 Tim 本人撤回(2026-09-23 23:33:27,45 个码还给 admin)—— 引导与线上从那天起就不是同一个设计;
--   MES-5b Step 0 §1.5 量到它的直接后果:引导的 admin 持 action.manage_devices 与 action.confirm_capture 而不持 module.processing.view,
--   一份全新安装会在第一天就违反"动作码与它那一页的查看码一起授"。所以现在是【目录里的每一个码】(SELECT 自 permissions,
--   以后每一个新码自动在内 —— 不必再有人记得把它补进这一行),
--   ~~★ 唯一例外,照常设裁定的原文:`module.tasks.view_all`(读【别人的私人任务】)admin 从来没有 —— 那条裁定说的是「保留 + 每一个新码」,
--   而它不在 Tim 2026-09-23 还回去的 45 个码里;要不要加是 Tim 的一句话(docs/role-matrix.md §13)。线上 admin 今天持 74 / 75,本行与它逐码相同。~~
--   ★★ MES-5b-3(2026-10-09,Tim 的裁定,关掉 MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED):【admin 也持 module.tasks.view_all】—— admin 持目录里的
--   每一个码,没有例外。同一支迁移给线上的 admin 角色补了那一行(那是本刀唯一的一处授权改动);引导与线上从此逐码相同:75 / 75。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.code = 'admin';

-- ★★ GOLIVE-1 第 5 行(Tim 2026-10-20 d2 #27 · 2026-10-29 Q2–Q5):下面每一个角色的码【逐字取自线上】(2026-10-29,以 postgres 读基表
--   role_permissions)—— 七个真角色 = db/seeds/seven-roles-2026-10-29.sql;auditor 按 Q2;operations 与 floor_display 照线上;employee 0 个。
--   此前这里是一份"全新安装的起点"设计(九角色分工 + 各刀追加),而线上早已按 Tim 的矩阵(ROLE-1 及以后)走开:
--   没有 cfo / cco / cto、finance 少码、还留着无人持有的 hr / procurement / sales。Tim Q5:引导 = 线上。
--   每一个角色【为什么】是这些码,写在它们各自落地的那一刀里(docs/role-matrix.md、db/migrations/、上面 admin 那一段的历史)——
--   这一段只负责一件事:全新重建出来的,与线上一模一样。db/fixtures/298 与 db/live-fixtures/298 两头钉住它。
--   auditor(Q2):只读 —— 18 个模块查看码,外加被删记录、价格(销售与采购两侧)、销售、自批报表、销毁证书、变更历史;
--     【不给】银行明细、薪酬、身份信息、健康数据与绩效正文(绩效是一个人对另一个人的评价,不是可审计的账)。
--   employee(Q3):一个码都不给 —— 它打得开的只有每一个账号都有的个人页;员工自助是行级的(current_user_employee())。
--   operations(Q4):线上停用、0 个持有人,照旧;floor_display 只持 data.view_floor_board(多一个码,空闲豁免就没了,MES-8b-2)。

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_banking',
        'data.view_cod',
        'data.view_prices',
        'data.view_purchase_prices',
        'data.view_reviews',
        'data.view_sales',
        'data.view_self_approvals',
        'module.compliance.view',
        'module.customers.view',
        'module.finance.view',
        'module.hr.view',
        'module.inbound.view',
        'module.inventory.view',
        'module.logistics.view',
        'module.materials.view',
        'module.output.view',
        'module.pricing.view',
        'module.processing.view',
        'module.purchasing.view',
        'module.safety.view',
        'module.sales.view',
        'module.stocktakes.view',
        'module.suppliers.view',
        'module.tasks.view'
) WHERE r.code = 'gm';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'action.contract_terms',
        'action.decide_hr_requests',
        'action.direct_sale',
        'action.hr_reviews',
        'action.issue_coa',
        'action.manage_portal_users',
        'action.ncr_decide',
        'action.raise_po_equipment',
        'action.request_shipping_release',
        'action.supplier_review',
        'data.view_banking',
        'data.view_cod',
        'data.view_deleted',
        'data.view_health',
        'data.view_pay',
        'data.view_prices',
        'data.view_purchase_prices',
        'data.view_reviews',
        'data.view_sales',
        'module.compliance.view',
        'module.customers.edit',
        'module.customers.view',
        'module.finance.view',
        'module.hr.edit',
        'module.hr.view',
        'module.inbound.edit',
        'module.inbound.view',
        'module.inventory.edit',
        'module.inventory.view',
        'module.logistics.view',
        'module.materials.edit',
        'module.materials.view',
        'module.output.edit',
        'module.output.view',
        'module.pricing.edit',
        'module.pricing.view',
        'module.processing.edit',
        'module.processing.view',
        'module.purchasing.edit',
        'module.purchasing.view',
        'module.quality.edit',
        'module.quality.view',
        'module.safety.view',
        'module.sales.edit',
        'module.sales.view',
        'module.stocktakes.edit',
        'module.stocktakes.view',
        'module.suppliers.edit',
        'module.suppliers.view',
        'module.tasks.edit',
        'module.tasks.view'
) WHERE r.code = 'cco';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'action.approve_review',
        'action.customer_credit',
        'action.decide_hr_requests',
        'action.finance_reopen',
        'action.finance_settings',
        'action.supplier_approve',
        'data.view_banking',
        'data.view_change_log',
        'data.view_cod',
        'data.view_deleted',
        'data.view_floor_board',
        'data.view_health',
        'data.view_identity',
        'data.view_pay',
        'data.view_prices',
        'data.view_purchase_prices',
        'data.view_reviews',
        'data.view_sales',
        'data.view_self_approvals',
        'module.compliance.view',
        'module.customers.view',
        'module.finance.view',
        'module.hr.view',
        'module.inbound.view',
        'module.inventory.view',
        'module.logistics.view',
        'module.materials.view',
        'module.output.view',
        'module.pricing.view',
        'module.processing.view',
        'module.purchasing.view',
        'module.quality.view',
        'module.safety.view',
        'module.sales.view',
        'module.stocktakes.view',
        'module.suppliers.view',
        'module.tasks.view'
) WHERE r.code = 'cfo';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'action.decide_hr_requests',
        'action.metal_prices',
        'action.overtime_enter',
        'action.price_receipts',
        'action.raise_po_office',
        'action.stocktake_post',
        'action.wo_release',
        'data.view_banking',
        'data.view_cod',
        'data.view_deleted',
        'data.view_health',
        'data.view_identity',
        'data.view_pay',
        'data.view_prices',
        'data.view_purchase_prices',
        'data.view_sales',
        'module.customers.edit',
        'module.customers.view',
        'module.finance.edit',
        'module.finance.view',
        'module.hr.edit',
        'module.hr.view',
        'module.inbound.edit',
        'module.inbound.view',
        'module.inventory.edit',
        'module.inventory.view',
        'module.logistics.view',
        'module.materials.edit',
        'module.materials.view',
        'module.output.edit',
        'module.output.view',
        'module.pricing.view',
        'module.processing.view',
        'module.purchasing.edit',
        'module.purchasing.view',
        'module.quality.view',
        'module.safety.view',
        'module.sales.view',
        'module.stocktakes.edit',
        'module.stocktakes.view',
        'module.suppliers.edit',
        'module.suppliers.view',
        'module.tasks.edit',
        'module.tasks.view'
) WHERE r.code = 'finance';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'action.apply_assay',
        'action.compliance_pack',
        'action.confirm_capture',
        'action.manage_devices',
        'action.ncr_decide',
        'data.view_banking',
        'data.view_cod',
        'data.view_deleted',
        'data.view_prices',
        'data.view_purchase_prices',
        'data.view_reviews',
        'data.view_sales',
        'module.compliance.view',
        'module.customers.edit',
        'module.customers.view',
        'module.finance.view',
        'module.hr.view',
        'module.inbound.edit',
        'module.inbound.view',
        'module.inventory.edit',
        'module.inventory.view',
        'module.logistics.view',
        'module.materials.edit',
        'module.materials.view',
        'module.output.edit',
        'module.output.view',
        'module.pricing.view',
        'module.processing.edit',
        'module.processing.view',
        'module.purchasing.edit',
        'module.purchasing.view',
        'module.quality.edit',
        'module.quality.view',
        'module.safety.edit',
        'module.safety.view',
        'module.sales.view',
        'module.stocktakes.edit',
        'module.stocktakes.view',
        'module.suppliers.edit',
        'module.suppliers.view',
        'module.tasks.edit',
        'module.tasks.view'
) WHERE r.code = 'cto';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'action.batch_write_off',
        'action.confirm_capture',
        'action.issue_cod',
        'action.overtime_approve',
        'action.processing_aftercare',
        'action.processing_commit',
        'action.processing_rollback',
        'action.raise_po_consumables',
        'action.receive_goods',
        'action.ship_goods',
        'action.stocktake_count',
        'action.wo_create',
        'data.view_cod',
        'data.view_purchase_prices',
        'module.inbound.edit',
        'module.inbound.view',
        'module.inventory.edit',
        'module.inventory.view',
        'module.logistics.view',
        'module.output.edit',
        'module.output.view',
        'module.processing.view',
        'module.purchasing.view',
        'module.quality.view',
        'module.safety.edit',
        'module.safety.view',
        'module.stocktakes.edit',
        'module.stocktakes.view',
        'module.suppliers.edit',
        'module.suppliers.view',
        'module.tasks.edit',
        'module.tasks.view'
) WHERE r.code = 'warehouse';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'data.view_change_log',
        'data.view_cod',
        'data.view_deleted',
        'data.view_prices',
        'data.view_purchase_prices',
        'data.view_sales',
        'data.view_self_approvals',
        'module.compliance.view',
        'module.customers.view',
        'module.finance.view',
        'module.hr.view',
        'module.inbound.view',
        'module.inventory.view',
        'module.logistics.view',
        'module.materials.view',
        'module.output.view',
        'module.pricing.view',
        'module.processing.view',
        'module.purchasing.view',
        'module.quality.view',
        'module.safety.view',
        'module.sales.view',
        'module.stocktakes.view',
        'module.suppliers.view',
        'module.tasks.view'
) WHERE r.code = 'auditor';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN (
        'module.inbound.edit',
        'module.inbound.view',
        'module.inventory.edit',
        'module.inventory.view',
        'module.logistics.view',
        'module.materials.edit',
        'module.materials.view',
        'module.output.edit',
        'module.output.view',
        'module.processing.edit',
        'module.processing.view',
        'module.safety.view',
        'module.stocktakes.edit',
        'module.stocktakes.view',
        'module.tasks.edit',
        'module.tasks.view'
) WHERE r.code = 'operations';

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_floor_board' FROM roles r WHERE r.code = 'floor_display';

-- employee:【一个码都不给】(GOLIVE-1 Q3)。

-- 引导默认值的自检:edit 必须伴随同模块的 view;动作码必须伴随用它那一页的查看码之一(MES-5b-1)。
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
    -- MES-5b-1(Step 0 Q30):动作码必须伴随用它那一页的查看码之一(permissions.requires_view_any —— set_role_permissions 那一道的同一条规矩)。
    SELECT string_agg(r.code || ' -> ' || rp.permission_code, ', ' ORDER BY r.code, rp.permission_code)
    INTO v_bad
    FROM role_permissions rp
    JOIN roles r ON r.id = rp.role_id
    JOIN permissions p ON p.code = rp.permission_code
    WHERE p.requires_view_any IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM role_permissions v
                      WHERE v.role_id = rp.role_id
                        AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'BOOTSTRAP_ACTION_REQUIRES_VIEW|%', v_bad;
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
