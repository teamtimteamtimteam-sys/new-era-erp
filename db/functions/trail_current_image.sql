-- db/functions/trail_current_image.sql
-- AUDIT-TRAIL-1a:一行【今天】的整份样子 —— 还在就读那一行;已经被硬删,就取 change_log 里它最后一份完整影像
--   (DELETE 的 old,或 INSERT 的 new)。两处都没有 → NULL。第二个返回值说它是不是已经不在了。
-- 给 record_trail 用:判这一行过不过它自己那张表的读规则(Q4)、以及给子行一个"这是哪一行"的上下文(第几行、哪个物料)。
-- 【属主身份】按表名动态读任意一张表;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_current_image(p_table text, p_key jsonb, OUT image jsonb, OUT gone boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_where text;
BEGIN
    gone := false;
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        image := NULL;
        RETURN;
    END IF;
    SELECT string_agg(format('t.%I::text = %L', k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE %s LIMIT 1', p_table, v_where) INTO image;
    IF image IS NOT NULL THEN
        RETURN;
    END IF;
    SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO image
      FROM change_log c
     WHERE c.table_name = p_table AND c.row_key = p_key AND c.op IN ('INSERT', 'DELETE')
     ORDER BY c.seq DESC
     LIMIT 1;
    gone := image IS NOT NULL;
END;
$function$;
