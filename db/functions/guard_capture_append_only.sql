-- db/functions/guard_capture_append_only.sql
-- MES-2(2026-10-06,规格 §4.2 · §6.3;MES-0 §3.7;MES-2 Step 0 Q9 · Q11 · Q18):三张【只追加】的采集记录共用的守卫 ——
--   weighings(正式称重记录:更正是一条新行,corrects_id 指回原行)· capture_draft_changes(确认时改过的值,原值 + 新值 + 理由)·
--   weighbridge_ticket_shares(地磅单分给收货单 / 发货行的公斤数)。
--   UPDATE 一律拒(行级);DELETE / TRUNCATE 一律拒(【语句级】—— 没有 DELETE 策略时 authenticated 的 DELETE 在 RLS 那里就是
--   零行,行级触发器不会醒,U1-B 的那一课)。CAPTURE_RECORD_APPEND_ONLY|<表>|<操作>。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_capture_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'CAPTURE_RECORD_APPEND_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;
