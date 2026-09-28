-- db/functions/change_log_redaction_ok.sql
-- HISTORY-1:一次涂抹对【一份影像】(old 或 new)做的改动,是不是只有"把允许的列改成 null"。
-- 键集合必须一模一样(不许删键、不许加键);每一个值变了的键都必须在允许名单里、且新值是 JSON null。
CREATE OR REPLACE FUNCTION public.change_log_redaction_ok(p_table text, p_before jsonb, p_after jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_before IS NULL OR p_after IS NULL THEN p_before IS NULL AND p_after IS NULL
        ELSE COALESCE((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_before) k), ARRAY[]::text[])
           = COALESCE((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_after) k), ARRAY[]::text[])
         AND NOT EXISTS (
             SELECT 1 FROM jsonb_each(p_after) a
              WHERE a.value IS DISTINCT FROM p_before -> a.key
                AND NOT (a.value = 'null'::jsonb AND a.key = ANY (change_log_redactable_columns(p_table))))
    END;
$function$;
