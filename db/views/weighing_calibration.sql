-- db/views/weighing_calibration.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q28,Tim):weighing_calibration_all 的【带门外壳】—— 地磅单页、收货单页、确认队列读它,
--   把"instrument not recorded" / 不在校准期内标出来(开关关着时只标,不拒)。行谓词与 weighings 的读策略逐字同一句。

CREATE VIEW public.weighing_calibration WITH (security_invoker = off) AS
 SELECT weighing_id,
    ticket_id,
    role,
    weight_kg,
    source,
    device_id,
    device_code,
    captured_at,
    captured_on,
    is_current,
    calibration_id,
    calibration_result,
    valid_until,
    status
   FROM weighing_calibration_all
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.inbound.view'::text)
     OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.weighing_calibration IS
    'MES-2:weighing_calibration_all 的带门外壳(加工 / 收货 / 物流查看码任一,与 weighings 的读策略同一句)。';

GRANT SELECT ON public.weighing_calibration TO authenticated;
REVOKE ALL ON public.weighing_calibration FROM anon;
