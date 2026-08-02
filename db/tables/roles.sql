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
CREATE POLICY "roles select by permission"
    ON public.roles
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "roles insert by permission"
    ON public.roles
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'::text));

CREATE POLICY "roles update by permission"
    ON public.roles
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions'::text)) WITH CHECK (has_permission('action.manage_permissions'::text));

CREATE POLICY "roles delete by permission"
    ON public.roles
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'::text));

-- ═══════════════════════════════════════════════════════════════════════════
-- 【引导默认值 / BOOTSTRAP —— 全新安装的起点,不是线上快照】
-- 这九个工作角色 + 一行保留但零权限的 employee,是 db/scripts/2026-08-02-role-set-reshape.sql
-- 定下来的分工;那次重塑【只改了线上的数据】,本文件当时停在 cut 1 播下的七个角色上。
-- 于是照镜像重建出来的库,拿到的是一份【已经作废的早期设计】——
-- 没有 gm / procurement / sales,finance 还兼着 HR 与加工。
-- 本表【仍然是运行期配置】:界面上改角色是正常的,check_mirrors 照旧不逐行比对。
-- 这里修的是【起点】,不是把检查收紧。
--
-- 【为什么保留 employee 这一行】员工自助是【行级】的,靠 current_user_employee()
-- 限定到本人相关的行,与角色无关。给它任何模块权限反而会把整张表打开。
-- ═══════════════════════════════════════════════════════════════════════════
INSERT INTO public.roles (code, name_en, name_zh, description_en, description_zh, is_system, sort_order) VALUES
    ('admin', 'System Administrator', '系统管理员', 'Full access to everything, including who can see what.', '拥有全部权限,包括决定谁能看见什么。', true, 10),
    ('gm', 'General Manager', '总经理', 'Sees the whole business, including costs and margins, but cannot change who has access.', '看得见整个生意,包括成本与利润;但不能改动任何人的权限。', false, 20),
    ('finance', 'Finance', '财务', 'Ledger, payables, receivables, invoicing and payments, with full cost visibility.', '总账、应付、应收、开票与收付款,并可见全部成本。', false, 30),
    ('procurement', 'Procurement', '采购', 'Negotiates and raises purchase orders; sees prices but cannot pay anyone.', '议价、下采购单;看得见价格,但付不了任何钱。', false, 40),
    ('sales', 'Sales', '销售', 'Customers, output batches and sales; invoicing is handled by finance.', '客户、产出批次与销售;开票由财务负责。', false, 50),
    ('operations', 'Operations Supervisor', '运营主管', 'Runs processing, inventory and stocktakes: quantities, yields and recovery, never prices.', '负责加工、库存与盘点:管数量、产出与回收率,不涉及价格。', false, 60),
    ('warehouse', 'Warehouse & Field', '仓储现场', 'Receiving, output and stock counts on the floor; no commercial data.', '现场收货、产出与盘点;不接触任何商务数据。', false, 70),
    ('hr', 'Human Resources', '人力资源', 'Employee records, payroll and training, including pay and identity data.', '员工档案、薪资与培训,含薪酬与身份信息。', false, 80),
    ('auditor', 'Read-only Auditor', '只读审计', 'Sees every module and all costs, changes nothing; no bank details, no salaries.', '可查看全部模块与成本,不能改动任何东西;不含银行明细与薪酬。', false, 90),
    ('employee', 'Employee (unused)', '员工(暂未使用)', 'Not used for access. Employee self-service is row-level and applies automatically to any account linked to an employee record.', '不用于授权。员工自助是行级的,只要账号关联了员工档案即自动生效,与本角色无关。', false, 100);
