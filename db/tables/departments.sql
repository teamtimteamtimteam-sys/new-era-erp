-- db/tables/departments.sql
-- 部门:浅层级组织架构(部门 → 下属组),parent_department_id 自引用。
-- 环路由 guard_department_cycle 触发器挡住(自己不能是自己的任意层上级);
-- 上溯循环带步数上限,万一历史数据已成环也不会把触发器挂死。
--
-- 【不预置任何部门】—— 替 Tim 编一份组织架构就是猜。
-- 权限切次会消费这张表(按部门授权),故 code 保持稳定、可读。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.departments (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                 text NOT NULL UNIQUE,
    name_en              text NOT NULL,
    name_zh              text NOT NULL,
    parent_department_id uuid REFERENCES public.departments (id),
    is_active            boolean NOT NULL DEFAULT true,
    notes                text,
    deleted_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid DEFAULT auth.uid(),
    -- HR-3a 追加(ALTER 加的列排在末尾)。open_review_cycle 用它默认年度评估的评估人;
    -- 可空 —— 新建部门时未必已经定下经理,未设时评估人留空由 HR 手工指派。
    -- 【外键不写在这里】departments 与 employees 互相引用,镜像重放要能拓扑排序,
    -- 所以那条 FK 由后建的 employees.sql 末尾补上(见该文件)。
    manager_employee_id  uuid
);

CREATE INDEX idx_departments_parent ON public.departments (parent_department_id);
CREATE INDEX idx_departments_manager ON public.departments (manager_employee_id);

CREATE TRIGGER trg_departments_updated_at
    BEFORE UPDATE ON public.departments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE FUNCTION public.guard_department_cycle()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_parent uuid := NEW.parent_department_id;
    v_steps  integer := 0;
BEGIN
    WHILE v_parent IS NOT NULL LOOP
        IF v_parent = NEW.id THEN
            RAISE EXCEPTION 'DEPARTMENT_CYCLE';
        END IF;
        v_steps := v_steps + 1;
        IF v_steps > 50 THEN
            RAISE EXCEPTION 'DEPARTMENT_CYCLE';
        END IF;
        SELECT parent_department_id INTO v_parent FROM departments WHERE id = v_parent;
    END LOOP;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_departments_no_cycle
    BEFORE INSERT OR UPDATE OF parent_department_id ON public.departments
    FOR EACH ROW EXECUTE FUNCTION public.guard_department_cycle();

ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "departments select by permission"
    ON public.departments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

CREATE POLICY "departments insert by permission"
    ON public.departments
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "departments update by permission"
    ON public.departments
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit'::text)) WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "departments delete by permission"
    ON public.departments
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'::text));

-- 列注释:说明写在数据库里,重建出来的库也带着它们(OPS-1 补齐)。
COMMENT ON COLUMN public.departments.manager_employee_id IS
    '部门经理。open_review_cycle 用它默认年度评估的评估人。可空 —— 未设时评估人留空,由 HR 手工指派。';
