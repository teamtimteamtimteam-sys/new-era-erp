-- db/functions/change_log_null_keys.sql
-- HISTORY-1:把一份影像里【点名的那些键】改成 JSON null,其余原样;键集合不变。
-- 涂抹(change_log_redact_employee)用它 —— 只做 change_log_redaction_ok 放行的那一件事。
CREATE OR REPLACE FUNCTION public.change_log_null_keys(p_img jsonb, p_keys text[])
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_img IS NULL THEN NULL
        ELSE COALESCE((SELECT jsonb_object_agg(e.key, CASE WHEN e.key = ANY (p_keys) THEN 'null'::jsonb ELSE e.value END)
                         FROM jsonb_each(p_img) e), '{}'::jsonb)
    END;
$function$;
