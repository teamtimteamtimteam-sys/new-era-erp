-- db/functions/guard_incident_update_write.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3,Tim):incident_updates 的两道守卫,一支函数 ——
--   UPDATE / DELETE(语句级):对谁都按名拒 INCIDENT_UPDATE_IMMUTABLE|<动作> —— 只可追加,一次记错的更正靠下一次更正。
--   INSERT(行级):会话里直连插入按名拒 INCIDENT_UPDATE_THROUGH_FUNCTION_ONLY;record_incident_update(属主路径)放行。
--   INVOKER:row_security_active 要反映调用者(guard_part_issue_write 同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_update_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        RAISE EXCEPTION 'INCIDENT_UPDATE_IMMUTABLE|%', lower(TG_OP);
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INCIDENT_UPDATE_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;
