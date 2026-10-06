-- db/functions/guard_instrument_calibrations_write.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q31;MES-2 Step 0 Q24):校准记录的守卫 —— 只追加。
--   ① DELETE / TRUNCATE 一律拒(CALIBRATION_NEVER_DELETED),语句级。
--   ② 一条记错了的校准【作废】(带理由),不改:作废之后冻住(CALIBRATION_VOIDED|<id>)。
--   ③ 唯一会变的是作废那三列(CALIBRATION_ONLY_VOID|<id>):日期、有效期、结论、证书号、机构一个字都不改 ——
--      "某一刻这台仪器在不在校准期内"是从这些列【读的时候推出来的】(Q25),改它们就是改历史。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_instrument_calibrations_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'CALIBRATION_NEVER_DELETED';
    END IF;
    IF OLD.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'CALIBRATION_VOIDED|%', OLD.id;
    END IF;
    IF (to_jsonb(NEW) - 'voided_at' - 'voided_by' - 'void_reason')
       IS DISTINCT FROM (to_jsonb(OLD) - 'voided_at' - 'voided_by' - 'void_reason') THEN
        RAISE EXCEPTION 'CALIBRATION_ONLY_VOID|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;
