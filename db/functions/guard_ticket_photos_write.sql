-- db/functions/guard_ticket_photos_write.sql
-- MES-2(2026-10-06,MES-0 Q20;MES-2 Step 0 Q21):地磅单照片的守卫。
--   ① DELETE / TRUNCATE 一律拒(TICKET_PHOTO_NEVER_DELETED),语句级 —— 一张拍错的照片【撤下】(带理由),行与对象都留着。
--   ② 撤下之后冻住(TICKET_PHOTO_WITHDRAWN|<id>)。
--   ③ 唯一会变的是撤下那三列(TICKET_PHOTO_ONLY_WITHDRAW|<id>):文件路径、类型、大小、谁何时传的一个字都不改。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_ticket_photos_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'TICKET_PHOTO_NEVER_DELETED';
    END IF;
    IF OLD.withdrawn_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_PHOTO_WITHDRAWN|%', OLD.id;
    END IF;
    IF (to_jsonb(NEW) - 'withdrawn_at' - 'withdrawn_by' - 'withdraw_reason')
       IS DISTINCT FROM (to_jsonb(OLD) - 'withdrawn_at' - 'withdrawn_by' - 'withdraw_reason') THEN
        RAISE EXCEPTION 'TICKET_PHOTO_ONLY_WITHDRAW|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;
