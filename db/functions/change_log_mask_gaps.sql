-- db/functions/change_log_mask_gaps.sql
-- HISTORY-1(Tim 的 Q7):遮蔽规则名单与目录对不对得上。
--   目录这一侧 = 每张 <表>_masked 视图里 `CASE … END AS <列>`、而 <列> 是那张基表【真的列】的那些
--   (派生列如 purchase_orders.gross_total_ccy、employees 的年假余额不算 —— 它们不在基表里,记录里也没有)。
--   名单这一侧 = change_log_mask_rules()。
--   缺一条(missing_rule)= 记录会把屏幕遮着的值交出去;多一条(stale_rule)= 名单在描述一件已经不存在的事。
-- 【零必须是测量】同时报它看了几张表、几列 —— gate 在看见的表少于 20 张时判失败,
--   一个什么都没看见的检查不许报"干净"。
-- 【不是 SECURITY DEFINER】只读目录与一份常量名单。
CREATE OR REPLACE FUNCTION public.change_log_mask_gaps()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH views AS (
        SELECT left(v.relname::text, -7) AS base, pg_get_viewdef(v.oid) AS def
          FROM pg_class v
          JOIN pg_namespace n ON n.oid = v.relnamespace
         WHERE n.nspname = 'public' AND v.relkind = 'v' AND v.relname::text LIKE '%\_masked'
    ), hidden AS (
        SELECT DISTINCT w.base AS table_name, m[1] AS column_name
          FROM views w, regexp_matches(w.def, 'END AS (\w+)', 'g') m
         WHERE EXISTS (SELECT 1 FROM pg_attribute a
                         JOIN pg_class t ON t.oid = a.attrelid
                         JOIN pg_namespace tn ON tn.oid = t.relnamespace
                        WHERE tn.nspname = 'public' AND t.relkind = 'r' AND t.relname::text = w.base
                          AND a.attname::text = m[1] AND a.attnum > 0 AND NOT a.attisdropped)
    ), rules AS (
        SELECT r.table_name, r.column_name FROM change_log_mask_rules() r
    )
    SELECT jsonb_build_object(
        'examined_tables', (SELECT count(DISTINCT h.table_name) FROM hidden h),
        'examined_columns', (SELECT count(*) FROM hidden h),
        'gaps', COALESCE((SELECT jsonb_agg(g.x ORDER BY g.x) FROM (
                    SELECT format('missing_rule:%s.%s', h.table_name, h.column_name) AS x FROM hidden h
                     WHERE NOT EXISTS (SELECT 1 FROM rules r WHERE r.table_name = h.table_name AND r.column_name = h.column_name)
                    UNION ALL
                    SELECT format('stale_rule:%s.%s', r.table_name, r.column_name) FROM rules r
                     WHERE NOT EXISTS (SELECT 1 FROM hidden h WHERE h.table_name = r.table_name AND h.column_name = r.column_name)
                ) g), '[]'::jsonb));
$function$;
