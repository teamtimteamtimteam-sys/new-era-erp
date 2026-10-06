-- db/functions/guard_gateway_outages_append_only.sql
-- MES-1(2026-10-06):网关中断只追加 —— 一段过去的沉默记下了就不改、不删(INGEST_LOG_APPEND_ONLY|gateway_outages|<操作>)。
-- 语句级:UPDATE / DELETE / TRUNCATE 不论命中几行都按名拒(零行也触发)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_gateway_outages_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|gateway_outages|%', lower(TG_OP);
END;
$function$;
