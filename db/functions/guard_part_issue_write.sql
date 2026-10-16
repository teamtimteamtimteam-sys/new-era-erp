-- db/functions/guard_part_issue_write.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12,Tim):maintenance_part_issues 的两道守卫,一支函数 ——
--   UPDATE / DELETE(语句级):对谁都按名拒 PART_ISSUE_IMMUTABLE|<动作> —— 只可追加,一次出错的出库靠一行退回更正。
--   INSERT(行级):会话里直连插入(row_security_active = 真)按名拒 PART_ISSUES_THROUGH_FUNCTION_ONLY;那两支 DEFINER 函数(属主路径)放行。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_equipment_direct_write 同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.guard_part_issue_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        RAISE EXCEPTION 'PART_ISSUE_IMMUTABLE|%', lower(TG_OP);
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'PART_ISSUES_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;
