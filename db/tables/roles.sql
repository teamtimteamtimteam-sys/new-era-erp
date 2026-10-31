-- db/tables/roles.sql
-- 角色。【这是数据,不是枚举】—— 加一个角色、改一个名字、调一次授权,都应该是
-- 界面上的 INSERT/UPDATE,不该再来一次迁移。策略里永远不出现角色名(见
-- db/functions/has_permission.sql),所以角色怎么改都不影响策略。
--
-- is_system:不可删除、不可停用、也不可被摘掉这个标记的角色 —— 只有管理员是。
-- 守卫见下面的 guard_system_role;它与 user_roles 的 guard_last_admin 一起,
-- 防的是同一个失效模式:系统里一个活着的管理员都不剩,从此没人能改权限。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm1-permission-skeleton.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 界面上可以新建 / 改名 / 停用角色(app/settings/permissions/roles + actions.ts 的 insert/update/软删),db/scripts/2026-08-02-role-set-reshape.sql 也重塑过它。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上比对。
-- 它只保证镜像这一套自己首尾相顾(本文件引用到的码/科目都存在于对应的种子里)。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.roles (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    description_en text,
    description_zh text,
    is_system      boolean NOT NULL DEFAULT false,
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0,
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_roles_updated_at
    BEFORE UPDATE ON public.roles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE FUNCTION public.guard_system_role()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.is_system THEN
            RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED|%', OLD.code;
        END IF;
        RETURN OLD;
    END IF;
    -- 停用、软删、或把 is_system 摘掉 —— 三条都是"让管理员角色失去意义",一并拒绝
    IF OLD.is_system AND (NOT NEW.is_active OR NEW.deleted_at IS NOT NULL OR NOT NEW.is_system) THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_roles_system_protected
    BEFORE UPDATE OR DELETE ON public.roles
    FOR EACH ROW EXECUTE FUNCTION public.guard_system_role();

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
-- ★ NOROLE-SURFACE(2026-10-19,Step 0 Q1–Q5,Tim):读不再是 USING (true) —— 一个没有角色的会话一行都读不到;谓词 = 今天读它的那几页的码之并(没有一个角色丢掉一条路)。
--   ★ Tim 2026-10-19(NOROLE-SURFACE 施工中的 Q21):审计记录也是读者 —— trail_row_visible 对每一行重判它自己这张表的读策略,
--     于是员工页的审计记录(module.hr.view,AUDIT-TRAIL Q21/Q24 的账号镜像)与 /settings/change-history(data.view_change_log)
--     要的码一并写进谓词;否则角色授予那几行对它们一律变成「受限」。
CREATE POLICY "roles select by permission"
    ON public.roles
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['action.manage_permissions'::text, 'data.view_change_log'::text])));

CREATE POLICY "roles insert by permission"
    ON public.roles
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK ((SELECT has_permission('action.manage_permissions'::text)));

CREATE POLICY "roles update by permission"
    ON public.roles
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING ((SELECT has_permission('action.manage_permissions'::text))) WITH CHECK ((SELECT has_permission('action.manage_permissions'::text)));

CREATE POLICY "roles delete by permission"
    ON public.roles
    AS PERMISSIVE FOR DELETE TO authenticated
    USING ((SELECT has_permission('action.manage_permissions'::text)));

