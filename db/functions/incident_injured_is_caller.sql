-- db/functions/incident_injured_is_caller.sql
-- ESG-2(Tim 2026-10-31 Q7):这件事故受伤的那名员工,是不是【调用者自己】。incident_days_lost_corrections 的读策略用它给受伤的人本人让路
--   (与 incidents_masked 里 OR injured_employee_id = current_user_employee() 同一个判据)。
--   【属主权限】injured_employee_id 从列授权里拿掉了,读策略里的子查询以调用者身份读不到那一列;这里只回一个布尔,不回任何列。
--   current_user_employee() 为空(没有员工档案)→ false(COALESCE,CLEANUP-A 的那个陷阱)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.incident_injured_is_caller(p_incident_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT i.injured_employee_id = current_user_employee() FROM incidents i WHERE i.id = p_incident_id), false);
$function$;
