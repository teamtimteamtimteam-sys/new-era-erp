-- db/functions/trail_current_image.sql
-- AUDIT-TRAIL-1a:一行【今天】的整份样子 —— 还在就读那一行;已经被硬删,就取 change_log 里它最后一份完整影像
--   (DELETE 的 old,或 INSERT 的 new)。两处都没有 → NULL。第二个返回值说它是不是已经不在了。
-- 给 record_trail 用:判这一行过不过它自己那张表的读规则(Q4)、以及给子行一个"这是哪一行"的上下文(第几行、哪个物料)。
-- 【属主身份】按表名动态读任意一张表;EXECUTE 已从 authenticated 收回。
-- AUDIT-TRAIL-1d-1(M9):trail_log_only_tables() 登记的表(auth.users)不在 public 里 —— 照登记的 schema 去读,
--   并且【只读那一份安全投影】(id · email · created_at · banned_until),绝不 to_jsonb 整行(那会把口令散列与令牌带进上下文)。
--   这种表在 change_log 里没有行影像(它的事件是 record_account_event 写的 ACCOUNT_* 那几种),所以读不到就是 NULL,不回落。
CREATE OR REPLACE FUNCTION public.trail_current_image(p_table text, p_key jsonb, OUT image jsonb, OUT gone boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_where text;
    v_lo    record;
BEGIN
    gone := false;
    SELECT l.* INTO v_lo FROM trail_log_only_tables() l WHERE l.table_name = p_table;
    IF FOUND THEN
        IF p_key IS NULL OR NOT (p_key ? 'id') THEN
            image := NULL;
            RETURN;
        END IF;
        EXECUTE format('SELECT jsonb_build_object(%s) FROM %I.%I t WHERE t.id::text = $1 LIMIT 1',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_lo.image_columns) c),
                       v_lo.schema_name, v_lo.rel_name)
           INTO image USING p_key ->> 'id';
        RETURN;
    END IF;
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
