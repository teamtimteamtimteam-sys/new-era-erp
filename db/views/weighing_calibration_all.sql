-- db/views/weighing_calibration_all.sql
-- MES-2(2026-10-06,MES-0 Q30;MES-2 Step 0 Q25 · Q27,Tim):【每一次称重,在它那一刻,仪器在不在校准期内】—— 基视图,不给人读。
--   captured_on = 读数那一天(新加坡日历);对它挑这台仪器【没作废、calibrated_on ≤ captured_on】的最近一行校准
--   (按 calibrated_on,再按 id —— id 是 identity,同一天记两行也排得出先后),交给 calibration_status_from 判:
--   in_calibration · expired · failed · never_calibrated;没有记录仪器 → not_recorded。
--   is_current = 这一行没有被更正过(更正读最新的)。
--   【属主视图、不带谓词、EXECUTE / SELECT 从 authenticated 收回】:读者经 weighing_calibration(带门的外壳)读它;
--   校准闸 assert_receipt_reading_calibrated(调用方都是 DEFINER)以属主身份直接读它。视图读视图走属主替换。

CREATE VIEW public.weighing_calibration_all WITH (security_invoker = off) AS
 SELECT w.id AS weighing_id,
    w.ticket_id,
    w.role,
    w.weight_kg,
    w.source,
    w.device_id,
    d.code AS device_code,
    w.captured_at,
    (w.captured_at AT TIME ZONE 'Asia/Singapore'::text)::date AS captured_on,
    NOT (EXISTS ( SELECT 1
           FROM weighings x
          WHERE x.corrects_id = w.id)) AS is_current,
    c.id AS calibration_id,
    c.result AS calibration_result,
    c.valid_until,
        CASE
            WHEN w.device_id IS NULL THEN 'not_recorded'::text
            ELSE calibration_status_from(c.result, c.valid_until, (w.captured_at AT TIME ZONE 'Asia/Singapore'::text)::date)
        END AS status
   FROM weighings w
     LEFT JOIN devices d ON d.id = w.device_id
     LEFT JOIN LATERAL ( SELECT ic.id,
            ic.result,
            ic.valid_until
           FROM instrument_calibrations ic
          WHERE ic.device_id = w.device_id AND ic.voided_at IS NULL
            AND ic.calibrated_on <= (w.captured_at AT TIME ZONE 'Asia/Singapore'::text)::date
          ORDER BY ic.calibrated_on DESC, ic.id DESC
         LIMIT 1) c ON true;

COMMENT ON VIEW public.weighing_calibration_all IS
    'MES-2:每一次称重在读数那一天(新加坡日历)仪器在不在校准期内 —— in_calibration · expired · failed · never_calibrated · not_recorded(没有记录仪器)。is_current = 没被更正过。基视图,不给人读:读者经 weighing_calibration;校准闸以属主身份读它。';

REVOKE ALL ON public.weighing_calibration_all FROM authenticated, anon;