-- ═══════════════════════════════════════════════════════════════════════════
-- 【引导默认值 / BOOTSTRAP —— 全新安装的起点】
-- ★★ GOLIVE-1 第 5 行(Tim 2026-10-20 d2 #27 · 2026-10-29 Q3 · Q4 · Q5)起:【全新安装建出来的角色,正是线上那 11 个】——
--   admin · gm · cco · cfo · finance · operations · cto · warehouse · auditor · employee · floor_display,
--   每一行的名字、说明、is_system、is_active、排序与线上(2026-10-29,以 postgres 读基表)逐字相同。
--   hr · procurement · sales 删掉(线上 0 个持有人,本刀的迁移同时删);cfo · cco · cto 补进来(ROLE1-BOOTSTRAP-MISSING-ROLES 关闭)。
--   ★ operations 在线上是【停用并软删】的(is_active = false,deleted_at 2026-09-10,0 个持有人),Tim Q4:照旧不动 —— 引导里同样停用、软删(见本段末)。
--   ★ employee:不持任何码,只打得开每一个账号都有的个人页(Tim Q3,说明改写);员工自助是行级的,与角色无关。
--   这一点由两支 fixture 钉住:db/fixtures/298(重建库的角色与授权 = db/seeds/eleven-roles-2026-10-31.sql)与
--   db/live-fixtures/298(线上 = 同一份),所以"重建出来的角色就是线上的角色"是一句会红的话,不是一句注释。
--   本表【仍然是运行期配置】:界面上改角色是正常的;改了,就同一个提交重取那份快照(新日期的文件)。
-- ═══════════════════════════════════════════════════════════════════════════
INSERT INTO public.roles (code, name_en, name_zh, description_en, description_zh, is_system, is_active, sort_order) VALUES
    ('admin', 'System Administrator', '系统管理员', 'Full access to everything, including who can see what.', '拥有全部权限,包括决定谁能看见什么。', true, true, 10),
    ('gm', 'General Manager', '总经理', 'Sees the whole business, including costs and margins, but cannot change who has access.', '看得见整个生意,包括成本与利润;但不能改动任何人的权限。', false, true, 20),
    ('cco', 'Commercial & People', '商务与人力', 'Customers, sales and everything about people, plus system administration: accounts, roles and permissions. Reads every other module without changing it.', '客户、销售与人的全部事务,外加系统管理:账号、角色与权限。其余每一个模块【只读】。', false, true, 22),
    ('cfo', 'CFO', '首席财务官', 'Approves purchase orders at or above the approval threshold. Deliberately cannot raise purchase orders.', '审批达到或超过门槛的采购单。**刻意不能提单** —— 提得了单又批得了同一张单的人不是一道控制。', false, true, 25),
    ('finance', 'Finance', '财务', 'Ledger, payables, receivables, invoicing and payments, with full cost visibility.', '总账、应付、应收、开票与收付款,并可见全部成本。', false, true, 30),
    ('operations', 'Operations Supervisor', '运营主管', 'Runs processing, inventory and stocktakes: quantities, yields and recovery, never prices.', '负责加工、库存与盘点:管数量、产出与回收率,不涉及价格。', false, false, 60),
    ('cto', 'CTO', '首席科技官', NULL, NULL, false, true, 60),
    ('warehouse', 'Warehouse & Field', '仓储现场', 'Receiving, output and stock counts on the floor; no commercial data.', '现场收货、产出与盘点;不接触任何商务数据。', false, true, 70),
    ('auditor', 'Read-only Auditor', '只读审计', 'Sees every module and all costs, changes nothing; no bank details, no salaries.', '可查看全部模块与成本,不能改动任何东西;不含银行明细与薪酬。', false, true, 90),
    ('employee', 'Employee (unused)', '员工(暂未使用)', 'Holds no codes. It opens only the personal pages every account gets: your own profile (/me), your reviews, the workbench, notifications, reminders, the calendar and the unit converter. Employee self-service is row-level and applies automatically to any account linked to an employee record.', '不持任何码。它只打得开每一个账号都有的个人页:本人档案(/me)、我的评估、工作台、通知、提醒、日历与单位换算。员工自助是行级的,只要账号关联了员工档案即自动生效。', false, true, 100),
    -- ★ MES-8b-2(2026-10-17,MES-0 Q83 · MES-8 Step 0 Q19 · Q29,Tim):车间大屏。【一块屏一个账号】,由 admin 经 /settings/accounts 建,只挂这一个角色;
    --   这个角色只持 data.view_floor_board。只持它(角色与码都只有这一个)的会话【不被空闲登出】,而且只打得开 /display;
    --   给这个角色加任何一个别的码、或给那个账号加任何一个别的角色,豁免当场消失(session_is_floor_display_only)。本刀不建任何账号。
    ('floor_display', 'Floor display', '车间大屏', 'A wall screen on the plant floor: one account per screen, holding only this role. It opens only the floor board (/display) — live counts from processing, safety and stock, no money, no names, no health details — and is not signed out when idle. Any other role or code on the account removes both.', '车间墙上的一块屏:一块屏一个账号,只挂这一个角色。它只打得开大屏(/display)—— 加工、安全与库存的实时计数,没有钱、没有名字、没有健康信息 —— 并且空闲时不被登出。账号上多一个角色或这个角色多一个码,两样都没有了。', false, true, 110);

-- ★ GOLIVE-1(Tim Q4:operations 照旧不动):线上的 operations 不只是停用,它在 2026-09-10 10:28:34 CST 被【软删】了(deleted_at 不空,0 个持有人)。
--   引导照线上:同一行、同一组码,软删 —— 于是重建出来的 11 行与线上 11 行逐行同状态(db/fixtures/298 · db/live-fixtures/298 比 is_active 与"删没删")。
UPDATE public.roles SET deleted_at = now() WHERE code = 'operations';

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.roles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.manage_permissions');
