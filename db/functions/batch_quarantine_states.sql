-- db/functions/batch_quarantine_states.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q16,Tim):【这一批身上开着的、要隔离的安全状态】—— 发货队列与发货单拿它【标出来,不拒】。
--   预留与发货此前一个安全状态都不看(MES-3b Step 0 §1.11);Tim 裁:标,不拒 —— 受损电池怎么运归货代(V30),
--   一道拒绝还会挡住把它们送去有执照的回收商。
--   读 output_batch_safety_states(开着的,ended_at 为空)× inbound_safety_states.requires_quarantine = true(V4 为空 = 不要求,
--   与 MES-3a 的隔离闸同一句)。返回以逗号连起来的状态码,按码排序;一个都没有 → NULL。
--   【内层】不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回;shipment_document 与 shipping_queue_rows(各自查过码的 DEFINER)调它。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.batch_quarantine_states(p_output_batch_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT string_agg(s.safety_state_code, ',' ORDER BY s.safety_state_code)
      FROM output_batch_safety_states s
      JOIN inbound_safety_states st ON st.code = s.safety_state_code
     WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL AND st.requires_quarantine IS TRUE;
$function$;
