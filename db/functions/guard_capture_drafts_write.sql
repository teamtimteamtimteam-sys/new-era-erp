-- db/functions/guard_capture_drafts_write.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 Q12 · Q13;MES-2 Step 0 Q4 · Q10):草稿的守卫。
--   ① DELETE / TRUNCATE 一律拒(CAPTURE_DRAFT_NEVER_DELETED),语句级 —— 草稿永不过期、永不删(MES-0 Q13)。
--   ② 一张草稿只决定一次:确认或驳回之后冻住(CAPTURE_DRAFT_DECIDED|<id>)。驳回是终局(Q10)。
--   ③ 唯一会变的是【决定】那几列(status · confirmed_at/by · rejected_at/by · reject_reason);转换器给的 proposed、
--      收件箱那一行、设备、数据类、来源一个字都不改(CAPTURE_DRAFT_ONLY_DECISION|<id>)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_capture_drafts_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_NEVER_DELETED';
    END IF;
    IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_DECIDED|%', OLD.id;
    END IF;
    IF (to_jsonb(NEW) - 'status' - 'confirmed_at' - 'confirmed_by' - 'rejected_at' - 'rejected_by' - 'reject_reason')
       IS DISTINCT FROM
       (to_jsonb(OLD) - 'status' - 'confirmed_at' - 'confirmed_by' - 'rejected_at' - 'rejected_by' - 'reject_reason') THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_ONLY_DECISION|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;
