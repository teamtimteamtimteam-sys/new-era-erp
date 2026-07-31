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
CREATE POLICY "authenticated full access on roles"
    ON public.roles AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- 【七个角色是起点,不是定论】。首建需要一份可用的起点,但它们完全是可编辑的数据。
INSERT INTO public.roles (code, name_en, name_zh, description_en, description_zh, is_system, sort_order) VALUES
    ('admin',      'System Administrator', '系统管理员', 'Full access to everything',                  '拥有全部权限',               true,  10),
    ('finance',    'Finance',              '财务',       'Ledger, payables, receivables and costs',    '总账、应收应付与成本',       false, 20),
    ('operations', 'Operations',           '运营',       'Material flow without cost visibility',      '物料流转,不含成本可见性',   false, 30),
    ('warehouse',  'Warehouse & Field',    '仓储现场',   'Receiving, output, stock counts',            '收货、产出与盘点',           false, 40),
    ('hr',         'Human Resources',      '人力资源',   'Employee records, payroll and training',     '员工档案、薪资与培训',       false, 50),
    ('auditor',    'Read-only Auditor',    '只读审计',   'Sees everything, changes nothing',           '可查看一切,不能改动',       false, 60),
    ('employee',   'Employee Self-service','员工自助',   'Own records only',                           '仅限本人相关记录',           false, 70);
