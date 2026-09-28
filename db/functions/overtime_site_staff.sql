-- db/functions/overtime_site_staff.sql
-- OVERTIME-1(Tim Q11 · Q17):今天标为现场员工的人(没删的)—— 录入页的员工下拉只列他们,
-- 而【一个都没有】正是录入页那个空态:建批钮按不动,旁边一行说没有人被标为现场员工、去哪里标。
-- 【属主权限】录的人(财务)本来就读得到员工;但页面的空态判断对仓库也要成立,而仓库读不到员工行。
--   只带编号、显示名、入离职日(录入页用它们挡住不在职的日期),不带任何别的。
-- 【门】与两张加班表同一组码。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_site_staff()
 RETURNS TABLE(employee_id uuid, employee_code text, employee_name text, hire_date date, separation_date date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.hr.view') OR has_permission('action.overtime_enter')
            OR has_permission('action.overtime_approve')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', 'action.overtime_enter';
    END IF;
    RETURN QUERY
    SELECT e.id, e.code, COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name),
           e.hire_date, e.separation_date
      FROM employees e
     WHERE e.is_site_staff AND e.deleted_at IS NULL
     ORDER BY e.code;
END;
$function$;

COMMENT ON FUNCTION public.overtime_site_staff() IS
'OVERTIME-1:标为现场员工的人(employees.is_site_staff,未删)—— 录入页的下拉与它的空态都读它。属主权限,只带编号、显示名、入离职日。门:module.hr.view / action.overtime_enter / action.overtime_approve 任一,否则 PERMISSION_DENIED。';
