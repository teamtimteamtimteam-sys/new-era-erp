-- db/functions/required_training_retire.sql
-- ESG-2(Tim 2026-10-31 Q8):停用一门必修培训 —— 从覆盖里拿掉,挂着它的培训记录照旧在(不删行)。要 action.manage_esg。
--   按名拒:REQUIRED_TRAINING_NOT_FOUND · REQUIRED_TRAINING_RETIRED(已经停用)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.required_training_retire(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF NOT EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id) THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_NOT_FOUND';
    END IF;
    IF EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id AND t.retired_at IS NOT NULL) THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_RETIRED';
    END IF;
    UPDATE required_trainings SET retired_at = now(), retired_by = auth.uid(), updated_by = auth.uid() WHERE id = p_id;
    RETURN jsonb_build_object('id', p_id);
END;
$function$;
