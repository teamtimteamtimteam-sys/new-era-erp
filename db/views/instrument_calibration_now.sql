-- db/views/instrument_calibration_now.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q31 · V8;MES-2 Step 0 Q23 · Q25 · Q29,Tim):【每一台仪器今天在不在校准期内】——
--   /operation/calibration 与设备页读它,两条提醒臂(instrument_calibration_due · _approaching)也读它。
--   仪器 = 秤、地磅、电表、在线仪表(Q23),没停用的。in_use = interface_status 不是 reserved(登记了、还没装的占位不催)。
--   今天的状态:挑法与 weighing_calibration_all 同一个(没作废、calibrated_on ≤ 今天的最近一行,calibrated_on 再 id),
--   判断是同一支 calibration_status_from。approaching:在期内、V8 给了、有效期落在 [今天, 今天 + 提前天数] 里;V8 没给 → 恒为 false。
--   【属主视图】读校准记录与设置不过 RLS,所以行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.instrument_calibration_now WITH (security_invoker = off) AS
 SELECT d.id AS device_id,
    d.code,
    d.name,
    d.kind,
    d.station,
    d.interface_status,
    d.interface_status <> 'reserved'::text AS in_use,
    d.capacity,
    d.unit,
    d.created_at AS registered_at,
    c.id AS calibration_id,
    c.calibrated_on,
    c.valid_until,
    c.result,
    c.certificate_no,
    c.calibrating_body,
    calibration_status_from(c.result, c.valid_until, CURRENT_DATE) AS status,
    calibration_status_from(c.result, c.valid_until, CURRENT_DATE) = 'in_calibration'::text
      AND s.calibration_lead_days IS NOT NULL
      AND c.valid_until <= (CURRENT_DATE + s.calibration_lead_days) AS approaching,
    s.calibration_lead_days AS lead_days
   FROM devices d
     CROSS JOIN ( SELECT ingest_settings.calibration_lead_days
           FROM ingest_settings
          WHERE ingest_settings.id) s
     LEFT JOIN LATERAL ( SELECT ic.id,
            ic.calibrated_on,
            ic.valid_until,
            ic.result,
            ic.certificate_no,
            ic.calibrating_body
           FROM instrument_calibrations ic
          WHERE ic.device_id = d.id AND ic.voided_at IS NULL AND ic.calibrated_on <= CURRENT_DATE
          ORDER BY ic.calibrated_on DESC, ic.id DESC
         LIMIT 1) c ON true
  WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
    AND d.retired_at IS NULL AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.instrument_calibration_now IS
    'MES-2:每一台没停用的仪器(秤 · 地磅 · 电表 · 在线仪表)今天在不在校准期内 —— 最近一条没作废的校准记录 + calibration_status_from。in_use = 不是 reserved。approaching 只在 V8(calibration_lead_days)给了时才可能为真。行谓词 module.processing.view。';

GRANT SELECT ON public.instrument_calibration_now TO authenticated;
REVOKE ALL ON public.instrument_calibration_now FROM anon;
