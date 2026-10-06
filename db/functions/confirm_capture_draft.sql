-- db/functions/confirm_capture_draft.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 Q11 · Q12;MES-2 Step 0 Q8 · Q9,Tim):工位上【确认】一张网关送来的草稿 —— 它从此是正式记录。
--   持 action.confirm_capture(warehouse · cto · admin;任何一个持有人确认任何一个工位的草稿,工位照显示,MES-0 Q11)。
--   p_overrides {"weight_kg": …} 改量出来的值,p_reasons {"weight_kg": "…"} 写改的理由(改了就必填);p_subject 选主语
--   ({} 净重 · {"new_ticket": …} 开一张地磅单 · {"ticket_id": …} 完成一张)。全部规则在 capture_confirm_internal。
--   返回那一次称重的 id。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.confirm_capture_draft(p_draft_id uuid, p_overrides jsonb DEFAULT '{}'::jsonb, p_reasons jsonb DEFAULT '{}'::jsonb, p_subject jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.confirm_capture');
    RETURN capture_confirm_internal(p_draft_id, p_overrides, p_reasons, p_subject, NULL, NULL);
END;
$function$;
