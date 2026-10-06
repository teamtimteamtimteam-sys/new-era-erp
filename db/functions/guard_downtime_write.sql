-- db/functions/guard_downtime_write.sql
-- U1-B(2026-10-05,UNBLOCK-1 Q15):一段停机可以【更正】、可以【作废】,永远不【硬删】。
--
-- 【三条,各自一个理由】
--   ① DELETE 一律拒(DOWNTIME_NEVER_DELETED)—— 包括属主与迁移。交接单(shift_handover_equipment_refs,NOT NULL)与
--      保养记录指着它;一段记错了的停机的去处是作废,不是消失(消失之后,"那天为什么停了"连一个"没有发生过"都说不出)。
--   ② 作废过的行冻住(DOWNTIME_VOIDED|<起始>)—— 作废之后再更正,读的人分不清哪一个版本被作废了。
--   ③ 作废的三列只经 void_equipment_downtime() 写(DOWNTIME_VOID_THROUGH_FUNCTION_ONLY)—— 由 row_security_active 判:
--      带 RLS 的调用者(每一个经 PostgREST 来的人)直连改 voided_* 被拒;属主 / SECURITY DEFINER 的路放行。
--      更正(起止与原因)照旧走表上的 UPDATE 策略(module.processing.edit),变更记录留着旧值 —— Tim 的 Q15。
-- 【两个挂法】UPDATE 挂行级(③ 要比 OLD 与 NEW);DELETE 挂【语句级】—— 这张表没有 DELETE 策略,一个 authenticated 的 DELETE
--   在 RLS 那里就匹配零行,行级触发器根本不会触发,于是它"成功地"什么都没删(ALERT-1 那一族:零行不许报告成功)。
--   语句级零行也照样触发,所以每一句 DELETE —— 不论谁、不论命中几行 —— 都按名拒。fixture 248 DT4 实测过这一格。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.guard_downtime_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'DOWNTIME_NEVER_DELETED';
    END IF;
    IF OLD.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_VOIDED|%', to_char(OLD.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    IF row_security_active(TG_RELID)
       AND (NEW.voided_at IS DISTINCT FROM OLD.voided_at
            OR NEW.voided_by IS DISTINCT FROM OLD.voided_by
            OR NEW.void_reason IS DISTINCT FROM OLD.void_reason) THEN
        RAISE EXCEPTION 'DOWNTIME_VOID_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;
