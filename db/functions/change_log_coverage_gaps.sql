-- db/functions/change_log_coverage_gaps.sql
-- HISTORY-1(Tim 的 Q4 · Q12):每一张 public 表是不是【要么被记录、要么在豁免名单上带着理由】。
--   被记录 = 两条【启用着的】触发器都在,都指向 change_log_capture():
--     zzz_change_log          AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW  (tgtype 29)
--     zzz_change_log_truncate AFTER TRUNCATE FOR EACH STATEMENT              (tgtype 32)
--   缺口三种:unbound(没绑也没豁免)· excluded_but_bound(豁免了却绑着)·
--   excluded_unknown(豁免名单点了一张不存在的表 —— 名单在描述一件已经不存在的事)。
-- 【零必须是测量】报它看了几张表;gate 少于 200 张判失败。
-- 【不是 SECURITY DEFINER】只读目录。
CREATE OR REPLACE FUNCTION public.change_log_coverage_gaps()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH t AS (
        SELECT c.oid, c.relname::text AS table_name
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
    ), b AS (
        SELECT t.table_name,
               EXISTS (SELECT 1 FROM pg_trigger tg
                        WHERE tg.tgrelid = t.oid AND tg.tgname = 'zzz_change_log' AND NOT tg.tgisinternal
                          AND tg.tgenabled <> 'D' AND tg.tgtype = 29
                          AND tg.tgfoid = 'public.change_log_capture()'::regprocedure) AS has_row,
               EXISTS (SELECT 1 FROM pg_trigger tg
                        WHERE tg.tgrelid = t.oid AND tg.tgname = 'zzz_change_log_truncate' AND NOT tg.tgisinternal
                          AND tg.tgenabled <> 'D' AND tg.tgtype = 32
                          AND tg.tgfoid = 'public.change_log_capture()'::regprocedure) AS has_trunc,
               EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = t.table_name) AS excluded
          FROM t
    )
    SELECT jsonb_build_object(
        'examined', (SELECT count(*) FROM b),
        'bound', (SELECT count(*) FROM b WHERE b.has_row AND b.has_trunc),
        'excluded', (SELECT count(*) FROM b WHERE b.excluded),
        'gaps', COALESCE((SELECT jsonb_agg(g.x ORDER BY g.x) FROM (
                    SELECT format('unbound:%s', b.table_name) AS x FROM b
                     WHERE NOT b.excluded AND NOT (b.has_row AND b.has_trunc)
                    UNION ALL
                    SELECT format('excluded_but_bound:%s', b.table_name) FROM b
                     WHERE b.excluded AND (b.has_row OR b.has_trunc)
                    UNION ALL
                    SELECT format('excluded_unknown:%s', x.table_name) FROM change_log_exclusions() x
                     WHERE NOT EXISTS (SELECT 1 FROM t WHERE t.table_name = x.table_name)
                ) g), '[]'::jsonb));
$function$;
