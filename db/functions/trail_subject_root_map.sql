-- db/functions/trail_subject_root_map.sql
-- GOLIVE-2(第 13 行):trail_subjects() 的 root_table → 以它为根的主语(按名排)的一个常量 jsonb —— trail_row_record 问「这张表是不是某个主语的根」
--   时不再扫一遍主语表。与 trail_subject_member_map 同一个理由、同一种写法。
CREATE OR REPLACE FUNCTION public.trail_subject_root_map()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT COALESCE(jsonb_object_agg(g.root_table, g.subjects), '{}'::jsonb)
      FROM (SELECT ts.root_table, jsonb_agg(ts.subject ORDER BY ts.subject) AS subjects
              FROM trail_subjects() ts GROUP BY ts.root_table) g;
$function$;
