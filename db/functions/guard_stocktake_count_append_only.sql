-- db/functions/guard_stocktake_count_append_only.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2):**谁数过,只增不改**。
--
-- stocktake_counts 是"这张盘点单上谁数过"的唯一记录,过账时"录过数的人不能过账"读的就是它。
-- 一行能被改掉或删掉,那条规矩就能被事后抹平 —— 所以 UPDATE 与 DELETE 【不分直连与属主路径】
-- 一律按名拒 STOCKTAKE_COUNT_APPEND_ONLY|盘点单。重录是再插一行,不是改旧的那一行。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.guard_stocktake_count_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'STOCKTAKE_COUNT_APPEND_ONLY|%',
        COALESCE((SELECT s.code FROM stocktakes s WHERE s.id = OLD.stocktake_id), OLD.stocktake_id::text);
END;
$function$;

COMMENT ON FUNCTION public.guard_stocktake_count_append_only() IS
'ROLE-1 Batch 3a:stocktake_counts 只增不改 —— UPDATE / DELETE 不分直连与属主路径,一律按名拒 STOCKTAKE_COUNT_APPEND_ONLY|盘点单。过账时"录过数的人不能过账"读的就是这张表。';
