-- db/functions/trail_pk_columns.sql
-- AUDIT-TRAIL-1a:一张 public 表的主键列(按主键里的顺序)。record_trail 用它把一行拼成 change_log.row_key 的形状。
CREATE OR REPLACE FUNCTION public.trail_pk_columns(p_table text)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- GOLIVE-2(第 13 行):PL/pgSQL 而不是 SQL —— 与 trail_fk_targets 同一个理由(CHAIN-WALK-COST):带 SET 子句的 SQL 函数每调一次都重新规划
    --   这一串目录连接;PL/pgSQL 在一个会话里把计划缓存下来。查询逐字未变。
    RETURN (SELECT array_agg(a.attname::text ORDER BY k.ord)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
     WHERE c.relname = p_table AND i.indisprimary);
END;
$function$;
