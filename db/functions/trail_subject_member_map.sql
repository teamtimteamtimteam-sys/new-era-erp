-- db/functions/trail_subject_member_map.sql
-- GOLIVE-2(第 13 行):trail_subject_members() 里 home 的那些行,按 table_name 分组、组内按 (subject, ord) 排好的一个常量 jsonb。
--   IMMUTABLE、无参、不带 SET —— 规划器在规划时就把它求成一个常量,于是 trail_row_record 在 PL/pgSQL 里缓存的那条计划每一跳只做一次按键取值,
--   不再扫一遍 402 行。内容与 trail_subject_members() 逐行同源(改那一张,这一张跟着变)。
CREATE OR REPLACE FUNCTION public.trail_subject_member_map()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT COALESCE(jsonb_object_agg(g.table_name, g.members), '{}'::jsonb)
      FROM (SELECT tm.table_name, jsonb_agg(to_jsonb(tm) ORDER BY tm.subject, tm.ord) AS members
              FROM trail_subject_members() tm WHERE tm.home GROUP BY tm.table_name) g;
$function$;
