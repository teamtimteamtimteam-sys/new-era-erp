-- db/functions/change_log_restrict.sql
-- HISTORY-1:把一份影像里【读者看不见的值】换成受限标记 {"$restricted": true}。
--   p_keys 为 NULL = 整份影像(任务隐私那一支);否则只换点名的那几列。
-- ★ 值本来就是 JSON null 的【不换】—— 「受限」与「本来就空」是两件事(lib/permissions.ts 抬头那一条),
--   屏幕上前者画「受限」,后者留白。
CREATE OR REPLACE FUNCTION public.change_log_restrict(p_img jsonb, p_keys text[])
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_img IS NULL THEN NULL
        ELSE COALESCE((SELECT jsonb_object_agg(e.key,
                    CASE WHEN (p_keys IS NULL OR e.key = ANY (p_keys)) AND e.value <> 'null'::jsonb
                         THEN '{"$restricted": true}'::jsonb ELSE e.value END)
                 FROM jsonb_each(p_img) e), '{}'::jsonb)
    END;
$function$;
