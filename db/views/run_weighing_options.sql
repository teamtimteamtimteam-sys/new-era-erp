-- db/views/run_weighing_options.sql
-- MES-4a(2026-10-07,MES-0 Q22;MES-4a Step 0 Q24 · Q25,Tim):【提交加工单时,一条产出腿挑得到的称重】。
--   确认了的、单独的净重(不挂地磅单)、没被更正过、还没给任何一条产出腿用过 —— 与 commit_processing_run 第 2 步的判据逐条同一组;
--   带着仪器编号、读数时刻,以及仪器在读数那一天的校准状态(weighing_calibration_all 那一句判据:not_recorded 只标出来;
--   不在校准期内的照样列出来,提交时按名拒 —— 页面先说,而不是让它消失)。
--   属主权限 + 加工的门(module.processing.view):基视图 weighing_calibration_all 从 authenticated 收回了,视图读视图走属主替换。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.run_weighing_options WITH (security_invoker = off) AS
 SELECT w.id AS weighing_id,
    w.weight_kg,
    w.source,
    w.device_id,
    wc.device_code,
    w.captured_at,
    wc.status AS calibration_status
   FROM weighings w
     JOIN weighing_calibration_all wc ON wc.weighing_id = w.id
  WHERE w.ticket_id IS NULL AND w.role = 'net'::text
    AND NOT (EXISTS ( SELECT 1
           FROM weighings x
          WHERE x.corrects_id = w.id))
    AND NOT (EXISTS ( SELECT 1
           FROM processing_outputs po
          WHERE po.weighing_id = w.id))
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.run_weighing_options IS
    'MES-4a:提交加工单时一条产出腿挑得到的称重 —— 单独的、当前的净重,还没给任何一条腿用过;带仪器与读数那天的校准状态。门:module.processing.view。';

GRANT SELECT ON public.run_weighing_options TO authenticated;
REVOKE ALL ON public.run_weighing_options FROM anon;
