-- db/functions/trail_pk_columns.sql
-- AUDIT-TRAIL-1a:一张 public 表的主键列(按主键里的顺序)。record_trail 用它把一行拼成 change_log.row_key 的形状。
CREATE OR REPLACE FUNCTION public.trail_pk_columns(p_table text)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT array_agg(a.attname::text ORDER BY k.ord)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
     WHERE c.relname = p_table AND i.indisprimary;
$function$;
