-- db/functions/guard_employment_history_salary_write.sql
-- ROLE-1(2026-09-23):guard_employee_salary_write 的另一半。
--
-- employment_history 的插入策略只问 module.hr.edit。一行直连插进来的 salary_change
-- (old_/new_monthly_salary)会在履历上留下一次【没有发生过】的调薪 —— 人读履历时
-- 无从分辨。调薪的留痕只该由写 monthly_salary 的那几条属主路径自己写
-- (approve_review、set_initial_salary),所以:
--
-- 【规则】一次【直连】INSERT(row_security_active = true)带非 NULL 的
-- old_monthly_salary 或 new_monthly_salary,或 change_type = 'salary_change' → 拒,
-- SALARY_DIRECT_WRITE_REFUSED。app 自己的两处插入(app/hr/employees/actions.ts
-- 入职与调岗)从不写这两列,不受影响。
--
-- UPDATE 不需要它:trg_employment_history_immutable 本来就不让改。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.guard_employment_history_salary_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF NEW.change_type = 'salary_change'
       OR NEW.old_monthly_salary IS NOT NULL
       OR NEW.new_monthly_salary IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_DIRECT_WRITE_REFUSED';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_employment_history_salary_write() IS
'ROLE-1:直连插入一行带薪资数字(或 change_type = salary_change)的履历,一律 SALARY_DIRECT_WRITE_REFUSED —— 调薪留痕只由写 monthly_salary 的属主路径自己写(approve_review、set_initial_salary)。';
