-- db/functions/guard_employee_salary_write.sql
-- ROLE-1(Tim 的矩阵,2026-09-23):**对 employees.monthly_salary 的直连写一律拒绝。**
--
-- 【洞】authenticated 对 employees 持表级 INSERT/UPDATE(含 monthly_salary 这一列;
-- ROLE-MATRIX-0 以 information_schema.column_privileges 实测),更新策略只问
-- module.hr.edit。屏幕上没有改月薪的栏位,但数据库接受 —— 包括改自己的。
-- 绩效评估那条"本人不能批自己的加薪"(APR-2)可以这样整个绕过去。
--
-- 【规则】一次【直连】写(row_security_active = true):
--   · INSERT 带一个非 NULL 的 monthly_salary → 拒;
--   · UPDATE 让 monthly_salary 变了 → 拒。
-- 拒绝码 SALARY_DIRECT_WRITE_REFUSED。合法的路都是属主路径,这支守卫看不见它们:
-- approve_review(评估批准)、set_initial_salary(第一份月薪,Q7)、
-- anonymise_employee(依法清空)。
--
-- 【为什么用触发器而不是收列权限】列级 GRANT 要在每次 ADD COLUMN 时记得扩 ——
-- 本仓库为 SELECT 那一份列清单已经付过四次账(AGENTS.md「masked table」一节)。
-- 触发器只认这一列,加列不用碰它。形状与 enforce_write_permission 相同:INVOKER +
-- row_security_active 分出直连写。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.guard_employee_salary_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' AND NEW.monthly_salary IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_DIRECT_WRITE_REFUSED';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.monthly_salary IS DISTINCT FROM OLD.monthly_salary THEN
        RAISE EXCEPTION 'SALARY_DIRECT_WRITE_REFUSED';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_employee_salary_write() IS
'ROLE-1:直连写 employees.monthly_salary(INSERT 带值,或 UPDATE 改了它)一律 SALARY_DIRECT_WRITE_REFUSED。合法的路是属主路径:approve_review、set_initial_salary、anonymise_employee。INVOKER + row_security_active,与 enforce_write_permission 同形。';
