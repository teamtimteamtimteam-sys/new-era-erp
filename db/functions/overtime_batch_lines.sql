-- db/functions/overtime_batch_lines.sql
-- OVERTIME-1(2026-09-28):一张加班批的行,带员工编号与名字。
-- 【为什么是属主权限】仓库(批的人)不持 module.hr.view,employees 的 RLS 只给他自己那一行,
--   所以 INVOKER 下名字永远是空的 —— 而他要批的正是"谁、哪天、几个小时"。本函数只替他打开
--   【这一批里那几个人的编号与显示名】,不带任何薪酬或身份信息(Tim Q13:名字、日期、小时,永不带钱)。
-- 【门】module.hr.view、action.overtime_enter、action.overtime_approve 任一 —— 与两张表的读策略同一组码。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_batch_lines(p_batch_id uuid)
 RETURNS TABLE(line_id uuid, employee_id uuid, employee_code text, employee_name text, work_date date, day_kind text, hours numeric, note text, voided boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.hr.view') OR has_permission('action.overtime_enter')
            OR has_permission('action.overtime_approve')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', 'action.overtime_approve';
    END IF;
    RETURN QUERY
    SELECT l.id, l.employee_id, e.code,
           COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name),
           l.work_date, l.day_kind, l.hours, l.note, l.voided_at IS NOT NULL
      FROM overtime_lines l
      JOIN employees e ON e.id = l.employee_id
     WHERE l.batch_id = p_batch_id
     ORDER BY l.work_date, e.code;
END;
$function$;

COMMENT ON FUNCTION public.overtime_batch_lines(uuid) IS
'OVERTIME-1:一张加班批的行(员工编号、显示名、日期、桶、小时、备注、作废否)。属主权限,因为批的人(仓库)读不到别人的员工行;只带编号与显示名,不带薪酬或身份信息。门:module.hr.view / action.overtime_enter / action.overtime_approve 任一,否则 PERMISSION_DENIED。';
