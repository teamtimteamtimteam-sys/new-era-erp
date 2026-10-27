-- db/functions/waiting_for_me_count.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (10)):首页唯一新增的那个数 —— waiting_for_me() 的行数。
--   不另数一遍:首页的数与待办页的行数是同一条查询,所以它们不可能各说各话。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_for_me_count()
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT count(*)::integer FROM waiting_for_me();
$function$;

COMMENT ON FUNCTION public.waiting_for_me_count() IS
'SYSTEM-MAP-2:首页的待办数 = waiting_for_me() 的行数(同一条查询,不另数)。';
